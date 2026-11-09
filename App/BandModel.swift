import CoreML
import Foundation
import UIKit

/// The HTDemucs network body as a Core ML model, for the "band" surround modes. The model is
/// made from demucs' htdemucs by tools/band/convert.py on the build machine and lies in the app
/// as BandModel/HTDemucsBody.mlmodelc; the transform and everything else around it is done in
/// App/Sound (`Demucs`, `BandSplitter`, `BandProcessor`).
///
/// Loading takes a while and starts the first time a band mode is used; the network handed
/// out waits for it on the band queue, never on the thread that feeds playback.
///
/// Compute units: GPU and CPU in front; CPU only while the app is in the background, where iOS
/// refuses GPU work (Metal command buffers fail with "background execution not permitted").
/// The model is reloaded for the other units when the app changes state, and a GPU run that
/// fails anyway is done again on the CPU, so no segment is lost. The Neural Engine is not used
/// (its compile of a model this size can take minutes; whether it may run in the background is
/// not verified).
///
/// On a memory warning the model is let go; it is loaded again for the next segment, at most
/// `maxReloads` times in a row without a segment going through, each try logged.
final class BandModel: BandNetwork {
    static let shared = BandModel()
    static let maxReloads = 3

    private let lock = NSLock()
    private var model: MLModel?
    private var units: MLComputeUnits?
    private var trouble: String?
    private var loading = false
    private var observing = false
    private var background = false
    private var released = false
    private var reloads = 0
    private let loaded = DispatchSemaphore(value: 0)
    /* the input arrays, made once and filled for every segment */
    private var inSpec: MLMultiArray?
    private var inWave: MLMultiArray?

    struct Unavailable: Error, CustomStringConvertible {
        let description: String
    }

    /// The compute units now in use, and whether the app is in the background (for the log).
    var label: String {
        lock.lock()
        defer { lock.unlock() }
        let u = units == .cpuOnly ? "cpuOnly" : (units == nil ? "none" : "cpuAndGPU")
        return background ? "\(u), background" : u
    }

    var inBackground: Bool {
        lock.lock()
        defer { lock.unlock() }
        return background
    }

    /// Starts loading (once) and returns the network; for `SurroundChain.bandNetwork`. Main queue.
    func network() -> BandNetwork? {
        lock.lock()
        let start = !loading
        loading = true
        let watch = !observing
        observing = true
        lock.unlock()
        if watch {
            let center = NotificationCenter.default
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in self?.setBackground(true) }
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in self?.setBackground(false) }
            center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in self?.memoryWarning() }
            /* applicationState is for the main thread only */
            if Thread.isMainThread {
                setBackground(UIApplication.shared.applicationState == .background)
            } else {
                DispatchQueue.main.async { self.setBackground(UIApplication.shared.applicationState == .background) }
            }
        }
        if start {
            /* not on the band queue: the network waits for this there */
            DispatchQueue.global(qos: .userInitiated).async {
                let units = self.wantedUnits()
                _ = try? self.ensure(units, reason: "first use")
                for _ in 0..<64 { self.loaded.signal() }
            }
        }
        return self
    }

    private func setBackground(_ on: Bool) {
        lock.lock()
        let changed = background != on
        background = on
        lock.unlock()
        if changed { Diag.shared.log("band: app \(on ? "in the background: next segments on the CPU only" : "in front again: next segments on GPU and CPU")") }
    }

    private func memoryWarning() {
        lock.lock()
        let had = model != nil
        model = nil
        units = nil
        inSpec = nil
        inWave = nil
        released = had
        lock.unlock()
        if had { Diag.shared.log("band: memory warning, model let go; it is loaded again for the next segment", error: true) }
    }

    private func wantedUnits() -> MLComputeUnits {
        return inBackground ? .cpuOnly : .cpuAndGPU
    }

    /* Loads the model for `wanted` unless it is already loaded so (band queue, or the first load). */
    private func ensure(_ wanted: MLComputeUnits, reason: String) throws -> MLModel {
        lock.lock()
        if let m = model, units == wanted {
            lock.unlock()
            return m
        }
        /* the old one goes first: two copies of 200 MB do not fit */
        model = nil
        units = nil
        lock.unlock()
        let url = Bundle.main.bundleURL.appendingPathComponent("BandModel/HTDemucsBody.mlmodelc")
        guard FileManager.default.fileExists(atPath: url.path) else {
            lock.lock()
            trouble = "model not in the app"
            lock.unlock()
            Diag.shared.log("band: model not in the app", error: true)
            throw Unavailable(description: "model not in the app")
        }
        let name = wanted == .cpuOnly ? "cpuOnly" : "cpuAndGPU"
        let began = Date()
        let config = MLModelConfiguration()
        config.computeUnits = wanted
        do {
            let made = try MLModel(contentsOf: url, configuration: config)
            lock.lock()
            model = made
            units = wanted
            trouble = nil
            lock.unlock()
            Diag.shared.log(String(format: "band: model loaded in %.1f s (compute units: %@, reason: %@), footprint %d MB",
                                   Date().timeIntervalSince(began), name, reason, PerfMonitor.mb(PerfMonitor.footprint())))
            return made
        } catch {
            lock.lock()
            trouble = "model does not load: \(error)"
            lock.unlock()
            Diag.shared.log("band: model does not load (\(name), \(reason)): \(error)", error: true)
            throw error
        }
    }

    func run(spec: [Float], wave: [Float]) throws -> (spec: [Float], wave: [Float]) {
        _ = loaded.wait(timeout: .now() + 600)
        lock.lock()
        let wasReleased = released
        lock.unlock()
        let wanted = wantedUnits()
        var mlmodel: MLModel
        do {
            mlmodel = try ensure(wanted, reason: wasReleased ? "after a memory warning" : (wanted == .cpuOnly ? "app in the background" : "app in front"))
        } catch {
            try countFailure(error)
            mlmodel = try ensure(wanted, reason: "retry")
        }
        do {
            let out = try predict(mlmodel, spec: spec, wave: wave)
            lock.lock()
            reloads = 0
            released = false
            lock.unlock()
            return out
        } catch let error where wanted != .cpuOnly {
            /* most likely the GPU refused (the app went to the background mid-segment): the same
               segment again on the CPU */
            Diag.shared.log("band: GPU run failed (\(error)); this segment again on the CPU only")
            let cpu = try ensure(.cpuOnly, reason: "GPU run failed")
            return try predict(cpu, spec: spec, wave: wave)
        }
    }

    /* Too many loads in a row without a segment going through: give up for this run. */
    private func countFailure(_ error: Error) throws {
        lock.lock()
        reloads += 1
        let n = reloads
        lock.unlock()
        Diag.shared.log("band: load try \(n) of \(BandModel.maxReloads) failed: \(error)", error: true)
        if n >= BandModel.maxReloads { throw error }
    }

    private func predict(_ mlmodel: MLModel, spec: [Float], wave: [Float]) throws -> (spec: [Float], wave: [Float]) {
        return try autoreleasepool { () throws -> (spec: [Float], wave: [Float]) in
            let plane = Demucs.bins * Demucs.frames
            lock.lock()
            if inSpec == nil {
                inSpec = try? MLMultiArray(shape: [1, 4, NSNumber(value: Demucs.bins), NSNumber(value: Demucs.frames)], dataType: .float32)
                inWave = try? MLMultiArray(shape: [1, 2, NSNumber(value: Demucs.segment)], dataType: .float32)
            }
            let a = inSpec, b = inWave
            lock.unlock()
            guard let a = a, let b = b else { throw Unavailable(description: "no memory for the inputs") }
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
