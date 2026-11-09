import AVFoundation
import Foundation

/// Reads a song file as plain samples, piece by piece, starting anywhere in the song.
///
/// This is the only file of the sound code that needs AVFoundation (the decoder for the
/// compressed audio lives there); everything else works on arrays of numbers.
///
/// The system's reader does not survive everything: one that is open when the app is suspended
/// is dead afterwards ("Operation Interrupted", -11847). So when reading fails, the reader is
/// thrown away and a new one is opened where the old one stopped; the caller sees an unbroken
/// stream. Only after three attempts in a row without getting any further (at once, after
/// 0.3 s, after 1 s) is the error passed on.
///
/// Finding the exact sample again: a reader that is started in the middle of a song does not
/// deliver the same samples as one that began at the start of the file (seen in the tests).
/// So the new reader always begins at the start of the file, and what lies before the wanted
/// sample is decoded and thrown away - decoding is some hundred times faster than playing,
/// and a few seconds of sound are already waiting to be played. The last samples that were
/// handed out are then looked for in what the new reader delivers, and reading carries on
/// right after them.
///
/// `exact: true` opens a song the same way from the beginning on: slower to start when the
/// starting point is far into the song, but the samples are exactly those of the song from
/// that point (used where two songs must line up, as in a mix).
///
/// Use from one queue. Typical use: `let d = try SongDecoder(url:startAt:)`, then
/// `while let piece = try d.next() { ... }`.
public final class SongDecoder {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// Length in seconds as the file states it. For songs delivered in fragments iOS can
    /// state about twice the real length; the real end is where `next()` returns nil.
    public let statedDuration: Double
    /// Known after the first `next()`.
    public private(set) var sampleRate: Double = 0
    public private(set) var channelCount = 0
    /// Where in the song the first returned sample lies, in seconds. Known after the first
    /// `next()`; close to `startAt` but not necessarily equal.
    public private(set) var startTime: Double = 0
    /// Samples (per channel) returned so far.
    public private(set) var framesRead = 0
    /// Told (on the decoding queue) each time the file had to be opened again, in words fit
    /// for a log.
    public var onReopen: ((String) -> Void)?

    private let url: URL
    private let requestedStart: Double
    private let exactStart: Bool
    private var reader: AVAssetReader
    private var output: AVAssetReaderTrackOutput
    private var first = true
    /// Attempts to open the file again since the last piece that was read.
    private var tries = 0
    /// Decoded after opening again and not handed out yet.
    private var carry: (left: [Float], right: [Float])?
    /// The last samples handed out (left channel), to find the same place again.
    private var tail: [Float] = []
    /// How the place was found the last time the file was opened again (for the log).
    private var joinNote = ""

    private static let backOff: [TimeInterval] = [0, 0.3, 1.0]
    /// Samples decoded before the place where reading is taken up again: the decoder needs
    /// the pieces just before to give the right sound, and the search needs room.
    private static let runUp = 16384
    private static let tailLength = 1024

    public init(url: URL, startAt: Double = 0, exact: Bool = false) throws {
        self.url = url
        requestedStart = max(0, startAt)
        exactStart = exact && startAt > 0
        let start = startAt > 0 && !exact ? CMTime(seconds: startAt, preferredTimescale: 44100) : nil
        let opened = try SongDecoder.open(url, at: start)
        reader = opened.reader
        output = opened.output
        /* AVFoundation states about twice the real length for fragmented files (YouTube's
           m4a); their fragments give the real one. */
        statedDuration = (url.isFileURL ? SongDecoder.fragmentedLength(url) : nil) ?? opened.duration
    }

    private static let lengthLock = NSLock()
    private static var lengths: [String: Double] = [:]

