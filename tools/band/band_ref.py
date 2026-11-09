"""HTDemucs split into "network body" (converted to Core ML) and the pre/post processing the
app does itself (numpy here, App/Sound/BandSeparator.swift on the phone).

The numpy part is the specification for the Swift code: same padding, same STFT scaling, same
segment offsets and transition weights as demucs.apply.apply_model(shifts=0, overlap=0.25).

Used by tools/band/align.py (PC check against apply_model) and tools/band/convert.py (CI).
"""
import math

import numpy as np
import torch
from torch import nn

SR = 44100
NFFT = 4096
HOP = 1024
SEGMENT = 343980          # int(44100 * 7.8): htdemucs' training length
FRAMES = 336              # ceil(SEGMENT / HOP)
BINS = 2048               # NFFT // 2, the Nyquist bin is dropped
STRIDE = int(0.75 * SEGMENT)
SOURCES = ["drums", "bass", "other", "vocals"]


class Body(nn.Module):
    """HTDemucs.forward between the normalisations: takes the normalised CaC spectrogram
    (1, 4, BINS, FRAMES) and the normalised wave (1, 2, SEGMENT), returns the normalised
    outputs (1, 16, BINS, FRAMES) = 4 sources x (L re, L im, R re, R im) and (1, 8, SEGMENT)
    = 4 sources x (L, R)."""

    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, x, xt):
        m = self.m
        saved, saved_t, lengths, lengths_t = [], [], [], []
        for idx, encode in enumerate(m.encoder):
            lengths.append(x.shape[-1])
            inject = None
            if idx < len(m.tencoder):
                lengths_t.append(xt.shape[-1])
                tenc = m.tencoder[idx]
                xt = tenc(xt)
                if not tenc.empty:
                    saved_t.append(xt)
                else:
                    inject = xt
            x = encode(x, inject)
            if idx == 0 and m.freq_emb is not None:
                frs = torch.arange(x.shape[-2], device=x.device)
                emb = m.freq_emb(frs).t()[None, :, :, None].expand_as(x)
                x = x + m.freq_emb_scale * emb
            saved.append(x)
        if m.crosstransformer:
            if m.bottom_channels:
                b, c, f, t = x.shape
                x = x.reshape(b, c, f * t)
                x = m.channel_upsampler(x)
                x = x.reshape(b, -1, f, t)
                xt = m.channel_upsampler_t(xt)
            x, xt = m.crosstransformer(x, xt)
            if m.bottom_channels:
                b, c, f, t = x.shape
                x = x.reshape(b, c, f * t)
                x = m.channel_downsampler(x)
                x = x.reshape(b, -1, f, t)
                xt = m.channel_downsampler_t(xt)
        for idx, decode in enumerate(m.decoder):
            skip = saved.pop(-1)
            x, pre = decode(x, skip, lengths.pop(-1))
            offset = m.depth - len(m.tdecoder)
            if idx >= offset:
                tdec = m.tdecoder[idx - offset]
                length_t = lengths_t.pop(-1)
                if tdec.empty:
                    pre = pre[:, :, 0]
                    xt, _ = tdec(pre, None, length_t)
                else:
                    skip = saved_t.pop(-1)
                    xt, _ = tdec(xt, skip, length_t)
        return x, xt


def _constant_embeddings():
    """The cross-transformer's position embeddings depend only on shapes. Cached, they enter a
    trace as constants instead of arange / sin / in-place slice writes (which Core ML lacks)."""
    import demucs.transformer as T
    if getattr(T, "_band_cached", False):
        return
    for name in ["create_sin_embedding", "create_2d_sin_embedding"]:
        original = getattr(T, name)
        cache = {}

        def cached(*args, _f=original, _c=cache, **kwargs):
            # under a trace the sizes are traced values: plain ints make the key stable
            args = tuple(int(a) if isinstance(a, (int, torch.Tensor)) else a for a in args)
            kwargs = {k: int(v) if isinstance(v, (int, torch.Tensor)) else v for k, v in kwargs.items()}
            key = repr((args, sorted(kwargs.items())))
            if key not in _c:
                with torch.no_grad():
                    _c[key] = _f(*args, **kwargs).detach()
            return _c[key]
        setattr(T, name, cached)
    T._band_cached = True


