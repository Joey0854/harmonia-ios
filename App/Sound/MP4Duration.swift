import Foundation

/// The length of a fragmented MP4 (as YouTube serves its m4a audio), from the file itself:
/// the sample durations of every fragment (`moof/traf/trun`, with `tfhd` and `trex` defaults)
/// over the track's time scale (`mdhd`). AVFoundation reports about twice the real length for
/// these files (seen on every song, and on Tests/Fixtures/song-fragmented.m4a: 11.975 s for 6 s).
/// Nil for files without fragments or that cannot be read.
public enum MP4Duration {
    public static func fragmented(_ url: URL) -> Double? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return fragmented(data)
    }

    public static func fragmented(_ data: Data) -> Double? {
        var timescale: UInt32 = 0
        var defaultDuration: UInt32 = 0     // trex
        var total: UInt64 = 0
        var fragments = 0
        let bytes = [UInt8](data)
        let n = bytes.count

        func u32(_ at: Int) -> UInt32 {
            guard at + 4 <= n else { return 0 }
            return UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
        }
        func u64(_ at: Int) -> UInt64 { return UInt64(u32(at)) << 32 | UInt64(u32(at + 4)) }
        func type(_ at: Int) -> String {
            guard at + 4 <= n else { return "" }
            return String(bytes: bytes[at..<(at + 4)], encoding: .ascii) ?? ""
        }
        /* calls `visit` for each box in [from, to): (type, start of content, end) */
        func boxes(_ from: Int, _ to: Int, _ visit: (String, Int, Int) -> Void) {
            var p = from
            while p + 8 <= to {
                var size = Int(u32(p))
                var header = 8
                if size == 1 { size = Int(truncatingIfNeeded: u64(p + 8)); header = 16 }
                if size == 0 { size = to - p }
                guard size >= header, p + size <= to else { return }
                visit(type(p + 4), p + header, p + size)
                p += size
            }
        }

        boxes(0, n) { t, start, end in
            if t == "moov" {
                boxes(start, end) { t2, s2, e2 in
                    if t2 == "trak" {
                        boxes(s2, e2) { t3, s3, e3 in
                            guard t3 == "mdia" else { return }
                            boxes(s3, e3) { t4, s4, _ in
                                guard t4 == "mdhd", timescale == 0 else { return }
                                let version = bytes[s4]
                                timescale = version == 1 ? u32(s4 + 4 + 16) : u32(s4 + 4 + 8)
                            }
                        }
                    } else if t2 == "mvex" {
                        boxes(s2, e2) { t3, s3, _ in
                            /* trex: version/flags, track id, description index, duration, ... */
                            if t3 == "trex" { defaultDuration = u32(s3 + 12) }
                        }
                    }
                }
            } else if t == "moof" {
                fragments += 1
                boxes(start, end) { t2, s2, e2 in
                    guard t2 == "traf" else { return }
                    var fragmentDefault = defaultDuration
                    boxes(s2, e2) { t3, s3, _ in
                        let flags = u32(s3) & 0xFFFFFF
                        if t3 == "tfhd" {
                            var p = s3 + 8                       // version/flags, track id
                            if flags & 0x01 != 0 { p += 8 }      // base data offset
                            if flags & 0x02 != 0 { p += 4 }      // sample description index
                            if flags & 0x08 != 0 { fragmentDefault = u32(p) }
                        } else if t3 == "trun" {
                            let count = Int(u32(s3 + 4))
                            var p = s3 + 8
                            if flags & 0x01 != 0 { p += 4 }      // data offset
                            if flags & 0x04 != 0 { p += 4 }      // first sample flags
                            let hasDuration = flags & 0x100 != 0
                            var per = 0
                            if hasDuration { per += 4 }
                            if flags & 0x200 != 0 { per += 4 }
                            if flags & 0x400 != 0 { per += 4 }
                            if flags & 0x800 != 0 { per += 4 }
                            if hasDuration {
                                for i in 0..<count { total += UInt64(u32(p + i * per)) }
                            } else {
                                total += UInt64(count) * UInt64(fragmentDefault)
                            }
                        }
                    }
                }
            }
        }
        guard fragments > 0, timescale > 0, total > 0 else { return nil }
        return Double(total) / Double(timescale)
    }
}