    /* Worked out once per file (by path and size). */
    private static func fragmentedLength(_ url: URL) -> Double? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        let key = url.path + "|" + String(size)
        lengthLock.lock()
        if let known = lengths[key] {
            lengthLock.unlock()
            return known > 0 ? known : nil
        }
        lengthLock.unlock()
        let found = MP4Duration.fragmented(url)
        lengthLock.lock()
        if lengths.count > 64 { lengths.removeAll() }
        lengths[key] = found ?? 0
        lengthLock.unlock()
        return found
    }

    deinit {
        reader.cancelReading()
    }

    private static func open(_ url: URL, at start: CMTime?) throws -> (reader: AVAssetReader, output: AVAssetReaderTrackOutput, duration: Double) {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw Failure(description: "no audio track in \(url.lastPathComponent)")
        }
        let seconds = asset.duration.seconds
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw Failure(description: "cannot read \(url.lastPathComponent): \(SongDecoder.describe(error))")
        }
        /* 32-bit float, channels side by side, at the song's own rate and channel count. */
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw Failure(description: "decoder refuses this track")
        }
        reader.add(output)
        if let start = start {
            reader.timeRange = CMTimeRange(start: start, duration: .positiveInfinity)
        }
        guard reader.startReading() else {
            throw Failure(description: "decoder did not start: \(SongDecoder.describe(reader.error))")
        }
        return (reader, output, seconds.isFinite ? seconds : 0)
    }

    /// The next piece of the song (both arrays the same length; a mono song is given twice),
    /// or nil at the end.
    public func next() throws -> (left: [Float], right: [Float])? {
        while true {
            do {
                let piece = try read()
                tries = 0
                if let p = piece { remember(p.left) }
                return piece
            } catch {
                guard tries < SongDecoder.backOff.count else { throw error }
                let wait = SongDecoder.backOff[tries]
                tries += 1
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                let began = Date()
                let place = String(format: "%.3f", resumeTime)
                do {
                    try reopen()
                    let took = String(format: "%.3f", Date().timeIntervalSince(began))
                    onReopen?("decoder reopened at \(place) s after \(error) (try \(tries)), took \(took) s\(joinNote)")
                } catch let again {
                    /* Still the old, dead reader: the next round fails again and counts as a try. */
                    onReopen?("decoder could not be reopened at \(place) s after \(error) (try \(tries)): \(again)")
                }
            }
        }
    }

    /// Makes the reader unusable, as the system does when the app is suspended. For tests.
    public func breakReaderForTesting() {
        reader.cancelReading()
    }

    /// Where the next sample lies, in seconds from the start of the song.
    private var resumeTime: Double {
        return first ? requestedStart : startTime + Double(framesRead) / sampleRate
    }

    private func remember(_ left: [Float]) {
        let keep = SongDecoder.tailLength
        if left.count >= keep {
            tail = Array(left[(left.count - keep)...])
        } else {
            tail.append(contentsOf: left)
            if tail.count > keep { tail.removeFirst(tail.count - keep) }
        }
    }

    private func reopen() throws {
        joinNote = ""
        if first {
            /* Nothing was read yet: simply begin again. */
            let seek = requestedStart > 0 && !exactStart
            let opened = try SongDecoder.open(url, at: seek ? CMTime(seconds: requestedStart, preferredTimescale: 44100) : nil)
            reader.cancelReading()
            reader = opened.reader
            output = opened.output
            return
        }
        /* The sample of the song (counted from its start) that must come next. */
        let frame = Int64((startTime * sampleRate).rounded()) + Int64(framesRead)
        let opened = try SongDecoder.open(url, at: nil)
        reader.cancelReading()
        reader = opened.reader
        output = opened.output
        carry = nil
        let found = try gather(frame: frame, seconds: 0)
        let left = found.left
        /* Where counting from the start of the file puts the sample ... */
        let counted = found.at
        var join = counted
        /* ... and where the sound says it is: right after the last samples handed out. */
        let m = tail.count
        var energy: Float = 0
        for v in tail { energy += abs(v) }
        if m >= 256, energy > 1e-4 * Float(m), left.count >= m {
            let low = max(0, counted - m - 12000)
            let high = min(left.count - m, counted - m + 12000)
            var best = Float.greatestFiniteMagnitude
            var bestAt = -1
            if high >= low {
                left.withUnsafeBufferPointer { l in
                    tail.withUnsafeBufferPointer { t in
                        for k in low...high {
                            var difference: Float = 0
                            var i = 0
                            while i < m && difference < best {
                                difference += abs(l[k + i] - t[i])
                                i += 1
                            }
                            if i == m && difference < best {
                                best = difference
                                bestAt = k
                            }
                        }
                    }
                }
            }
            if bestAt >= 0 && best < 1e-4 * Float(m) {
                join = bestAt + m
                if join != counted { joinNote = ", found \(join - counted) samples from where counting put it" }
            } else {
                joinNote = ", place taken by counting (the sound was not found again)"
            }
        } else {
            joinNote = ", place taken by counting"
        }
        carry = (Array(found.left[join...]), Array(found.right[join...]))
    }

    /// Reads from the start of the file (where the reader must stand) up to a little past the
    /// wanted sample - given as `frame`, or when that is nil as `seconds` - and returns the
    /// sound from a little before it on, with the index of the wanted sample in it.
    private func gather(frame: Int64?, seconds: Double) throws -> (left: [Float], right: [Float], at: Int, target: Int64) {
        let margin = Int64(SongDecoder.runUp)
        var left: [Float] = [], right: [Float] = []
        var target = frame
        var position: Int64 = 0      // samples from the start of the file of the next piece
        var collectedFrom: Int64 = 0
        var collecting = false
        while let piece = try decodeOne() {
            var wanted: Int64 = 0
            if let known = target {
                wanted = known
            } else {
                wanted = Int64((seconds * sampleRate).rounded())
                target = wanted
            }
            let end = position + Int64(piece.left.count)
            if !collecting && end <= wanted - margin {
                position = end      // far before the wanted sample: not kept
                continue
            }
            if !collecting {
                collecting = true
                collectedFrom = position
            }
            left.append(contentsOf: piece.left)
            right.append(contentsOf: piece.right)
            position = end
            if position >= wanted + margin { break }
        }
        let wanted = target ?? 0
        let at = collecting ? Int(min(max(0, wanted - collectedFrom), Int64(left.count))) : 0
        return (left, right, at, wanted)
    }

    private func read() throws -> (left: [Float], right: [Float])? {
        if let waiting = carry {
            carry = nil
            if !waiting.left.isEmpty {
                framesRead += waiting.left.count
                return waiting
            }
        }
        if first && exactStart {
            /* Begin at the start of the file and throw away what lies before the wanted place. */
            let found = try gather(frame: nil, seconds: requestedStart)
            first = false
            startTime = sampleRate > 0 ? Double(found.target) / sampleRate : requestedStart
            let left = Array(found.left[found.at...])
            let right = Array(found.right[found.at...])
            if left.isEmpty { return nil }
            framesRead += left.count
            return (left, right)
        }
        guard let piece = try decodeOne() else { return nil }
        if first {
            first = false
            startTime = piece.time.isFinite ? max(0, piece.time) : 0
        }
        framesRead += piece.left.count
        return (piece.left, piece.right)
    }

    /// One piece from the system's reader, with the place it claims for it (in seconds, and in
    /// samples from the start of the song). nil at the end of the song.
    private func decodeOne() throws -> (left: [Float], right: [Float], time: Double, frame: Int64)? {
        while true {
            guard let sample = output.copyNextSampleBuffer() else {
                switch reader.status {
                case .completed:
                    return nil
                case .failed:
                    throw Failure(description: "decoding failed: \(SongDecoder.describe(reader.error))")
                case .cancelled:
                    throw Failure(description: "decoding was cancelled")
                default:
                    throw Failure(description: "decoder gave nothing (state \(reader.status.rawValue))")
                }
            }
            let frames = CMSampleBufferGetNumSamples(sample)
            if frames <= 0 { continue }
            guard let description = CMSampleBufferGetFormatDescription(sample),
                  let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
                  let block = CMSampleBufferGetDataBuffer(sample) else {
                throw Failure(description: "decoder gave a piece without data")
            }
            let channels = Int(basic.mChannelsPerFrame)
            let length = CMBlockBufferGetDataLength(block)
            guard channels >= 1, length >= frames * channels * 4 else {
                throw Failure(description: "decoder gave \(length) bytes for \(frames) frames of \(channels) channels")
            }
            var raw = [Float](repeating: 0, count: frames * channels)
            let status = raw.withUnsafeMutableBytes { bytes -> OSStatus in
                guard let base = bytes.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: frames * channels * 4, destination: base)
            }
            guard status == 0 else {
                throw Failure(description: "cannot copy decoded samples (\(status))")
            }
            if sampleRate == 0 {
                sampleRate = basic.mSampleRate
                channelCount = channels
            }
            var left = [Float](repeating: 0, count: frames)
            var right = [Float](repeating: 0, count: frames)
            if channels == 1 {
                left = raw
                right = raw
            } else {
                for i in 0..<frames {
                    left[i] = raw[i * channels]
                    right[i] = raw[i * channels + 1]
                }
            }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let frame = time.isFinite ? Int64((time * basic.mSampleRate).rounded()) : 0
            return (left, right, time, frame)
        }
    }

    /// An error in a form that can be told apart in a log: where it comes from, its number,
    /// its text.
    public static func describe(_ error: Error?) -> String {
        guard let e = error as NSError? else { return "unknown" }
        var text = "\(e.domain) \(e.code) \(e.localizedDescription)"
        if let under = e.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " (\(under.domain) \(under.code))"
        }
        return text
    }
}
