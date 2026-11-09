import Foundation
import UIKit

/// "學生模型壓力測試" (diagnostics sheet): the student model separates the song now playing, segment after
/// segment without pause, for 20 minutes; the stems are thrown away. Every 30 seconds one log line with
/// the thermal state, the segment times, footprint, battery and the compute plan; at the end (or when
/// stopped) a summary, and a report goes to the PC (the existing report receiver, trigger
/// "student-stress"). Its own queue and its own model: playback, the band modes and HTDemucs are not
/// touched. Stops early at thermal state critical. The screen is kept on while it runs.
final class StudentStress {
    static let shared = StudentStress()
    static let duration: TimeInterval = 20 * 60

    private let queue = DispatchQueue(label: "student.stress", qos: .userInitiated)
    private let lock = NSLock()
    private var running = false
    private var stopAsked = false
    private var info: [String: Any] = ["state": "idle"]

    /// For /api/report's perf and the page.
    func summary() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return info
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func set(_ k: String, _ v: Any) {
        lock.lock()
        info[k] = v
        lock.unlock()
    }

    /// Returns nil when started, else why not.
    func start(kind: String, file: URL?, onUpdate: @escaping ([String: Any]) -> Void) -> String? {
        guard StudentModel.available(kind) else { return "Student\(kind) 不在這個版本裡" }
        lock.lock()
        if running {
            lock.unlock()
            return "已經在跑了"
        }
        running = true
        stopAsked = false
        info = ["state": "starting", "kind": kind]
        lock.unlock()
        UIApplication.shared.isIdleTimerDisabled = true
        queue.async { self.loop(kind: kind, file: file, onUpdate: onUpdate) }
        return nil
    }

    func stop() {
        lock.lock()
        stopAsked = true
        lock.unlock()
    }

