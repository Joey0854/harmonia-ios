import Foundation
import Accelerate

/*
 "Measure this car": the test sound the app plays next to each speaker of a car, and the
 analysis of what the phone's own microphone recorded there. Pure functions only (no audio
 session, no files), so that they can be tested with `swift test`; App/CarProbe.swift does the
 playing, recording and uploading.

 The method follows the upmix probe made for the PC (pink noise in a band, a few left / right
 relations, a fixed total level per cell, levels relative to the "B1 in phase, centred" cell),
 shortened to about 13 seconds per position:

   0.0 - 0.6 s   silence (the background noise is measured in the 0.3 s before the beep)
   0.6 - 0.9 s   the alignment beep (a rising sweep, both channels the same)
   1.3 s         10 cells of 1.0 s each, 0.1 s of silence between them
   12.2 - 12.7 s silence

 In each cell only the middle 0.6 s is measured (0.2 - 0.8 s after the cell starts).
 Everything is made from fixed random seeds: the same sample rate always gives the same samples.
 */

/// One cell of the probe.
public struct CarProbeCell: Equatable {
    /// e.g. "B1/inphase/+15": band / left-right relation / left minus right in dB
    public let id: String
    public let band: String
    public let state: String
    /// left level minus right level, dB
    public let diffDb: Double
    /// seconds from the start of the probe
    public let start: Double
    public let seed: UInt64

    /// The cell's definition as it goes into the upload.
    public var definition: [String: Any] {
        let (lo, hi) = CarProbe.bands[band] ?? (0, 0)
        let (gl, gr) = CarProbe.channelGains(diffDb: diffDb)
        return [
            "id": id, "band": band, "state": state, "diffDb": diffDb,
            "bandHz": [lo, hi], "start": start, "duration": CarProbe.cellDuration,
            "analysisStart": start + CarProbe.analysisOffset,
            "analysisEnd": start + CarProbe.analysisOffset + CarProbe.analysisLength,
            "leftDb": (20 * log10(gl) * 1000).rounded() / 1000,
            "rightDb": (20 * log10(gr) * 1000).rounded() / 1000,
            "seed": Int(seed)
        ]
    }
}

public enum CarProbe {
    /// Changes whenever the sound or the timing changes; goes into every upload.
    public static let version = "carprobe-1"

    public static let beepStart = 0.6
    public static let beepDuration = 0.3
    public static let beepLowHz = 300.0
    public static let beepHighHz = 6000.0
    public static let beepDbfs = -12.0
    public static let firstCell = 1.3
    public static let cellDuration = 1.0
    public static let cellGap = 0.1
    public static let analysisOffset = 0.2
    public static let analysisLength = 0.6
    public static let tail = 0.5
    /// sqrt(power left + power right) of every cell, dBFS
    public static let totalRmsDb = -20.0
    /// the cell everything is measured against
    public static let referenceId = "B1/inphase/0"
    /// background noise: this long before the beep
    public static let noiseLength = 0.3

    public static let bands: [String: (Double, Double)] = [
        "B1": (250, 4000), "B2": (4000, 10000), "LF": (40, 120)
    ]

    public static let cells: [CarProbeCell] = {
        let list: [(String, String, Double)] = [
            ("B1", "inphase", 0), ("B1", "inphase", 15), ("B1", "inphase", -15),
            ("B1", "indep", 0), ("B1", "anti", 0), ("B1", "anti", 15),
            ("B2", "inphase", 0), ("B2", "anti", 0),
            ("LF", "inphase", 0), ("LF", "anti", 0)
        ]
        return list.enumerated().map { k, c in
            let sign = c.2 == 0 ? "0" : (c.2 > 0 ? "+" : "") + String(Int(c.2))
            return CarProbeCell(id: "\(c.0)/\(c.1)/\(sign)", band: c.0, state: c.1, diffDb: c.2,
                                start: firstCell + Double(k) * (cellDuration + cellGap),
                                seed: UInt64(1000 + k))
        }
    }()

