// Lists where Core ML would run each op of a compiled model (MLComputePlan, macOS 14.4+), with compute
// units .all. usage: swift tools/student/plan.swift <model.mlmodelc> [<model.mlmodelc> ...]
// Prints the compute devices this machine has (a GitHub macOS runner is a VM and may have no Neural
// Engine: then no op can be planned there and the check has to be done on the phone, which the app
// does too; see App/StudentModel.swift), op counts per preferred device, and every op not on the ANE.
// Exits 0 either way: this is a report, the decision is made by reading it.
import CoreML
import Foundation

@available(macOS 14.4, *)
func deviceName(_ d: MLComputeDevice) -> String {
    switch d {
    case .cpu: return "CPU"
    case .gpu: return "GPU"
    case .neuralEngine: return "ANE"
    @unknown default: return "other"
    }
}

@available(macOS 14.4, *)
func walk(_ plan: MLComputePlan, _ ops: [MLModelStructure.Program.Operation],
          _ counts: inout [String: Int], _ off: inout [String], _ anyANE: inout [String: Int]) {
    for op in ops {
        if let u = plan.deviceUsage(for: op) {
            let p = deviceName(u.preferred)
            counts[p, default: 0] += 1
            if u.supported.contains(where: { deviceName($0) == "ANE" }) { anyANE[op.operatorName, default: 0] += 1 }
            if p != "ANE" && !op.operatorName.hasPrefix("const") {
                off.append("\(op.operatorName) -> \(p) (supported: \(u.supported.map(deviceName).joined(separator: "/")))")
            }
        } else {
            counts["none (\(op.operatorName))", default: 0] += 1
        }
        for b in op.blocks { walk(plan, b.operations, &counts, &off, &anyANE) }
    }
}

@available(macOS 14.4, *)
func report() async {
let devices = MLComputeDevice.allComputeDevices.map(deviceName)
print("compute devices on this machine: \(devices)")
for path in CommandLine.arguments.dropFirst() {
    let cfg = MLModelConfiguration()
    cfg.computeUnits = .all
    do {
        let plan = try await MLComputePlan.load(contentsOf: URL(fileURLWithPath: path), configuration: cfg)
        guard case let .program(program) = plan.modelStructure, let main = program.functions["main"] else {
            print("\(path): not an ML program"); continue
        }
        var counts: [String: Int] = [:], off: [String] = [], anyANE: [String: Int] = [:]
        walk(plan, main.block.operations, &counts, &off, &anyANE)
        let planned = counts.filter { !$0.key.hasPrefix("none") }.values.reduce(0, +)
        let onANE = counts["ANE"] ?? 0
        print("\(path): preferred device per op \(counts.sorted { $0.key < $1.key })")
        print(String(format: "\(path): %d of %d planned ops on the ANE (%.1f%%)", onANE, planned,
                     planned > 0 ? 100 * Double(onANE) / Double(planned) : 0))
        print("\(path): ops that list the ANE as supported: \(anyANE.sorted { $0.key < $1.key })")
        for line in off { print("  not on ANE: \(line)") }
    } catch {
        print("\(path): compute plan failed: \(error)")
    }
}
}

if #available(macOS 14.4, *) {
    await report()
} else {
    print("MLComputePlan needs macOS 14.4")
}
