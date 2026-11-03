import XCTest
@testable import ScrollTaxCore

final class ClockTests: XCTestCase {
    let policy = Policy.proposed
    let rome = TimeZone(identifier: "Europe/Rome")!
    // 2 Nov 2026, 10:00 UTC
    let t0 = Date(timeIntervalSince1970: 1_793_613_600)
    let day: TimeInterval = 86400

    /// The phone `seconds` after t0 on its uptime clock, showing `wallShift` extra seconds on its calendar.
    func at(_ seconds: TimeInterval, shift wallShift: TimeInterval = 0, boot: String = "boot-1") -> ClockSample {
        ClockSample(wall: t0.addingTimeInterval(seconds + wallShift), uptime: 1000 + seconds, bootID: boot)
    }

    func blockedAndUnlocked() -> AppState {
        var s = AppState()
        s.enableBlock()
        s.startUnlock(purchasedAt: t0, clock: at(0), policy: policy)
        return s
    }

    // MARK: the unlock timer

    func testAnUnlockEndsAfterFifteenMinutesOfUptime() {
        let s = blockedAndUnlocked()
        XCTAssertFalse(s.shieldShouldBeOn(clock: at(14 * 60), policy: policy))
        XCTAssertTrue(s.shieldShouldBeOn(clock: at(15 * 60 + 1), policy: policy))
    }

    func testMovingTheDateBackDoesNotStretchAnUnlock() {
        let s = blockedAndUnlocked()
        // Ten minutes in, the person sets the date back a whole day.
        XCTAssertFalse(s.shieldShouldBeOn(clock: at(10 * 60, shift: -day), policy: policy))
        // Sixteen minutes in, still with the wrong date, the block is back.
        XCTAssertTrue(s.shieldShouldBeOn(clock: at(16 * 60, shift: -day), policy: policy))
    }

    func testMovingTheDateForwardDoesNotShortenAnUnlockEither() {
        let s = blockedAndUnlocked()
        XCTAssertFalse(s.shieldShouldBeOn(clock: at(5 * 60, shift: day), policy: policy))
        XCTAssertEqual(s.unlockRemaining(clock: at(5 * 60, shift: day)), 10 * 60, accuracy: 0.01)
    }

    func testTheCountdownShownIsTheRealOneEvenWithAWrongDate() {
        let s = blockedAndUnlocked()
        let sample = at(5 * 60, shift: -day)
        guard case .unlocked(let end) = s.phase(clock: sample, policy: policy) else { return XCTFail("not unlocked") }
        XCTAssertEqual(end.timeIntervalSince(s.clock.trustedNow(sample)), 10 * 60, accuracy: 0.01)
    }

    func testAfterARestartTheDateIsUsedWhenItLooksRight() {
        let s = blockedAndUnlocked()
        let rebooted = ClockSample(wall: t0.addingTimeInterval(10 * 60), uptime: 30, bootID: "boot-2")
        XCTAssertFalse(s.shieldShouldBeOn(clock: rebooted, policy: policy))
        XCTAssertEqual(s.unlockRemaining(clock: rebooted), 5 * 60, accuracy: 1)
        let later = ClockSample(wall: t0.addingTimeInterval(16 * 60), uptime: 400, bootID: "boot-2")
        XCTAssertTrue(s.shieldShouldBeOn(clock: later, policy: policy))
    }

    func testRestartingAndMovingTheDateBackEndsTheUnlockInsteadOfStretchingIt() {
        var s = blockedAndUnlocked()
        s.clock.observe(at(60))
        let rebooted = ClockSample(wall: t0.addingTimeInterval(10 * 60 - day), uptime: 30, bootID: "boot-2")
        XCTAssertTrue(s.shieldShouldBeOn(clock: rebooted, policy: policy))
    }

    func testAnUnlockCannotLastLongerThanItsLengthWhateverTheDateSays() {
        var s = AppState()
        s.enableBlock()
        s.unlockEndsAt = t0.addingTimeInterval(day)
        s.unlockLength = 900
        let wallOnly = ClockSample(wall: t0)
        XCTAssertEqual(s.unlockRemaining(clock: wallOnly), 0)
    }

    // MARK: the daily limit

    func buyFour(_ s: inout AppState) {
        for i in 0..<4 {
            let start = TimeInterval(i * 20 * 60)
            s.startUnlock(purchasedAt: t0.addingTimeInterval(start), clock: at(start), policy: policy)
        }
    }

    func testMovingTheDateBackAfterARestartDoesNotGiveAnotherDay() {
        var s = AppState()
        s.enableBlock()
        buyFour(&s)
        // Next day, restart, then the date is set back to yesterday. Time cannot go back.
        let rebooted = ClockSample(wall: t0.addingTimeInterval(-day), uptime: 50, bootID: "boot-2")
        XCTAssertEqual(s.unlocksToday(clock: rebooted, timeZone: rome), 4)
        XCTAssertEqual(s.unlockDecision(clock: rebooted, timeZone: rome, policy: policy).isLimit, true)
    }