    /// Length of the whole probe, seconds.
    public static var duration: Double {
        return firstCell + Double(cells.count) * (cellDuration + cellGap) - cellGap + tail
    }

    /// Everything about the probe for the upload: timing, bands and every cell.
    public static var definition: [String: Any] {
        return [
            "version": version,
            "duration": duration,
            "beep": ["start": beepStart, "duration": beepDuration, "fromHz": beepLowHz, "toHz": beepHighHz, "dbfs": beepDbfs] as [String: Any],
            "totalRmsDb": totalRmsDb,
            "reference": referenceId,
            "noise": ["before": "beep", "length": noiseLength] as [String: Any],
            "bands": bands.mapValues { [$0.0, $0.1] },
            "notes": "diffDb = left dB minus right dB; pink noise in the band; levels are band RMS of the middle 0.6 s, relative to \(referenceId)",
            "cells": cells.map { $0.definition }
        ]
    }

    /// Left and right gain for a level difference, keeping power left + power right = 2.
    public static func channelGains(diffDb: Double) -> (Double, Double) {
        let r = pow(10, diffDb / 20)
        let gr = (2 / (1 + r * r)).squareRoot()
        return (r * gr, gr)
    }

    // MARK: the sound

    /// The alignment beep: a logarithmic sweep with 10 ms fades.
    public static func beep(sampleRate: Double) -> [Float] {
        let n = Int((beepDuration * sampleRate).rounded())
        let k = log(beepHighHz / beepLowHz)
        let amp = pow(10, beepDbfs / 20)
        let fade = max(1, Int(0.01 * sampleRate))
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let phase = 2 * Double.pi * beepLowHz * beepDuration / k * (exp(t / beepDuration * k) - 1)
            var w = 1.0
            if i < fade { w = 0.5 - 0.5 * cos(Double.pi * Double(i) / Double(fade)) }
            if i >= n - fade { w = 0.5 - 0.5 * cos(Double.pi * Double(n - 1 - i) / Double(fade)) }
            out[i] = Float(amp * sin(phase) * w)
        }
        return out
    }

    /// The whole probe, stereo, at this sample rate.
    public static func generate(sampleRate: Double) -> (left: [Float], right: [Float]) {
        let total = Int((duration * sampleRate).rounded())
        var left = [Float](repeating: 0, count: total)
        var right = [Float](repeating: 0, count: total)
        let b = beep(sampleRate: sampleRate)
        let b0 = Int((beepStart * sampleRate).rounded())
        for i in 0..<b.count where b0 + i < total {
            left[b0 + i] = b[i]
            right[b0 + i] = b[i]
        }
        for cell in cells {
            let (l, r) = makeCell(cell, sampleRate: sampleRate)
            let s0 = Int((cell.start * sampleRate).rounded())
            for i in 0..<l.count where s0 + i < total {
                left[s0 + i] = l[i]
                right[s0 + i] = r[i]
            }
        }
        return (left, right)
    }

    /// One cell: band-limited pink noise, centre / independent / opposite phase, then the level
    /// difference, at the fixed total level (measured over the analysis window, as on the PC).
    static func makeCell(_ cell: CarProbeCell, sampleRate: Double) -> ([Float], [Float]) {
        let n = Int((cellDuration * sampleRate).rounded())
        let (lo, hi) = bands[cell.band] ?? (250, 4000)
        let w0 = Int((analysisOffset * sampleRate).rounded())
        let w1 = min(n, w0 + Int((analysisLength * sampleRate).rounded()))
        var rng = CarProbeRandom(seed: cell.seed)

        func dot(_ a: [Double], _ b: [Double]) -> Double {
            var s = 0.0
            for i in w0..<w1 { s += a[i] * b[i] }
            return s
        }
        func unit(_ a: [Double]) -> [Double] {
            let rms = (dot(a, a) / Double(w1 - w0)).squareRoot()
            return rms > 0 ? a.map { $0 / rms } : a
        }
        let c = unit(bandNoise(count: n, lo: lo, hi: hi, sampleRate: sampleRate, rng: &rng))
        var other: [Double] = c
        switch cell.state {
        case "anti":
            other = c.map { -$0 }
        case "indep":
            var m = bandNoise(count: n, lo: lo, hi: hi, sampleRate: sampleRate, rng: &rng)
            let p = dot(m, c) / dot(c, c)
            for i in 0..<n { m[i] -= p * c[i] }
            other = unit(m)
        default:
            break
        }
        let (gl, gr) = channelGains(diffDb: cell.diffDb)
        let s = (pow(10, totalRmsDb / 10) / 2).squareRoot()
        let fade = max(1, Int(0.01 * sampleRate))
        var l = [Float](repeating: 0, count: n)
        var r = [Float](repeating: 0, count: n)
        for i in 0..<n {
            var w = 1.0
            if i < fade { w = 0.5 - 0.5 * cos(Double.pi * Double(i) / Double(fade)) }
            if i >= n - fade { w = 0.5 - 0.5 * cos(Double.pi * Double(n - 1 - i) / Double(fade)) }
            l[i] = Float(s * gl * c[i] * w)
            r[i] = Float(s * gr * other[i] * w)
        }
        return (l, r)
    }

    /// Pink noise strictly between lo and hi (random spectrum, inverse FFT), `count` samples.
    static func bandNoise(count: Int, lo: Double, hi: Double, sampleRate: Double, rng: inout CarProbeRandom) -> [Double] {
        var size = 1
        var log2n: vDSP_Length = 0
        while size < count { size <<= 1; log2n += 1 }
        var re = [Double](repeating: 0, count: size)
        var im = [Double](repeating: 0, count: size)
        for k in 1..<(size / 2) {
            let f = Double(k) * sampleRate / Double(size)
            if f < lo || f > hi { continue }
            let h = 1 / f.squareRoot()
            let a = rng.gaussian() * h
            let b = rng.gaussian() * h
            re[k] = a
            im[k] = b
            re[size - k] = a
            im[size - k] = -b
        }
        guard let setup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2)) else {
            return [Double](repeating: 0, count: count)
        }
        defer { vDSP_destroy_fftsetupD(setup) }
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zipD(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
            }
        }
        return Array(re[0..<count])
    }
}

