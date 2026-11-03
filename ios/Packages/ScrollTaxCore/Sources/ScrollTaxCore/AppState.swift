import Foundation

/// A purchase Apple has taken payment for but the backend has not heard about yet.
public struct PendingTransaction: Codable, Equatable, Sendable {
    public var signedTransaction: String
    public var timeZone: String
    public init(signedTransaction: String, timeZone: String) {
        self.signedTransaction = signedTransaction
        self.timeZone = timeZone
    }
}

/// Everything the phone needs to run the block with no network. The app and its
/// extensions share it through the app group, so the extensions can put the block
/// back on their own.
public struct AppState: Codable, Equatable, Sendable {
    public var blockEnabled = false
    public var unlockEndsAt: Date?
    /// The same end, on the phone's uptime clock, so changing the date can't stretch an unlock.
    public var unlockEndsUptime: TimeInterval?
    public var unlockBootID: String?
    public var unlockLength: TimeInterval?
    public var unlockStarts: [Date] = []
    public var clock = ClockGuard()
    /// What the backend last said about today's unlocks. Catches a reinstall, which wipes the local list.
    public var serverUsage: ServerUsage?
    public var leaveRequestedAt: Date?
    public var hasLeft = false
    public var pendingTransactions: [PendingTransaction] = []
    /// The person deleted their account but the backend hasn't confirmed yet.
    /// Everything on the phone is already gone, so this only retries the server call.
    public var accountDeletionPending = false

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case blockEnabled, unlockEndsAt, unlockEndsUptime, unlockBootID, unlockLength, unlockStarts, clock
        case serverUsage, leaveRequestedAt, hasLeft, pendingTransactions, accountDeletionPending
    }

    /// Every field is optional on the way in, so a state saved by an older build still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blockEnabled = try c.decodeIfPresent(Bool.self, forKey: .blockEnabled) ?? false
        unlockEndsAt = try c.decodeIfPresent(Date.self, forKey: .unlockEndsAt)
        unlockEndsUptime = try c.decodeIfPresent(TimeInterval.self, forKey: .unlockEndsUptime)
        unlockBootID = try c.decodeIfPresent(String.self, forKey: .unlockBootID)
        unlockLength = try c.decodeIfPresent(TimeInterval.self, forKey: .unlockLength)
        unlockStarts = try c.decodeIfPresent([Date].self, forKey: .unlockStarts) ?? []
        clock = try c.decodeIfPresent(ClockGuard.self, forKey: .clock) ?? ClockGuard()
        serverUsage = try c.decodeIfPresent(ServerUsage.self, forKey: .serverUsage)
        leaveRequestedAt = try c.decodeIfPresent(Date.self, forKey: .leaveRequestedAt)
        hasLeft = try c.decodeIfPresent(Bool.self, forKey: .hasLeft) ?? false
        pendingTransactions = try c.decodeIfPresent([PendingTransaction].self, forKey: .pendingTransactions) ?? []
        accountDeletionPending = try c.decodeIfPresent(Bool.self, forKey: .accountDeletionPending) ?? false
    }
}

/// Today's unlock count as the backend sees it. The backend counts from Apple's purchase dates,
/// so the phone's clock and a reinstall can't change it.
public struct ServerUsage: Codable, Equatable, Sendable {
    /// The local calendar day this applies to, like 2026-11-02.
    public var day: String
    public var used: Int
    /// How many unlocks the phone itself had counted for that day at that moment.
    public var localAtSync: Int

    public init(day: String, used: Int, localAtSync: Int) {
        self.day = day
        self.used = used
        self.localAtSync = localAtSync
    }
}

public enum Phase: Equatable, Sendable {
    case notStarted
    case blocked
    case unlocked(endsAt: Date)
    case leaving(effectiveAt: Date)
    case left
}

public enum UnlockDecision: Equatable, Sendable {
    case allowed(remainingToday: Int)
    case alreadyUnlocked(endsAt: Date)
    case limitReached(resetsAt: Date)
    case notBlocked
}

extension AppState {
    private func calendar(_ tz: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        return c
    }