    func testMovingTheDateForwardIsCaughtOnceTheBackendHasBeenReached() {
        var s = AppState()
        s.enableBlock()
        buyFour(&s)
        let sync = at(90 * 60)
        s.recordServerUsage(used: 4, serverTime: t0.addingTimeInterval(90 * 60), sample: sync, timeZone: rome)
        // Same boot, two hours later, the date jumps a day ahead. The count is still today's.
        let cheating = at(210 * 60, shift: day)
        XCTAssertEqual(s.unlocksToday(clock: cheating, timeZone: rome), 4)
        XCTAssertTrue(s.phoneClockLooksWrong(cheating))
        XCTAssertFalse(s.phoneClockLooksWrong(at(210 * 60)))
    }

    func testTheBackendTimeMayMoveTheClockBack() {
        var s = AppState()
        s.clock.observe(at(0, shift: day))
        XCTAssertEqual(s.clock.highWater, t0.addingTimeInterval(day))
        s.clock.syncWithServer(serverTime: t0, sample: at(0, shift: day))
        XCTAssertEqual(s.clock.trustedNow(at(0, shift: day)), t0)
    }

    func testAReinstallDoesNotWipeTheDailyCount() {
        // A fresh install has no local list, but the backend remembers three unlocks.
        var s = AppState()
        s.enableBlock()
        s.recordServerUsage(used: 3, serverTime: t0, sample: at(0), timeZone: rome)
        XCTAssertEqual(s.unlockDecision(clock: at(1), timeZone: rome, policy: policy), .allowed(remainingToday: 1))
        s.startUnlock(purchasedAt: t0, clock: at(2), policy: policy)
        XCTAssertEqual(s.unlocksToday(clock: at(2000), timeZone: rome), 4)
        XCTAssertTrue(s.unlockDecision(clock: at(2000), timeZone: rome, policy: policy).isLimit)
    }

    func testTheBackendNumberOnlyAppliesToTheDayItWasTakenOn() {
        var s = AppState()
        s.enableBlock()
        s.recordServerUsage(used: 4, serverTime: t0, sample: at(0), timeZone: rome)
        let tomorrow = ClockSample(wall: t0.addingTimeInterval(day), uptime: 5, bootID: "boot-2")
        XCTAssertEqual(s.unlocksToday(clock: tomorrow, timeZone: rome), 0)
    }

    func testTheLeaveWaitCannotBeSkippedByMovingTheDate() {
        var s = AppState()
        s.enableBlock()
        s.requestLeave(now: t0)
        s.clock.syncWithServer(serverTime: t0, sample: at(0))
        XCTAssertFalse(s.leaveIsDue(clock: at(60, shift: 2 * day), policy: policy))
        XCTAssertTrue(s.leaveIsDue(clock: at(25 * 3600), policy: policy))
    }

    // MARK: undoing an unlock the backend refused

    func testAnUnlockTheBackendRefusedIsTakenBack() {
        var s = blockedAndUnlocked()
        s.revokeUnlock(startedAt: t0)
        XCTAssertTrue(s.shieldShouldBeOn(clock: at(1), policy: policy))
        XCTAssertEqual(s.unlocksToday(clock: at(1), timeZone: rome), 0)
    }

    func testRevokingAnOlderUnlockLeavesTheCurrentOneRunning() {
        var s = blockedAndUnlocked()
        s.startUnlock(purchasedAt: t0.addingTimeInterval(1200), clock: at(1200), policy: policy)
        s.revokeUnlock(startedAt: t0)
        XCTAssertFalse(s.shieldShouldBeOn(clock: at(1300), policy: policy))
        XCTAssertEqual(s.unlockStarts.count, 1)
    }

    // MARK: saving

    func testAStateSavedByAnOlderBuildStillLoads() throws {
        let old = #"{"blockEnabled":true,"unlockStarts":[],"hasLeft":false,"pendingTransactions":[],"accountDeletionPending":false}"#
        let s = try JSONCoding.decoder.decode(AppState.self, from: Data(old.utf8))
        XCTAssertTrue(s.blockEnabled)
        XCTAssertNil(s.clock.anchor)
    }

    func testTheClockStateSurvivesSaving() throws {
        var s = blockedAndUnlocked()
        s.recordServerUsage(used: 1, serverTime: t0, sample: at(0), timeZone: rome)
        let back = try JSONCoding.decoder.decode(AppState.self, from: JSONCoding.encoder.encode(s))
        XCTAssertEqual(back, s)
    }

    func testTheRealClockSampleLooksSane() throws {
        let a = ClockSample.current()
        let b = ClockSample.current()
        let up = try XCTUnwrap(a.uptime)
        XCTAssertGreaterThan(up, 0)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(b.uptime), up)
        XCTAssertEqual(a.bootID, b.bootID)
        XCTAssertFalse(try XCTUnwrap(a.bootID).isEmpty)
    }
}

extension UnlockDecision {
    var isLimit: Bool {
        if case .limitReached = self { return true }
        return false
    }
}