/// Repeatable random numbers (xorshift64*), with normally distributed values.
public struct CarProbeRandom {
    private var state: UInt64
    public init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    public mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 2685821657736338717
    }
    /// evenly spread in (0, 1)
    public mutating func uniform() -> Double {
        return (Double(next() >> 11) + 0.5) / 9007199254740992
    }
    public mutating func gaussian() -> Double {
        let u = uniform(), v = uniform()
        return (-2 * log(u)).squareRoot() * cos(2 * Double.pi * v)
    }
}

// MARK: - the analysis

/// Where the beep was found in a recording.
public struct CarProbeSync: Equatable {
    /// sample of the recording where the beep starts
    public let sample: Int
    /// normalised cross-correlation at that place (0 ... 1)
    public let ncc: Double
    /// that peak against the median of the whole search
    public let ratio: Double
    public var found: Bool { return ncc >= CarProbeAnalyzer.minNcc && ratio >= CarProbeAnalyzer.minRatio }
}

/// What one position's recording says.
public struct CarProbeResult {
    public var sync: CarProbeSync?
    /// seconds between the start of the recording and the start of the probe in it
    public var latency: Double = 0
    /// cell id -> dB relative to the reference cell (only finite numbers)
    public var levels: [String: Double] = [:]
    /// cell id -> band RMS in dBFS
    public var absolute: [String: Double] = [:]
    /// band -> background noise in dBFS (the 0.3 s before the beep)
    public var noise: [String: Double] = [:]
    /// the reference cell above the background noise in its band, dB (nil: not measurable)
    public var snrDb: Double?
    public var peak: Double = 0
    public var clipped = false
    /// cells less than 6 dB above the noise of their band (their numbers are not reliable)
    public var lowCells: [String] = []
    /// cell id -> that cell above the background noise of its band, dB (only finite numbers)
    public var snrByCell: [String: Double] = [:]
    /// why it should be recorded again (empty: fine)
    public var problems: [String] = []
    public var needsRetake: Bool { return !problems.isEmpty }
}

