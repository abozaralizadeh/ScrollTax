import Foundation

public protocol ClockSource: Sendable {
    func sample() -> ClockSample
}

public struct SystemClockSource: ClockSource {
    public init() {}
    public func sample() -> ClockSample { .current() }
}

public enum ClockSync {
    /// Longest a check may take before its answer is too stale to trust.
    static let maxRoundTrip: TimeInterval = 15

    /// Asks the backend for the real time (and today's unlock count when signed in) and stores it, so a
    /// changed date on the phone stops mattering. Does nothing, quietly, when the backend can't be reached.
    /// Returns true if the state was updated.
    @discardableResult
    public static func run(
        store: StateStore, api: ServerInfoProviding, clock: ClockSource = SystemClockSource(),
        timeZone: TimeZone = .current
    ) async -> Bool {
        let before = clock.sample()
        let serverTime: Date
        var used: Int?
        do {
            if api.isSignedIn {
                let me = try await api.me(timeZone: timeZone.identifier)
                serverTime = me.serverTime
                used = me.today?.unlocksUsed
            } else {
                serverTime = try await api.serverTime().now
            }
        } catch {
            return false
        }
        let after = clock.sample()
        // The answer was taken somewhere in the middle of the trip, so aim for the middle.
        var mid = after
        if let b = before.uptime, let a = after.uptime, before.bootID == after.bootID {
            guard a - b <= maxRoundTrip else { return false }
            mid.uptime = (a + b) / 2
        }
        store.update { s in
            if let used {
                s.recordServerUsage(used: used, serverTime: serverTime, sample: mid, timeZone: timeZone)
            } else {
                s.clock.syncWithServer(serverTime: serverTime, sample: mid)
            }
        }
        return true
    }
}
