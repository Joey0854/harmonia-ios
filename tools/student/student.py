"""Student separation models for Harmonia (knowledge distillation from BS-RoFormer SW), built to run
in float16 on the Apple Neural Engine.

The I/O contract (the same as the app's HTDemucs spectral branch, so App/Sound/Demucs does the transforms
with Accelerate, outside the model):
  input  "spec": float32 [1, 4, 2048, 336]: the normalised STFT (n_fft 4096, hop 1024, Hann, /sqrt(n_fft))
          of one 7.8 s stereo segment (343980 samples at 44.1 kHz), channels L re, L im, R re, R im,
          then z-scored with the mean / std of the whole tensor (Demucs.separate does exactly this).
  output "mask": float32 [1, 20, 2048, 336]: a complex mask per stem and channel, stems in STEMS order,
          each with the input's four channels (L re, L im, R re, R im). Stem spectrum = mask (complex) x the
          un-normalised input spectrum; the app multiplies and inverts. Bounded to [-2, 2] by 2·tanh.

float16 safety (the teacher-sized HTDemucs reaches ~2655 inside, whose square overflows float16):
  - no group / layer norm over big tensors: ChanRMSNorm normalises over channels only (<= 512 values),
    clamps to +-CLAMP and pre-scales by 1/PRESCALE before squaring, so the largest square is
    (CLAMP/PRESCALE)^2 = 1024, the mean of squares <= 1024; x / rms(x) is unchanged by the pre-scale;
  - every residual branch ends in a norm-free conv whose output is added to a normed stream, and
    every block input is normed first (pre-norm), so the stream between blocks stays bounded by
    construction only up to the clamp; a final clamp keeps the head's input finite;
  - attention (candidate B) uses QK-norm: q and k are RMS-normalised over the head dimension (64), so
    |q·k| <= 64; times 1/8 and a learned temperature clamped to [0.1, 4] the logits stay within +-32,
    far from exp() overflow even before softmax's own max subtraction;
  - the output is 2·tanh: never above 2.
ANE-friendly layout (Apple's ml-ane-transformers principles): 4-D [B, C, H, W] tensors throughout, 1x1 /
3x3 Conv2d instead of Linear, reductions over the channel axis, no 5-D tensors.
"""
import torch
import torch.nn as nn
import torch.nn.functional as F

STEMS = ["vocals", "drums", "bass", "piano", "other"]
BINS, FRAMES = 2048, 336
CLAMP, PRESCALE = 1024.0, 32.0


class ChanRMSNorm(nn.Module):
    def __init__(self, c, eps=1e-4):
        super().__init__()
        self.g = nn.Parameter(torch.ones(1, c, 1, 1))
        self.eps = eps

    def forward(self, x):
        xs = torch.clamp(x, -CLAMP, CLAMP) * (1.0 / PRESCALE)
        ms = torch.mean(xs * xs, dim=1, keepdim=True)
        return xs * torch.rsqrt(ms + self.eps) * self.g