public enum CarProbeAnalyzer {
    public static let minNcc = 0.25
    public static let minRatio = 8.0
    public static let minSnrDb = 10.0
    /// the beep is looked for in the first this many seconds of the recording
    public static let searchSeconds = 4.0
    /// the measuring filters are this much wider than the bands, so that the band edges of the
    /// probe itself are not cut (the probe has nothing outside its band)
    static let widen = 1.5

    /// Finds the beep by normalised cross-correlation.
    public static func findBeep(_ x: [Float], sampleRate: Double, searchSeconds: Double = searchSeconds) -> CarProbeSync? {
        let tmpl = CarProbe.beep(sampleRate: sampleRate)
        let p = tmpl.count
        let region = min(x.count, Int(searchSeconds * sampleRate) + p)
        guard p > 0, region > p + 1 else { return nil }
        let n = region - p + 1
        let a = Array(x[0..<region])
        var c = [Float](repeating: 0, count: n)
        vDSP_conv(a, 1, tmpl, 1, &c, 1, vDSP_Length(n), vDSP_Length(p))
        var te = 0.0
        for v in tmpl { te += Double(v) * Double(v) }
        var cum = [Double](repeating: 0, count: region + 1)
        for i in 0..<region { cum[i + 1] = cum[i] + Double(a[i]) * Double(a[i]) }
        var ncc = [Float](repeating: 0, count: n)
        var best = 0
        var bestValue = -1.0
        for i in 0..<n {
            let local = max(0, cum[i + p] - cum[i])
            let v = abs(Double(c[i])) / ((local * te).squareRoot() + 1e-12)
            ncc[i] = Float(v)
            if v > bestValue { bestValue = v; best = i }
        }
        let median = Double(ncc.sorted()[n / 2])
        return CarProbeSync(sample: best, ncc: bestValue, ratio: bestValue / (median + 1e-9))
    }

    /// Fourth-order high-pass and fourth-order low-pass (Butterworth), as biquads.
    static func bandFilter(lo: Double, hi: Double, sampleRate: Double) -> [Biquad] {
        let qs = [0.5411961001461970, 1.3065629648763766]
        var out: [Biquad] = []
        for q in qs {
            let w = 2 * Double.pi * lo / sampleRate
            let alpha = sin(w) / (2 * q)
            let a0 = 1 + alpha
            out.append(Biquad(b0: (1 + cos(w)) / 2 / a0, b1: -(1 + cos(w)) / a0, b2: (1 + cos(w)) / 2 / a0,
                              a1: -2 * cos(w) / a0, a2: (1 - alpha) / a0))
        }
        let top = min(hi, 0.45 * sampleRate)
        for q in qs {
            let w = 2 * Double.pi * top / sampleRate
            let alpha = sin(w) / (2 * q)
            let a0 = 1 + alpha
            out.append(Biquad(b0: (1 - cos(w)) / 2 / a0, b1: (1 - cos(w)) / a0, b2: (1 - cos(w)) / 2 / a0,
                              a1: -2 * cos(w) / a0, a2: (1 - alpha) / a0))
        }
        return out
    }

    /// The recording filtered to a band (the whole recording, so that every window has history).
    static func filtered(_ x: [Float], band: String, sampleRate: Double) -> [Float] {
        let (lo, hi) = CarProbe.bands[band] ?? (250, 4000)
        var f = bandFilter(lo: lo / widen, hi: hi * widen, sampleRate: sampleRate)
        var out = [Float](repeating: 0, count: x.count)
        for i in 0..<x.count {
            var v = Double(x[i])
            for k in 0..<f.count { v = f[k].step(v) }
            out[i] = Float(v)
        }
        return out
    }

