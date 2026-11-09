import Accelerate
import CoreML
import Foundation

/// A distillation student candidate (tools/student/student.py, random weights for the 1.3.11 pilot) as a
/// Core ML float16 model: StudentModel/Student<kind>.mlmodelc, made in CI. Used only by the stress test
/// (StudentStress); the band modes keep using HTDemucs (BandModel).
///
/// Compute units: CPU and Neural Engine (no GPU), so that whatever the ANE cannot take shows up as CPU
/// work. Where iOS has MLComputePlan (17.4+), the planned device of every op is logged once per load:
/// that is Core ML's plan for this phone, not a measurement of where each op ran.
final class StudentModel: StudentNetwork {
    let kind: String
    let loadSeconds: Double
    private let model: MLModel
    private let input: MLMultiArray
    private let lock = NSLock()
    private var planText = "plan: not known yet"

    struct Unavailable: Error, CustomStringConvertible {
        let description: String
    }

    static let units: MLComputeUnits = .cpuAndNeuralEngine
    static let unitsName = "cpuAndNeuralEngine"

    static func url(_ kind: String) -> URL {
        return Bundle.main.bundleURL.appendingPathComponent("StudentModel/Student\(kind).mlmodelc")
    }

    static func available(_ kind: String) -> Bool {
        return FileManager.default.fileExists(atPath: url(kind).path)
    }

    init(kind: String) throws {
        self.kind = kind
        let url = StudentModel.url(kind)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Unavailable(description: "Student\(kind) not in the app")
        }
        let config = MLModelConfiguration()
        config.computeUnits = StudentModel.units
        let began = Date()
        model = try MLModel(contentsOf: url, configuration: config)
        loadSeconds = Date().timeIntervalSince(began)
        input = try MLMultiArray(shape: [1, 4, NSNumber(value: Demucs.bins), NSNumber(value: Demucs.frames)],
                                 dataType: .float16)
        computePlan(url, config)
    }

    /// One line on where the ops are planned to run (for the log and the report).
    var plan: String {
        lock.lock()
        defer { lock.unlock() }
        return planText
    }

    private func setPlan(_ text: String) {
        lock.lock()
        planText = text
        lock.unlock()
    }

    private func computePlan(_ url: URL, _ config: MLModelConfiguration) {
        if #available(iOS 17.4, *) {
            runPlan(url, config)
        } else {
            setPlan("plan: MLComputePlan needs iOS 17.4")
        }
    }

    @available(iOS 17.4, *)
    private func runPlan(_ url: URL, _ config: MLModelConfiguration) {
        let kind = self.kind
        Task.detached {
            do {
                let plan = try await MLComputePlan.load(contentsOf: url, configuration: config)
                guard case let .program(program) = plan.modelStructure, let main = program.functions["main"] else {
                    self.setPlan("plan: not an ML program")
                    return
                }
                var counts: [String: Int] = [:]
                var off: [String: Int] = [:]
                func name(_ d: MLComputeDevice) -> String {
                    switch d {
                    case .cpu: return "CPU"
                    case .gpu: return "GPU"
                    case .neuralEngine: return "ANE"
                    @unknown default: return "other"
                    }
                }
                func walk(_ ops: [MLModelStructure.Program.Operation]) {
                    for op in ops {
                        if !op.operatorName.hasPrefix("const"), let u = plan.deviceUsage(for: op) {
                            let p = name(u.preferred)
                            counts[p, default: 0] += 1
                            if p != "ANE" { off["\(op.operatorName)→\(p)", default: 0] += 1 }
                        }
                        for b in op.blocks { walk(b.operations) }
                    }
                }
                walk(main.block.operations)
                let total = counts.values.reduce(0, +)
                let ane = counts["ANE"] ?? 0
                let devices = MLComputeDevice.allComputeDevices.map(name).joined(separator: "/")
                let text = String(format: "plan: %d of %d ops on the ANE (%.1f%%), %@; devices %@%@", ane, total,
                                  total > 0 ? 100 * Double(ane) / Double(total) : 0,
                                  counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "),
                                  devices,
                                  off.isEmpty ? "" : "; not on the ANE: " + off.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", "))
                self.setPlan(text)
                Diag.shared.log("student \(kind): \(text)")
            } catch {
                self.setPlan("plan: failed (\(error))")
                Diag.shared.log("student \(kind): compute plan failed: \(error)", error: true)
            }
        }
    }

    func run(spec: [Float]) throws -> [Float] {
        let count = 4 * Demucs.bins * Demucs.frames
        guard spec.count == count, input.count == count else {
            throw Unavailable(description: "input of \(spec.count) values for \(input.count)")
        }
        return try autoreleasepool { () throws -> [Float] in
            /* float32 -> float16 into the input array (contiguous: made here) */
            spec.withUnsafeBufferPointer { src in
                var s = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.baseAddress!), height: 1,
                                      width: vImagePixelCount(count), rowBytes: count * 4)
                var d = vImage_Buffer(data: input.dataPointer, height: 1, width: vImagePixelCount(count), rowBytes: count * 2)
                vImageConvert_PlanarFtoPlanar16F(&s, &d, 0)
            }
            let features = try MLDictionaryFeatureProvider(dictionary: ["spec": MLFeatureValue(multiArray: input)])
            let out = try model.prediction(from: features)
            guard let mask = out.featureValue(for: "mask")?.multiArrayValue else {
                throw Unavailable(description: "model gave no mask")
            }
            return try StudentModel.floats(mask)
        }
    }

    /// The values of a [1, C, H, W] float16 (or float32) array in row-major order, whatever its strides.
    static func floats(_ a: MLMultiArray) throws -> [Float] {
        let shape = a.shape.map { $0.intValue }, strides = a.strides.map { $0.intValue }
        guard shape.count == 4, strides[3] == 1 else {
            throw Unavailable(description: "unexpected output layout \(shape) / \(strides)")
        }
        let (c, h, w) = (shape[1], shape[2], shape[3])
        var out = [Float](repeating: 0, count: c * h * w)
        out.withUnsafeMutableBufferPointer { dst in
            for i in 0..<c {
                for j in 0..<h {
                    let o = (i * h + j) * w
                    let off = i * strides[1] + j * strides[2]
                    switch a.dataType {
                    case .float16:
                        var s = vImage_Buffer(data: a.dataPointer + off * 2, height: 1, width: vImagePixelCount(w), rowBytes: w * 2)
                        var d = vImage_Buffer(data: dst.baseAddress! + o, height: 1, width: vImagePixelCount(w), rowBytes: w * 4)
                        vImageConvert_Planar16FtoPlanarF(&s, &d, 0)
                    default:
                        let p = a.dataPointer.assumingMemoryBound(to: Float.self) + off
                        (dst.baseAddress! + o).update(from: p, count: w)
                    }
                }
            }
        }
        return out
    }
}
