import XCTest
@testable import ScrollTaxCore

final class StateTests: XCTestCase {
    let policy = Policy.proposed
    let rome = TimeZone(identifier: "Europe/Rome")!
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    // 2 Nov 2026, 10:00 UTC
    let t0 = Date(timeIntervalSince1970: 1_793_613_600)

    func blocked() -> AppState {
        var s = AppState()
        s.enableBlock()
        return s
    }

    func testProposedAnswersMatchThePlan() {
        XCTAssertEqual(policy.priceMinor, 99)
        XCTAssertEqual(policy.currency, "EUR")
        XCTAssertEqual(policy.unlockMinutes, 15)
        XCTAssertEqual(policy.dailyUnlockLimit, 4)
        XCTAssertEqual(policy.leaveWaitHours, 24)
        XCTAssertEqual(policy.minAge, 18)
    }

    func testPriceText() {
        XCTAssertEqual(policy.priceText(locale: Locale(identifier: "en_IE")), "€0.99")
    }

    func testNewStateIsNotBlocking() {
        let s = AppState()
        XCTAssertEqual(s.phase(now: t0, policy: policy), .notStarted)
        XCTAssertFalse(s.shieldShouldBeOn(now: t0, policy: policy))
        XCTAssertEqual(s.unlockDecision(now: t0, timeZone: rome, policy: policy), .notBlocked)
    }

    func testEnablingTheBlockPutsTheShieldUp() {
        let s = blocked()
        XCTAssertEqual(s.phase(now: t0, policy: policy), .blocked)
        XCTAssertTrue(s.shieldShouldBeOn(now: t0, policy: policy))
        XCTAssertEqual(s.unlockDecision(now: t0, timeZone: rome, policy: policy), .allowed(remainingToday: 4))
    }

    func testAnUnlockLastsFifteenMinutesThenTheShieldReturns() {
        var s = blocked()
        s.startUnlock(now: t0, policy: policy)
        let end = t0.addingTimeInterval(15 * 60)
        XCTAssertEqual(s.phase(now: t0.addingTimeInterval(60), policy: policy), .unlocked(endsAt: end))
        XCTAssertFalse(s.shieldShouldBeOn(now: end.addingTimeInterval(-1), policy: policy))
        XCTAssertTrue(s.shieldShouldBeOn(now: end, policy: policy))
        XCTAssertEqual(s.phase(now: end, policy: policy), .blocked)
    }

    func testPayingWhileUnlockedIsNotOffered() {
        var s = blocked()
        s.startUnlock(now: t0, policy: policy)
        let end = t0.addingTimeInterval(900)
        XCTAssertEqual(
            s.unlockDecision(now: t0.addingTimeInterval(10), timeZone: rome, policy: policy),
            .alreadyUnlocked(endsAt: end))
    }

    func testTheFifthUnlockOfTheDayIsRefused() {
        var s = blocked()
        var now = t0
        for i in 1...4 {
            XCTAssertEqual(
                s.unlockDecision(now: now, timeZone: rome, policy: policy), .allowed(remainingToday: 5 - i))
            s.startUnlock(now: now, policy: policy)
            now = now.addingTimeInterval(20 * 60)
        }
        guard case .limitReached = s.unlockDecision(now: now, timeZone: rome, policy: policy) else {
            return XCTFail("expected the limit to be reached")
        }
        XCTAssertEqual(s.unlocksToday(now: now, timeZone: rome), 4)
    }

    func testTheCountResetsAtMidnightInTheirOwnTimeZone() {
        var s = blocked()
        // 22:30 UTC is 23:30 in Rome
        let late = Date(timeIntervalSince1970: 1_793_658_600)
        for _ in 0..<4 { s.startUnlock(now: late, policy: policy) }
        guard case .limitReached(let resets) = s.unlockDecision(
            now: late.addingTimeInterval(20 * 60), timeZone: rome, policy: policy)
        else { return XCTFail("expected the limit") }
        // midnight in Rome is 23:00 UTC, which is 30 minutes after `late`
        XCTAssertEqual(resets, late.addingTimeInterval(30 * 60))
        // an hour after that it is a new day
        let nextDay = late.addingTimeInterval(90 * 60)
        XCTAssertEqual(s.unlocksToday(now: nextDay, timeZone: rome), 0)
        // but in Tokyo, the same moment is already the next day
        XCTAssertEqual(s.unlocksToday(now: late, timeZone: tokyo), 4)
        XCTAssertEqual(s.unlocksToday(now: late.addingTimeInterval(3600 * 2), timeZone: tokyo), 4)
    }

    func testOldUnlockRecordsAreTrimmed() {
        var s = blocked()
        s.startUnlock(now: t0, policy: policy)
        s.startUnlock(now: t0.addingTimeInterval(5 * 86400), policy: policy)
        XCTAssertEqual(s.unlockStarts.count, 1)
    }