    public func leaveEffectiveAt(_ policy: Policy) -> Date? {
        leaveRequestedAt.map { $0.addingTimeInterval(policy.leaveWaitSeconds) }
    }

    public func leaveIsDue(clock s: ClockSample, policy: Policy) -> Bool {
        guard let at = leaveEffectiveAt(policy) else { return false }
        return clock.trustedNow(s) >= at
    }

    public func leaveIsDue(now: Date, policy: Policy) -> Bool {
        leaveIsDue(clock: ClockSample(wall: now), policy: policy)
    }

    /// Seconds of unlock left. In the same boot this runs on the uptime clock, which the date in Settings
    /// can't touch. After a restart there is only the date to go on, so if it has been moved back past
    /// the latest time we saw, the unlock ends (the safe side, the person can pay again).
    public func unlockRemaining(clock s: ClockSample) -> TimeInterval {
        guard let end = unlockEndsAt else { return 0 }
        if let endUp = unlockEndsUptime, let boot = unlockBootID, let up = s.uptime, s.bootID == boot, up >= 0 {
            return max(0, endUp - up)
        }
        let trusted = clock.trustedNow(s)
        if s.wall < trusted.addingTimeInterval(-ClockGuard.tolerance) { return 0 }
        let left = end.timeIntervalSince(trusted)
        if let length = unlockLength, left > length + ClockGuard.tolerance { return 0 }
        return max(0, left)
    }

    /// True when the shield should be up right now. Extensions use this too.
    public func shieldShouldBeOn(clock s: ClockSample, policy: Policy) -> Bool {
        guard blockEnabled, !hasLeft else { return false }
        if leaveIsDue(clock: s, policy: policy) { return false }
        return unlockRemaining(clock: s) <= 0
    }

    public func shieldShouldBeOn(now: Date, policy: Policy) -> Bool {
        shieldShouldBeOn(clock: ClockSample(wall: now), policy: policy)
    }

    public func phase(clock s: ClockSample, policy: Policy) -> Phase {
        if hasLeft { return .left }
        guard blockEnabled else { return .notStarted }
        if leaveIsDue(clock: s, policy: policy) { return .left }
        let left = unlockRemaining(clock: s)
        if left > 0 { return .unlocked(endsAt: clock.trustedNow(s).addingTimeInterval(left)) }
        if let at = leaveEffectiveAt(policy) { return .leaving(effectiveAt: at) }
        return .blocked
    }

    public func phase(now: Date, policy: Policy) -> Phase {
        phase(clock: ClockSample(wall: now), policy: policy)
    }