    private var shouldStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopAsked
    }

    /* Up to 3 minutes of the song (per channel), or a test signal when nothing is playing. */
    private func audio(_ file: URL?) -> (left: [Float], right: [Float], source: String) {
        let want = 180 * 44100
        if let file = file, let decoder = try? SongDecoder(url: file) {
            var l: [Float] = [], r: [Float] = []
            while l.count < want, let piece = try? decoder.next() {
                l += piece.left
                r += piece.right
            }
            if l.count >= Demucs.segment {
                return (l, r, "\(file.lastPathComponent) (\(l.count / 44100) s at \(Int(decoder.sampleRate)) Hz)")
            }
        }
        let n = 4 * Demucs.segment
        var g = SystemRandomNumberGenerator()
        let l = (0..<n).map { i in Float(0.3 * sin(2 * Double.pi * 220 * Double(i) / 44100)) + Float.random(in: -0.1...0.1, using: &g) }
        let r = (0..<n).map { i in Float(0.25 * sin(2 * Double.pi * 331 * Double(i) / 44100)) + Float.random(in: -0.1...0.1, using: &g) }
        return (l, r, "test signal (no song file)")
    }

    private func loop(kind: String, file: URL?, onUpdate: @escaping ([String: Any]) -> Void) {
        let thermalNow = { PerfMonitor.thermalName(ProcessInfo.processInfo.thermalState.rawValue) }
        func battery() -> String {
            var level: Float = -1
            DispatchQueue.main.sync { level = UIDevice.current.batteryLevel }
            return level < 0 ? "?" : String(format: "%.0f%%", level * 100)
        }
        let src = audio(file)
        let startBattery = battery()
        Diag.shared.log("student-stress \(kind): start, \(src.source), thermal \(thermalNow()), battery \(startBattery), footprint \(PerfMonitor.mb(PerfMonitor.footprint())) MB, units \(StudentModel.unitsName)")
        let model: StudentModel
        do {
            model = try StudentModel(kind: kind)
        } catch {
            Diag.shared.log("student-stress \(kind): model does not load: \(error)", error: true)
            finish(["state": "failed", "kind": kind, "error": "\(error)"], onUpdate)
            return
        }
        Diag.shared.log(String(format: "student-stress %@: model loaded in %.1f s, footprint %d MB", kind, model.loadSeconds, PerfMonitor.mb(PerfMonitor.footprint())))
        let began = Date()
        var segments = 0, errors = 0, offset = 0
        var total = 0.0, slowest = 0.0, fastest = Double.infinity
        var windowTimes: [Double] = []
        var lastTick = began
        var worstThermal = ProcessInfo.processInfo.thermalState.rawValue
        var thermalLog: [String] = []
        var peakFoot: UInt64 = 0
        var reason = "20 分鐘到"
        let segSeconds = Double(Demucs.segment) / 44100
        while true {
            if shouldStop { reason = "使用者停止"; break }
            if Date().timeIntervalSince(began) >= StudentStress.duration { break }
            if ProcessInfo.processInfo.thermalState == .critical { reason = "熱狀態 critical，提前停止"; break }
            if offset + Demucs.segment > src.left.count { offset = 0 }
            let l = Array(src.left[offset..<(offset + Demucs.segment)])
            let r = Array(src.right[offset..<(offset + Demucs.segment)])
            offset += Demucs.segment
            let t = Date()
            do {
                _ = try Student.separate(left: l, right: r, network: model)
                let dt = Date().timeIntervalSince(t)
                segments += 1
                total += dt
                slowest = max(slowest, dt)
                fastest = min(fastest, dt)
                windowTimes.append(dt)
            } catch {
                errors += 1
                Diag.shared.log("student-stress \(kind): segment failed: \(error)", error: true)
                if errors > 20 { reason = "錯誤太多"; break }
                Thread.sleep(forTimeInterval: 1)
            }
            let thermal = ProcessInfo.processInfo.thermalState.rawValue
            worstThermal = max(worstThermal, thermal)
            if Date().timeIntervalSince(lastTick) >= 30 {
                lastTick = Date()
                let foot = PerfMonitor.footprint()
                peakFoot = max(peakFoot, foot)
                let avg = windowTimes.isEmpty ? 0 : windowTimes.reduce(0, +) / Double(windowTimes.count)
                let elapsed = Int(Date().timeIntervalSince(began))
                let line = String(format: "student-stress %@: %d s, thermal %@, segments %d (last 30 s: %d, avg %.2f s = %.1fx realtime), footprint %d MB, battery %@, low power %@, units %@, %@",
                                  kind, elapsed, thermalNow(), segments, windowTimes.count, avg, avg > 0 ? segSeconds / avg : 0,
                                  PerfMonitor.mb(foot), battery(), ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off",
                                  StudentModel.unitsName, model.plan)
                Diag.shared.log(line)
                thermalLog.append("\(elapsed)s:\(thermalNow())")
                windowTimes.removeAll()
                let status: [String: Any] = ["state": "running", "kind": kind, "elapsed": elapsed, "segments": segments,
                                             "avgSeconds": segments > 0 ? total / Double(segments) : 0,
                                             "thermal": thermalNow(), "worstThermal": PerfMonitor.thermalName(worstThermal),
                                             "footprintMB": PerfMonitor.mb(foot), "battery": battery(), "plan": model.plan]
                lock.lock()
                info = status
                lock.unlock()
                onUpdate(status)
            }
        }
        let elapsed = Date().timeIntervalSince(began)
        let avg = segments > 0 ? total / Double(segments) : 0
        let result: [String: Any] = [
            "state": "done", "kind": kind, "reason": reason, "seconds": Int(elapsed), "segments": segments, "errors": errors,
            "avgSeconds": (avg * 1000).rounded() / 1000, "maxSeconds": (slowest * 1000).rounded() / 1000,
            "minSeconds": fastest.isFinite ? (fastest * 1000).rounded() / 1000 : 0,
            "realtimeX": avg > 0 ? ((segSeconds / avg) * 10).rounded() / 10 : 0,
            "worstThermal": PerfMonitor.thermalName(worstThermal), "thermalEnd": thermalNow(), "thermalTimeline": thermalLog,
            "peakFootprintMB": PerfMonitor.mb(max(peakFoot, PerfMonitor.footprint())),
            "batteryStart": startBattery, "batteryEnd": battery(), "units": StudentModel.unitsName,
            "plan": model.plan, "source": src.source, "loadSeconds": (model.loadSeconds * 10).rounded() / 10
        ]
        Diag.shared.log("student-stress \(kind): end (\(reason)): \(result)")
        finish(result, onUpdate)
        Diag.shared.sendReport(trigger: "student-stress")
    }

    private func finish(_ result: [String: Any], _ onUpdate: @escaping ([String: Any]) -> Void) {
        lock.lock()
        info = result
        running = false
        lock.unlock()
        DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = false }
        onUpdate(result)
    }
}