    func testLeavingWaitsTwentyFourHours() {
        var s = blocked()
        s.requestLeave(now: t0)
        let due = t0.addingTimeInterval(24 * 3600)
        XCTAssertEqual(s.phase(now: t0.addingTimeInterval(3600), policy: policy), .leaving(effectiveAt: due))
        XCTAssertTrue(s.shieldShouldBeOn(now: t0.addingTimeInterval(3600), policy: policy))
        XCTAssertFalse(s.completeLeaveIfDue(now: due.addingTimeInterval(-1), policy: policy))
        XCTAssertTrue(s.completeLeaveIfDue(now: due, policy: policy))
        XCTAssertEqual(s.phase(now: due, policy: policy), .left)
        XCTAssertFalse(s.shieldShouldBeOn(now: due, policy: policy))
        XCTAssertFalse(s.blockEnabled)
    }

    func testAskingToLeaveTwiceDoesNotMoveTheDate() {
        var s = blocked()
        s.requestLeave(now: t0)
        s.requestLeave(now: t0.addingTimeInterval(3600))
        XCTAssertEqual(s.leaveRequestedAt, t0)
    }

    func testCancellingLeaveKeepsTheBlock() {
        var s = blocked()
        s.requestLeave(now: t0)
        s.cancelLeave()
        XCTAssertEqual(s.phase(now: t0, policy: policy), .blocked)
        XCTAssertFalse(s.completeLeaveIfDue(now: t0.addingTimeInterval(48 * 3600), policy: policy))
    }

    func testTheShieldComesOffOnceTheLeaveWaitIsOverEvenIfNobodyOpenedTheApp() {
        var s = blocked()
        s.requestLeave(now: t0)
        XCTAssertFalse(s.shieldShouldBeOn(now: t0.addingTimeInterval(25 * 3600), policy: policy))
    }

    func testPayingDuringTheLeaveWaitStillWorks() {
        var s = blocked()
        s.requestLeave(now: t0)
        XCTAssertEqual(
            s.unlockDecision(now: t0.addingTimeInterval(60), timeZone: rome, policy: policy),
            .allowed(remainingToday: 4))
        s.startUnlock(now: t0.addingTimeInterval(60), policy: policy)
        guard case .unlocked = s.phase(now: t0.addingTimeInterval(120), policy: policy) else {
            return XCTFail("expected unlocked")
        }
    }

    func testTurningTheBlockBackOnAfterLeaving() {
        var s = blocked()
        s.requestLeave(now: t0)
        s.completeLeaveIfDue(now: t0.addingTimeInterval(25 * 3600), policy: policy)
        s.enableBlock()
        XCTAssertEqual(s.phase(now: t0.addingTimeInterval(26 * 3600), policy: policy), .blocked)
        XCTAssertNil(s.leaveRequestedAt)
    }

    func testResetClearsEverything() {
        var s = blocked()
        s.startUnlock(now: t0, policy: policy)
        s.pendingTransactions.append(PendingTransaction(signedTransaction: "x", timeZone: "UTC"))
        s.reset()
        XCTAssertEqual(s, AppState())
    }

    func testStateSurvivesSavingAndLoading() {
        var s = blocked()
        s.startUnlock(now: t0, policy: policy)
        s.requestLeave(now: t0)
        s.pendingTransactions.append(PendingTransaction(signedTransaction: "jws", timeZone: "Europe/Rome"))
        let store = UserDefaultsStateStore(suiteName: "scrolltax.tests.\(UUID().uuidString)")
        store.save(s)
        XCTAssertEqual(store.load(), s)
    }

    func testThePolicyIsRememberedAndFallsBackToTheProposedOne() {
        let suite = "scrolltax.tests.\(UUID().uuidString)"
        let store = PolicyStore(suiteName: suite)
        XCTAssertEqual(store.load(), .proposed)
        var changed = Policy.proposed
        changed.unlockMinutes = 30
        store.save(changed)
        XCTAssertEqual(PolicyStore(suiteName: suite).load().unlockMinutes, 30)
    }

    func testResetKeepsNothingButADeletionCanBeFlaggedAfterwards() {
        var s = blocked()
        s.reset()
        s.accountDeletionPending = true
        XCTAssertFalse(s.blockEnabled)
        XCTAssertTrue(s.accountDeletionPending)
    }

    func testAnEmptyStoreGivesAFreshState() {
        XCTAssertEqual(UserDefaultsStateStore(suiteName: "scrolltax.tests.\(UUID().uuidString)").load(), AppState())
    }

    func testUpdateChangesOneStepAtATime() {
        let store = MemoryStateStore()
        store.update { $0.enableBlock() }
        XCTAssertTrue(store.load().blockEnabled)
    }
}