    private static func dayKey(_ date: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The larger of what the phone counted and what the backend counted. Unlocks bought after the
    /// last backend check are added on top of the backend's number.
    public func unlocksToday(clock s: ClockSample, timeZone: TimeZone) -> Int {
        let cal = calendar(timeZone)
        let now = clock.trustedNow(s)
        let local = unlockStarts.filter { cal.isDate($0, inSameDayAs: now) }.count
        guard let server = serverUsage, server.day == Self.dayKey(now, cal) else { return local }
        return max(local, server.used + max(0, local - server.localAtSync))
    }

    public func unlocksToday(now: Date, timeZone: TimeZone) -> Int {
        unlocksToday(clock: ClockSample(wall: now), timeZone: timeZone)
    }

    /// When today's count goes back to zero: the next midnight in the person's time zone.
    public func nextReset(now: Date, timeZone: TimeZone) -> Date {
        let cal = calendar(timeZone)
        return cal.nextDate(
            after: now, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime)
            ?? now.addingTimeInterval(86400)
    }

    public func unlockDecision(clock s: ClockSample, timeZone: TimeZone, policy: Policy) -> UnlockDecision {
        let now = clock.trustedNow(s)
        let left = unlockRemaining(clock: s)
        if left > 0 { return .alreadyUnlocked(endsAt: now.addingTimeInterval(left)) }
        guard blockEnabled, !hasLeft else { return .notBlocked }
        let used = unlocksToday(clock: s, timeZone: timeZone)
        if used >= policy.dailyUnlockLimit {
            return .limitReached(resetsAt: nextReset(now: now, timeZone: timeZone))
        }
        return .allowed(remainingToday: policy.dailyUnlockLimit - used)
    }

    public func unlockDecision(now: Date, timeZone: TimeZone, policy: Policy) -> UnlockDecision {
        unlockDecision(clock: ClockSample(wall: now), timeZone: timeZone, policy: policy)
    }

    /// True when the phone's date is clearly off and the backend's time is being used instead.
    public func phoneClockLooksWrong(_ s: ClockSample) -> Bool { clock.phoneClockLooksWrong(s) }

    // MARK: changes

    public mutating func enableBlock() {
        blockEnabled = true
        hasLeft = false
        leaveRequestedAt = nil
    }

    /// Call after Apple has taken the payment. `purchasedAt` is Apple's date for it.
    public mutating func startUnlock(purchasedAt: Date, clock s: ClockSample, policy: Policy) {
        let trusted = clock.trustedNow(s)
        let start = min(purchasedAt, trusted)
        let length = policy.unlockSeconds
        let left = max(0, start.addingTimeInterval(length).timeIntervalSince(trusted))
        unlockLength = length
        unlockEndsAt = start.addingTimeInterval(length)
        unlockEndsUptime = s.uptime.map { $0 + left }
        unlockBootID = s.bootID
        unlockStarts.append(start)
        // Only today and yesterday matter, so the list can't grow forever.
        unlockStarts.removeAll { trusted.timeIntervalSince($0) > 3 * 86400 }
        clock.observe(s)
    }

    public mutating func startUnlock(now: Date, policy: Policy) {
        startUnlock(purchasedAt: now, clock: ClockSample(wall: now), policy: policy)
    }

    /// The backend refused to count a purchase (it went over the daily limit), so the unlock it started goes away.
    /// The phone may have used a slightly different start time than Apple's date, so the closest start
    /// within ten minutes is the one removed.
    public mutating func revokeUnlock(startedAt: Date) {
        let nearest = unlockStarts.enumerated()
            .map { ($0.offset, abs($0.element.timeIntervalSince(startedAt))) }
            .filter { $0.1 <= 600 }
            .min { $0.1 < $1.1 }
        guard let i = nearest?.0 else { return }
        let wasLatest = unlockStarts[i] == unlockStarts.max()
        unlockStarts.remove(at: i)
        if wasLatest { clearUnlock() }
    }

    private mutating func clearUnlock() {
        unlockEndsAt = nil
        unlockEndsUptime = nil
        unlockBootID = nil
        unlockLength = nil
    }

    public mutating func requestLeave(now: Date) {
        if leaveRequestedAt == nil { leaveRequestedAt = now }
    }

    public mutating func cancelLeave() {
        leaveRequestedAt = nil
    }

    /// Stores what the backend says about today. Call after a successful check.
    public mutating func recordServerUsage(used: Int, serverTime: Date, sample: ClockSample, timeZone: TimeZone) {
        clock.syncWithServer(serverTime: serverTime, sample: sample)
        let cal = calendar(timeZone)
        let local = unlockStarts.filter { cal.isDate($0, inSameDayAs: serverTime) }.count
        serverUsage = ServerUsage(day: Self.dayKey(serverTime, cal), used: used, localAtSync: local)
    }

    /// Returns true if the wait just finished and the block should come off for good.
    @discardableResult
    public mutating func completeLeaveIfDue(clock s: ClockSample, policy: Policy) -> Bool {
        guard blockEnabled, !hasLeft, leaveIsDue(clock: s, policy: policy) else { return false }
        hasLeft = true
        blockEnabled = false
        leaveRequestedAt = nil
        clearUnlock()
        return true
    }

    @discardableResult
    public mutating func completeLeaveIfDue(now: Date, policy: Policy) -> Bool {
        completeLeaveIfDue(clock: ClockSample(wall: now), policy: policy)
    }

    /// Back to a clean slate, for deleting the account.
    public mutating func reset() {
        self = AppState()
    }
}