def load_body():
    _constant_embeddings()
    from demucs.pretrained import get_model
    bag = get_model("htdemucs")
    model = bag.models[0] if hasattr(bag, "models") else bag
    model.eval()
    assert model.cac and model.nfft == NFFT and model.hop_length == HOP
    assert int(model.segment * SR) == SEGMENT and list(model.sources) == SOURCES
    return model, Body(model).eval()


# ---------------------------------------------------------------- numpy pre/post processing

def hann(n=NFFT):
    k = np.arange(n)
    return 0.5 - 0.5 * np.cos(2 * np.pi * k / n)   # periodic, as torch.hann_window


def reflect(x, left, right):
    return np.pad(x, (left, right), mode="reflect")


def spec(x):
    """HTDemucs._spec for one channel of SEGMENT samples -> complex (BINS, FRAMES)."""
    le = int(math.ceil(len(x) / HOP))
    pad = HOP // 2 * 3
    x = reflect(x, pad, pad + le * HOP - len(x))
    x = reflect(x, NFFT // 2, NFFT // 2)                    # torch.stft center=True
    frames = 1 + (len(x) - NFFT) // HOP
    idx = np.arange(NFFT)[None, :] + HOP * np.arange(frames)[:, None]
    z = np.fft.rfft(x[idx] * hann(), axis=1) / math.sqrt(NFFT)  # normalized=True
    z = z.T[:-1, 2:2 + le]
    return z


def ispec(z, length=SEGMENT):
    """HTDemucs._ispec for one channel: complex (BINS, FRAMES) -> length samples."""
    z = np.concatenate([z, np.zeros((1, z.shape[1]), z.dtype)], 0)
    z = np.pad(z, ((0, 0), (2, 2)))
    pad = HOP // 2 * 3
    le = HOP * int(math.ceil(length / HOP)) + 2 * pad
    frames = z.shape[1]
    w = hann()
    frames_t = np.fft.irfft(z.T * math.sqrt(NFFT), n=NFFT, axis=1) * w
    total = NFFT + HOP * (frames - 1)
    out = np.zeros(total)
    env = np.zeros(total)
    for t in range(frames):
        out[t * HOP:t * HOP + NFFT] += frames_t[t]
        env[t * HOP:t * HOP + NFFT] += w * w
    start = NFFT // 2
    out = out[start:start + le] / env[start:start + le]
    return out[pad:pad + length]


def prepare(seg):
    """seg: (2, SEGMENT) -> network inputs (normalised) and the statistics to undo it."""
    zl, zr = spec(seg[0]), spec(seg[1])
    x = np.stack([zl.real, zl.imag, zr.real, zr.imag])[None].astype(np.float64)
    mean, std = x.mean(), x.std(ddof=1)
    x = (x - mean) / (1e-5 + std)
    meant, stdt = seg.mean(), seg.std(ddof=1)
    xt = ((seg - meant) / (1e-5 + stdt))[None]
    return x.astype(np.float32), xt.astype(np.float32), (mean, std, meant, stdt)


def finish(x, xt, stats):
    """Network outputs -> (4 sources, 2 channels, SEGMENT)."""
    mean, std, meant, stdt = stats
    x = x.astype(np.float64).reshape(4, 4, BINS, FRAMES) * std + mean
    xt = xt.astype(np.float64).reshape(4, 2, SEGMENT) * stdt + meant
    out = np.zeros((4, 2, SEGMENT))
    for s in range(4):
        for c in range(2):
            out[s, c] = ispec(x[s, 2 * c] + 1j * x[s, 2 * c + 1]) + xt[s, c]
    return out


def weights():
    half = SEGMENT // 2
    w = np.concatenate([np.arange(1, half + 1), np.arange(SEGMENT - half, 0, -1)]).astype(np.float64)
    return w / w.max()


def separate(mix, run):
    """apply_model(shifts=0, split=True, overlap=0.25) with `run(x, xt) -> (x, xt)`."""
    length = mix.shape[1]
    out = np.zeros((4, 2, length))
    total = np.zeros(length)
    w = weights()
    for offset in range(0, length, STRIDE):
        n = min(SEGMENT, length - offset)
        delta = SEGMENT - n
        start = offset - delta // 2
        seg = np.zeros((2, SEGMENT))
        a, b = max(0, start), min(length, start + SEGMENT)
        seg[:, a - start:b - start] = mix[:, a:b]
        x, xt, stats = prepare(seg)
        y = finish(*run(x, xt), stats)[..., delta // 2:delta // 2 + n]
        out[..., offset:offset + n] += w[:n] * y
        total[offset:offset + n] += w[:n]
    return out / total
