import CoreML
import Foundation

/// The HTDemucs network body as a Core ML model, for the "band" surround modes. The model is
/// made from demucs' htdemucs by tools/band/convert.py on the build machine and lies in the app
/// as BandModel/HTDemucsBody.mlmodelc; the transform and everything else around it is done in
/// App/Sound (`Demucs`, `BandSplitter`, `BandProcessor`).
///
/// Loading takes a while and starts the first time a band mode is used; the network handed
/// out waits for it on the band queue, never on the thread that feeds playback. If the model
/// is missing or does not load, every run fails and the band modes play the original sound.
final class BandModel: BandNetwork {
    static let shared = BandModel()

    /// GPU and CPU: the Neural Engine is left out, since its compile of a model this size can
    /// take minutes and the inverse transforms it cannot do anyway are not in the model.
    static let computeUnits = MLComputeUnits.cpuAndGPU

    private let lock = NSLock()
    private var model: MLModel?
    private var trouble: String?
    private var loading = false
    private let loaded = DispatchSemaphore(value: 0)

    struct Unavailable: Error, CustomStringConvertible {
        let description: String
    }

    /// Starts loading (once) and returns the network; for `SurroundChain.bandNetwork`.
    func network() -> BandNetwork? {
        lock.lock()
        let start = !loading
        loading = true
        lock.unlock()
        if start {
            /* not on the band queue: the network waits for this there */
            DispatchQueue.global(qos: .userInitiated).async { self.load() }
        }
        return self
    }

    private func load() {
        let began = Date()
        var made: MLModel?
        var problem: String?
        let url = Bundle.main.bundleURL.appendingPathComponent("BandModel/HTDemucsBody.mlmodelc")
        if FileManager.default.fileExists(atPath: url.path) {
            let config = MLModelConfiguration()
            config.computeUnits = BandModel.computeUnits
            do {
                made = try MLModel(contentsOf: url, configuration: config)
            } catch {
                problem = "model does not load: \(error)"
            }
        } else {
            problem = "model not in the app"
        }
        lock.lock()
        model = made
        trouble = problem
        lock.unlock()
        if let p = problem {
            Diag.shared.log("band: \(p)", error: true)
        } else {
            Diag.shared.log(String(format: "band: model loaded in %.1f s (compute units: cpuAndGPU)", Date().timeIntervalSince(began)))
        }
        /* everybody who waits gets through */
        for _ in 0..<64 { loaded.signal() }
    }

    func run(spec: [Float], wave: [Float]) throws -> (spec: [Float], wave: [Float]) {
        lock.lock()
        var m = model
        var t = trouble
        lock.unlock()
        if m == nil && t == nil {
            _ = loaded.wait(timeout: .now() + 600)
            lock.lock()
            m = model
            t = trouble
            lock.unlock()
        }
        guard let mlmodel = m else { throw Unavailable(description: t ?? "model not loaded") }

        let plane = Demucs.bins * Demucs.frames
        let a = try MLMultiArray(shape: [1, 4, NSNumber(value: Demucs.bins), NSNumber(value: Demucs.frames)], dataType: .float32)
        let b = try MLMultiArray(shape: [1, 2, NSNumber(value: Demucs.segment)], dataType: .float32)
        try BandModel.fill(a, spec, count: 4 * plane)
        try BandModel.fill(b, wave, count: 2 * Demucs.segment)
        let input = try MLDictionaryFeatureProvider(dictionary: ["spec": MLFeatureValue(multiArray: a),
                                                                 "wave": MLFeatureValue(multiArray: b)])
        let out = try mlmodel.prediction(from: input)
        guard let s = out.featureValue(for: "spec_out")?.multiArrayValue,
              let w = out.featureValue(for: "wave_out")?.multiArrayValue else {
            throw Unavailable(description: "model gave no spec_out / wave_out")
        }
        return (try BandModel.read(s), try BandModel.read(w))
    }

    private static func fill(_ array: MLMultiArray, _ values: [Float], count: Int) throws {
        guard values.count == count, array.count == count else {
            throw Unavailable(description: "input of \(values.count) values for \(array.count)")
        }
        let p = array.dataPointer.bindMemory(to: Float.self, capacity: count)
        values.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { p.update(from: base, count: count) }
        }
    }

    /// The values in row-major order, whatever the array's strides and number type.
    private static func read(_ array: MLMultiArray) throws -> [Float] {
        guard [.float32, .double, .float16].contains(array.dataType) else {
            throw Unavailable(description: "unexpected output type \(array.dataType.rawValue)")
        }
        let shape = array.shape.map { $0.intValue }
        let strides = array.strides.map { $0.intValue }
        let total = shape.reduce(1, *)
        var out = [Float](repeating: 0, count: total)
        let rank = shape.count
        var index = [Int](repeating: 0, count: rank)
        func element(_ offset: Int) -> Float {
            switch array.dataType {
            case .float32: return array.dataPointer.assumingMemoryBound(to: Float.self)[offset]
            case .double: return Float(array.dataPointer.assumingMemoryBound(to: Double.self)[offset])
            case .float16: return Float(array.dataPointer.assumingMemoryBound(to: Float16.self)[offset])
            default: return 0
            }
        }
        guard rank > 0 else { return out }
        let inner = shape[rank - 1], innerStride = strides[rank - 1]
        var o = 0
        while o < total {
            var base = 0
            for d in 0..<(rank - 1) { base += index[d] * strides[d] }
            if array.dataType == .float32 && innerStride == 1 {
                let p = array.dataPointer.assumingMemoryBound(to: Float.self) + base
                out.withUnsafeMutableBufferPointer { dst in
                    (dst.baseAddress! + o).update(from: p, count: inner)
                }
            } else {
                for k in 0..<inner { out[o + k] = element(base + k * innerStride) }
            }
            o += inner
            var d = rank - 2
            while d >= 0 {
                index[d] += 1
                if index[d] < shape[d] { break }
                index[d] = 0
                d -= 1
            }
        }
        return out
    }
}