    /// RMS in dBFS of samples a ..< b (nil when the range is not inside the recording).
    static func rmsDb(_ y: [Float], _ a: Int, _ b: Int) -> Double? {
        guard a >= 0, b <= y.count, b - a > 0 else { return nil }
        var s = 0.0
        for i in a..<b { s += Double(y[i]) * Double(y[i]) }
        let db = 10 * log10(s / Double(b - a) + 1e-20)
        return db.isFinite ? db : nil
    }

    /// The whole analysis of one position's recording (mono, any sample rate).
    public static func analyze(_ x: [Float], sampleRate: Double) -> CarProbeResult {
        var result = CarProbeResult()
        var peak: Float = 0
        var hot = 0
        for v in x {
            let m = abs(v)
            if m > peak { peak = m }
            if m >= 0.99 { hot += 1 }
        }
        result.peak = Double(peak)
        result.clipped = hot >= 3
        guard let sync = findBeep(x, sampleRate: sampleRate) else {
            result.problems.append("錄音太短或沒有聲音")
            return result
        }
        result.sync = sync
        if !sync.found {
            result.problems.append("錄音裡找不到定位嗶聲（喇叭太遠、音量太小，或手機麥克風沒有在錄）")
            return result
        }
        let origin = Double(sync.sample) - CarProbe.beepStart * sampleRate
        result.latency = origin / sampleRate
        func at(_ t: Double) -> Int { return Int((origin + t * sampleRate).rounded()) }

        var filteredBands: [String: [Float]] = [:]
        for band in CarProbe.bands.keys { filteredBands[band] = filtered(x, band: band, sampleRate: sampleRate) }
        let noiseEnd = sync.sample
        let noiseStart = max(0, noiseEnd - Int(CarProbe.noiseLength * sampleRate))
        if noiseEnd - noiseStart >= Int(0.1 * sampleRate) {
            for (band, y) in filteredBands {
                if let db = rmsDb(y, noiseStart, noiseEnd) { result.noise[band] = db }
            }
        }
        for cell in CarProbe.cells {
            guard let y = filteredBands[cell.band] else { continue }
            let a = at(cell.start + CarProbe.analysisOffset)
            let b = at(cell.start + CarProbe.analysisOffset + CarProbe.analysisLength)
            if let db = rmsDb(y, a, b) { result.absolute[cell.id] = db }
        }
        guard let ref = result.absolute[CarProbe.referenceId] else {
            result.problems.append("錄音太短，沒有錄完整段測試音")
            return result
        }
        for (id, db) in result.absolute {
            let rel = db - ref
            if rel.isFinite { result.levels[id] = (rel * 100).rounded() / 100 }
        }
        if result.absolute.count < CarProbe.cells.count {
            result.problems.append("錄音太短，最後幾格沒有錄到")
        }
        if let n = result.noise["B1"] {
            result.snrDb = ref - n
        }
        for cell in CarProbe.cells {
            guard let db = result.absolute[cell.id], let n = result.noise[cell.band] else { continue }
            let snr = db - n
            if snr.isFinite { result.snrByCell[cell.id] = (snr * 100).rounded() / 100 }
            if db < n + 6 { result.lowCells.append(cell.id) }
        }
        if let snr = result.snrDb {
            if snr < minSnrDb {
                result.problems.append(String(format: "訊號只比背景噪音大 %.1f dB（至少要 %.0f dB）：靠近一點、音量大一點或保持安靜", snr, minSnrDb))
            }
        } else {
            result.problems.append("量不到背景噪音（嗶聲前的錄音太短）")
        }
        if result.clipped {
            result.problems.append("錄音削波（太大聲）：把音量調小一點，或手機離喇叭遠一點")
        }
        return result
    }
}
