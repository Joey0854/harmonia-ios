import Foundation

/// A WAV file read into memory: one array of samples (−1…1) per channel.
/// Understands 16/24/32-bit whole-number PCM and 32-bit float, plain or "extensible" headers.
public struct WavFile {
    public let sampleRate: Int
    public let channels: [[Float]]

    public struct ParseError: Error, CustomStringConvertible {
        public let description: String
    }

    public init(data: Data) throws {
        let b = [UInt8](data)
        func u16(_ o: Int) -> Int {
            let low = Int(b[o]), high = Int(b[o + 1])
            return low | (high << 8)
        }
        func u32(_ o: Int) -> Int { return u16(o) | (u16(o + 2) << 16) }
        func tag(_ o: Int) -> String { return String(bytes: b[o..<(o + 4)], encoding: .ascii) ?? "" }

        guard b.count >= 12, tag(0) == "RIFF", tag(8) == "WAVE" else {
            throw ParseError(description: "not a WAV file")
        }
        var format = 0, channelCount = 0, rate = 0, bits = 0
        var dataStart = -1, dataLength = 0
        var o = 12
        while o + 8 <= b.count {
            let id = tag(o)
            let size = u32(o + 4)
            let body = o + 8
            if id == "fmt ", size >= 16, body + 16 <= b.count {
                format = u16(body)
                channelCount = u16(body + 2)
                rate = u32(body + 4)
                bits = u16(body + 14)
                /* "Extensible" files keep the real format code further in. */
                if format == 0xFFFE, size >= 26, body + 26 <= b.count { format = u16(body + 24) }
            } else if id == "data" {
                dataStart = body
                dataLength = min(size, b.count - body)
                break
            }
            o = body + size + (size & 1)
        }
        guard dataStart >= 0, channelCount >= 1, channelCount <= 8, rate > 0 else {
            throw ParseError(description: "WAV header incomplete")
        }
        let width = bits / 8
        guard (format == 1 && (bits == 16 || bits == 24 || bits == 32)) || (format == 3 && bits == 32) else {
            throw ParseError(description: "WAV format \(format) with \(bits) bits is not supported")
        }
        let frames = dataLength / (width * channelCount)
        var out = [[Float]](repeating: [Float](repeating: 0, count: frames), count: channelCount)
        for i in 0..<frames {
            for c in 0..<channelCount {
                let p = dataStart + (i * channelCount + c) * width
                var value: Float = 0
                if format == 3 {
                    value = Float(bitPattern: UInt32(truncatingIfNeeded: u32(p)))
                } else if bits == 16 {
                    value = Float(Int16(truncatingIfNeeded: u16(p))) / 32768
                } else if bits == 24 {
                    let top = Int(b[p + 2]) << 16
                    let shifted: Int = (u16(p) | top) << 8
                    let raw = Int32(truncatingIfNeeded: shifted) >> 8
                    value = Float(raw) / 8388608
                } else {
                    value = Float(Int32(truncatingIfNeeded: u32(p))) / 2147483648
                }
                out[c][i] = value
            }
        }
        sampleRate = rate
        channels = out
    }
}
