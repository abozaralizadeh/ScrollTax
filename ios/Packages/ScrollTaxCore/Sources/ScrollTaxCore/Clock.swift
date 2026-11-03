import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// One reading of the phone's clocks. `uptime` counts seconds since boot and keeps
/// counting while the phone sleeps. Changing the date in Settings doesn't move it.
/// `bootID` changes on every restart, because `uptime` starts again from zero then.
public struct ClockSample: Equatable, Sendable {
    public var wall: Date
    public var uptime: TimeInterval?
    public var bootID: String?

    public init(wall: Date, uptime: TimeInterval? = nil, bootID: String? = nil) {
        self.wall = wall
        self.uptime = uptime
        self.bootID = bootID
    }

    public static func current() -> ClockSample {
        ClockSample(wall: Date(), uptime: monotonicSeconds(), bootID: currentBootID())
    }

    private static func monotonicSeconds() -> TimeInterval {
        #if canImport(Darwin)
        // CLOCK_MONOTONIC keeps counting during sleep on Apple platforms. Not yet checked on a real iPhone.
        return TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
        #else
        return ProcessInfo.processInfo.systemUptime
        #endif
    }

    private static func currentBootID() -> String? {
        #if canImport(Darwin)
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
        #else
        return try? String(contentsOfFile: "/proc/sys/kernel/random/boot_id", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #endif
    }
}

/// The backend's time, taken at a known point on the phone's own uptime clock.
public struct ServerAnchor: Codable, Equatable, Sendable {
    public var serverTime: Date
    public var uptime: TimeInterval
    public var bootID: String
}

/// Works out what time it really is when the person might have changed the phone's date.
///
/// - Since the last contact with the backend, in the same boot: the backend's time plus the uptime that has passed.
///   The date in Settings is ignored completely.
/// - Otherwise: the phone's date, but never earlier than the latest time seen before. Moving the date back
///   can't give back a day of unlocks. Moving it forward offline can't be told apart from real time passing,
///   and is corrected the next time the backend is reached.
public struct ClockGuard: Codable, Equatable, Sendable {
    /// How far the phone's date may differ before we call it wrong.
    public static let tolerance: TimeInterval = 120

    public var highWater: Date?
    public var anchor: ServerAnchor?

    public init() {}

    public func trustedNow(_ s: ClockSample) -> Date {
        if let a = anchor, let up = s.uptime, let boot = s.bootID, boot == a.bootID, up >= a.uptime {
            return a.serverTime.addingTimeInterval(up - a.uptime)
        }
        return max(s.wall, highWater ?? s.wall)
    }

    /// How far the phone's date is from the trusted time. Positive means the phone is ahead.
    public func skew(_ s: ClockSample) -> TimeInterval { s.wall.timeIntervalSince(trustedNow(s)) }

    /// True when the phone's date is clearly wrong and we know the right time from the backend.
    public func phoneClockLooksWrong(_ s: ClockSample) -> Bool {
        guard anchor != nil, trustedIsAnchored(s) else { return false }
        return abs(skew(s)) > Self.tolerance
    }

    private func trustedIsAnchored(_ s: ClockSample) -> Bool {
        guard let a = anchor, let up = s.uptime, let boot = s.bootID else { return false }
        return boot == a.bootID && up >= a.uptime
    }

    /// Remembers the latest time seen. Returns true when it moved enough to be worth saving.
    @discardableResult
    public mutating func observe(_ s: ClockSample) -> Bool {
        let t = trustedNow(s)
        if let h = highWater, t < h.addingTimeInterval(30) { return false }
        highWater = t
        return true
    }

    /// Call right after hearing the backend's time. This is the only thing that may move the clock backwards.
    public mutating func syncWithServer(serverTime: Date, sample: ClockSample) {
        highWater = serverTime
        if let up = sample.uptime, let boot = sample.bootID {
            anchor = ServerAnchor(serverTime: serverTime, uptime: up, bootID: boot)
        } else {
            anchor = nil
        }
    }
}
