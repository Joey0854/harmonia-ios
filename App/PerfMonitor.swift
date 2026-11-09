import Darwin
import Foundation
import os
import UIKit

/// How the phone is doing, for the log and the reports: every 30 seconds one line with the
/// app's memory footprint, the memory still available to it, CPU use, thermal state, low power
/// mode, battery level and how far the band separation is ahead of what is handed to the
/// player; memory warnings as they come; and the band segment timings since the app started
/// (`perf` in /api/report). Main queue.
final class PerfMonitor {
    static let shared = PerfMonitor()

    private var timer: Timer?
    private let lock = NSLock()
    private var segments = 0
    private var totalSeconds = 0.0
    private var slowest = 0.0
    private var slow = 0
    private var backgroundSegments = 0
    private var heatPausedSeconds = 0
    private var cacheHits = 0
    private var backgroundSlow = 0
    private var peakFootprint: UInt64 = 0
    private var worstThermal = 0
    private var warnings = 0
    private var lastCPU: (time: Double, cpu: Double)?
    private var fullPlayer: Bool?
    private var locked = false

    /// The page says whether its full player is open (pageInfo).
    func setFullPlayer(_ open: Bool) {
        lock.lock()
        fullPlayer = open
        lock.unlock()
    }

    /// For each band segment's log line: compute units, front or background, screen, page,
    /// thermal state (any thread).
    func segmentTag() -> String {
        lock.lock()
        let full = fullPlayer, isLocked = locked
        lock.unlock()
        let page = full.map { $0 ? "full player open" : "full player closed" } ?? "page ?"
        return "\(BandModel.shared.label), \(isLocked ? "screen locked" : "screen unlocked"), \(page), thermal \(PerfMonitor.thermalName(ProcessInfo.processInfo.thermalState.rawValue))"
    }

    func start() {
        guard timer == nil else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        BandProcessor.onSegment = { [weak self] seconds, realtime in self?.segment(seconds, realtime) }
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.lock.lock()
            self.warnings += 1
            self.lock.unlock()
            Diag.shared.log("perf: memory warning, footprint \(PerfMonitor.mb(PerfMonitor.footprint())) MB, available \(PerfMonitor.mb(PerfMonitor.available())) MB", error: true)
        }
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main) { [weak self] _ in
            self?.lock.lock(); self?.locked = true; self?.lock.unlock()
        }
        center.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { [weak self] _ in
            self?.lock.lock(); self?.locked = false; self?.lock.unlock()
        }
        locked = !UIApplication.shared.isProtectedDataAvailable
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.tick() }
        Diag.shared.perfProvider = { [weak self] in self?.take() ?? [:] }
    }

    /* Any thread (the band queue). */
    private func segment(_ seconds: Double, _ realtime: Double) {
        lock.lock()
        segments += 1
        totalSeconds += seconds
        slowest = max(slowest, seconds)
        if realtime < 1 { slow += 1 }
        lock.unlock()
        let bg = BandModel.shared.inBackground
        lock.lock()
        if bg {
            backgroundSegments += 1
            if realtime < 1 { backgroundSlow += 1 }
        }
        lock.unlock()
    }

    private func tick() {
        let foot = PerfMonitor.footprint()
        let thermal = ProcessInfo.processInfo.thermalState.rawValue
        lock.lock()
        peakFootprint = max(peakFootprint, foot)
        worstThermal = max(worstThermal, thermal)
        if BandProcessor.heldByHeat { heatPausedSeconds += 30 }
        lock.unlock()
        var cpuText = "?"
        let now = ProcessInfo.processInfo.systemUptime
        if let cpu = PerfMonitor.cpuTime() {
            if let last = lastCPU, now > last.time {
                cpuText = String(format: "%.0f%%", 100 * (cpu - last.cpu) / (now - last.time))
            }
            lastCPU = (now, cpu)
        }
        let battery = UIDevice.current.batteryLevel
        let lead = BandProcessor.lead.map { String(format: "%.1f s", $0) } ?? "-"
        Diag.shared.log("perf: footprint \(PerfMonitor.mb(foot)) MB, available \(PerfMonitor.mb(PerfMonitor.available())) MB, cpu \(cpuText), thermal \(PerfMonitor.thermalName(thermal)), low power \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off"), battery \(battery < 0 ? "?" : String(format: "%.0f%%", battery * 100)), band lead \(lead)")
    }

    /* The statistics since the last report, then from zero again (Diag's queue). */
    private func take() -> [String: Any] {
        let foot = PerfMonitor.footprint()
        /* for the whole session: reports go often (song ends, background), and counting from
           zero each time left the manual report with nothing */
        lock.lock()
        defer { lock.unlock() }
        cacheHits += BandProcessor.takeCacheHits()
        peakFootprint = max(peakFootprint, foot)
        return [
            "segments": segments,
            "avgSeconds": segments > 0 ? (totalSeconds / Double(segments) * 100).rounded() / 100 : 0,
            "maxSeconds": (slowest * 100).rounded() / 100,
            "slowSegments": slow,
            "peakFootprintMB": PerfMonitor.mb(peakFootprint),
            "availableMB": PerfMonitor.mb(PerfMonitor.available()),
            "worstThermal": PerfMonitor.thermalName(worstThermal),
            "memoryWarnings": warnings,
            "backgroundSegments": backgroundSegments,
            "heatPausedSeconds": heatPausedSeconds,
            "cacheHitSegments": cacheHits,
            "cacheMB": BandCache.shared.size() / 1_048_576,
            "backgroundSlowSegments": backgroundSlow,
            "computeUnits": BandModel.shared.label,
            "studentStress": StudentStress.shared.summary()
        ]
    }

    static func mb(_ bytes: UInt64) -> Int { return Int(bytes / 1_048_576) }

    static func thermalName(_ v: Int) -> String {
        return ["nominal", "fair", "serious", "critical"][max(0, min(3, v))]
    }

    /// phys_footprint from task_vm_info (what iOS counts against the app's memory limit).
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    static func available() -> UInt64 {
        return UInt64(os_proc_available_memory())
    }

    /// CPU seconds used by the process so far (user + system, all threads).
    static func cpuTime() -> Double? {
        var info = task_thread_times_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_thread_times_info_data_t>.size / MemoryLayout<natural_t>.size)
        let live = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &count)
            }
        }
        var basic = mach_task_basic_info_data_t()
        var bcount = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let dead = withUnsafeMutablePointer(to: &basic) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(bcount)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &bcount)
            }
        }
        guard live == KERN_SUCCESS, dead == KERN_SUCCESS else { return nil }
        func s(_ t: time_value_t) -> Double { return Double(t.seconds) + Double(t.microseconds) / 1e6 }
        /* threads still running, plus those that have ended */
        return s(info.user_time) + s(info.system_time) + s(basic.user_time) + s(basic.system_time)
    }
}
