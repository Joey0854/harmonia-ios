import Foundation

public extension BandNetwork {
    /// Anything slow that must happen before a run (loading a model); not timed by the watchdog.
    func prepare() throws {}
    /// The run that was started is not coming back: let go of what it uses, so that the
    /// next run starts afresh (another model instance, other compute units).
    func abandon() {}
}

/// Runs the network with a time limit. Each run goes to a queue of its own; if it has not
/// come back after `timeout` seconds it counts as stalled (a GPU that hangs, for one): that
/// queue and the network's model instance are left to themselves (a running prediction cannot
/// be stopped), and the same segment is run again on a new queue after `abandon()` (the app's
/// model then loads a new instance on the other compute units). Two stalls in a row throw
/// `Stalled`; the band processor then retries later, as for any failure.
///
/// The band queue, and with it the next song and every new mode, is never held longer than
/// two time limits.
public final class BandWatchdog: BandNetwork {
    public struct Stalled: Error, CustomStringConvertible {
        public let seconds: Double
        public var description: String { return String(format: "stalled: no answer in %.0f s", seconds) }
    }

    private final class Box {
        var result: Result<(spec: [Float], wave: [Float]), Error>?
    }

    public let timeout: Double
    private let inner: BandNetwork
    private let log: (String) -> Void
    private let lock = NSLock()
    private var queue: DispatchQueue
    private var queues = 0
    /// Runs that stalled so far (tests, the log).
    public private(set) var stalls = 0

    /// `timeout`: at least 10 s and one and a half segments of playback (11.7 s).
    public init(_ inner: BandNetwork, timeout: Double = max(10, 1.5 * Double(Demucs.segment) / Double(Demucs.sampleRate)),
                log: @escaping (String) -> Void = { _ in }) {
        self.inner = inner
        self.timeout = timeout
        self.log = log
        queue = DispatchQueue(label: "band.inference.0", qos: .userInitiated)
    }

    public func prepare() throws {
        try inner.prepare()
    }

    public func run(spec: [Float], wave: [Float]) throws -> (spec: [Float], wave: [Float]) {
        for attempt in 0..<2 {
            if attempt > 0 { try? inner.prepare() }
            lock.lock()
            let q = queue
            lock.unlock()
            let box = Box()
            let done = DispatchSemaphore(value: 0)
            let net = inner
            q.async {
                let r = Result { try net.run(spec: spec, wave: wave) }
                box.result = r
                done.signal()
            }
            if done.wait(timeout: .now() + timeout) == .success, let r = box.result {
                return try r.get()
            }
            lock.lock()
            stalls += 1
            queues += 1
            queue = DispatchQueue(label: "band.inference.\(queues)", qos: .userInitiated)
            lock.unlock()
            log(String(format: "band: inference stalled (no answer in %.0f s); left behind, %@", timeout,
                       attempt == 0 ? "the same segment again on a new instance" : "giving this segment up"))
            inner.abandon()
        }
        throw Stalled(seconds: timeout)
    }
}