class ResBlock(nn.Module):
    """pre-norm 3x3 conv block: x + conv(gelu(conv(norm(x))))."""

    def __init__(self, c, k=(3, 3), dil=(1, 1)):
        super().__init__()
        pad = (dil[0] * (k[0] - 1) // 2, dil[1] * (k[1] - 1) // 2)
        self.norm = ChanRMSNorm(c)
        self.c1 = nn.Conv2d(c, c, k, padding=pad, dilation=dil)
        self.c2 = nn.Conv2d(c, c, k, padding=pad, dilation=dil)
        nn.init.zeros_(self.c2.bias)
        self.c2.weight.data *= 0.5

    def forward(self, x):
        return x + self.c2(F.gelu(self.c1(self.norm(x)), approximate="tanh"))


class Attention(nn.Module):
    """Self-attention over time on a [1, C, 1, T] tensor, QK-normed (see the module docstring)."""

    def __init__(self, c, heads=8):
        super().__init__()
        self.h, self.d = heads, c // heads
        self.norm = ChanRMSNorm(c)
        self.qkv = nn.Conv2d(c, 3 * c, 1)
        self.out = nn.Conv2d(c, c, 1)
        self.qn = ChanRMSNorm(self.d)
        self.kn = ChanRMSNorm(self.d)
        self.temp = nn.Parameter(torch.ones(1))

    def forward(self, x):
        b, c, _, t = x.shape
        q, k, v = torch.chunk(self.qkv(self.norm(x)), 3, dim=1)
        # [1, C, 1, T] -> [h, d, 1, T]: heads on the batch axis so the per-head norm is a channel norm
        q = self.qn(q.reshape(self.h, self.d, 1, t)).reshape(self.h, self.d, t)
        k = self.kn(k.reshape(self.h, self.d, 1, t)).reshape(self.h, self.d, t)
        v = v.reshape(self.h, self.d, t)
        scale = torch.clamp(self.temp, 0.1, 4.0) / (self.d ** 0.5)
        logits = torch.matmul(q.transpose(1, 2), k) * scale          # [h, T, T]
        attn = torch.softmax(logits, dim=-1)
        y = torch.matmul(v, attn.transpose(1, 2))                     # [h, d, T]
        return x + self.out(y.reshape(1, c, 1, t))


class FeedForward(nn.Module):
    def __init__(self, c, mult=2):
        super().__init__()
        self.norm = ChanRMSNorm(c)
        self.a = nn.Conv2d(c, c * mult, 1)
        self.b = nn.Conv2d(c * mult, c, 1)

    def forward(self, x):
        return x + self.b(F.gelu(self.a(self.norm(x)), approximate="tanh"))


class Student(nn.Module):
    """U-Net over (frequency, time): 2048 bins down to 8 in four x4 steps, a temporal bottleneck over the
    flattened low-resolution spectrum, and back up with skip connections.

    kind "A": the bottleneck is temporal convolutions only (1x3, six blocks).
    kind "B": the same, with fewer conv blocks and QK-normed self-attention over time.
    """

    def __init__(self, kind="A", chans=(32, 64, 128, 256, 320), bott=512, blocks=(1, 1, 1, 1, 1)):
        super().__init__()
        self.kind = kind
        c = chans
        self.inp = nn.Conv2d(4, c[0], 3, padding=1)
        self.enc = nn.ModuleList()
        self.down = nn.ModuleList()
        self.tstride = [1, 2, 1, 1]          # time /2 once: 336 -> 168
        for i in range(5):
            self.enc.append(nn.Sequential(*[ResBlock(c[i]) for _ in range(blocks[i])]))
        for i in range(4):
            self.down.append(nn.Conv2d(c[i], c[i + 1], (4, self.tstride[i]), stride=(4, self.tstride[i])))
        self.low_bins = BINS // 4 ** 4        # 8
        flat = c[4] * self.low_bins
        self.to_b = nn.Conv2d(flat, bott, 1)
        mid = []
        if kind == "A":
            for _ in range(6):        # no dilation: dilated convs are reported to leave the ANE
                mid.append(ResBlock(bott, k=(1, 3)))
        else:
            for _ in range(2):
                mid.append(ResBlock(bott, k=(1, 3)))
            for _ in range(3):
                mid += [Attention(bott), FeedForward(bott)]
        self.mid = nn.Sequential(*mid)
        self.mid_norm = ChanRMSNorm(bott)
        self.from_b = nn.Conv2d(bott, flat, 1)
        self.up = nn.ModuleList()
        self.dec = nn.ModuleList()
        for i in reversed(range(4)):
            self.up.append(nn.Conv2d(c[i + 1], c[i], 1))
            self.dec.append(nn.Sequential(*[ResBlock(c[i]) for _ in range(blocks[i])]))
        self.out_norm = ChanRMSNorm(c[0])
        self.head = nn.Conv2d(c[0], 4 * len(STEMS), 3, padding=1)
        nn.init.zeros_(self.head.weight)
        nn.init.zeros_(self.head.bias)
        # identity-ish start: mask 1+0i for "other", 0 elsewhere -> 2 tanh(b) = 1 -> b = atanh(0.5)
        with torch.no_grad():
            o = STEMS.index("other") * 4
            self.head.bias[o + 0] = 0.5493
            self.head.bias[o + 2] = 0.5493

    def forward(self, spec):
        x = self.inp(spec)
        skips = []
        for i in range(4):
            x = self.enc[i](x)
            skips.append(x)
            x = self.down[i](x)
        x = self.enc[4](x)
        b, c4, f, t = x.shape
        y = self.to_b(x.reshape(1, c4 * f, 1, t))
        y = self.mid_norm(self.mid(y))
        x = x + self.from_b(y).reshape(1, c4, f, t)
        for j, i in enumerate(reversed(range(4))):
            # two x2 steps rather than one x4 (upsampling by more than 2 is reported to leave the ANE)
            x = F.interpolate(x, scale_factor=(2.0, float(self.tstride[i])), mode="nearest")
            x = F.interpolate(x, scale_factor=(2.0, 1.0), mode="nearest")
            x = self.up[j](x) + skips[i]
            x = self.dec[j](x)
        return 2.0 * torch.tanh(self.head(self.out_norm(x)))


def build(kind, seed=0):
    torch.manual_seed(seed)
    m = Student(kind)
    # random weights for the pilot: make the head non-zero so the output depends on the input
    with torch.no_grad():
        m.head.weight.normal_(0, 0.02)
    return m.eval()


def params(m):
    return sum(p.numel() for p in m.parameters())


if __name__ == "__main__":
    for k in ("A", "B"):
        m = build(k)
        x = torch.randn(1, 4, BINS, FRAMES)
        with torch.no_grad():
            y = m(x)
        print(k, f"{params(m) / 1e6:.2f}M params", tuple(y.shape), float(y.abs().max()))
