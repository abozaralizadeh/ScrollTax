import XCTest
@testable import ScrollTaxCore

final class FakeServerInfo: ServerInfoProviding, @unchecked Sendable {
    var isSignedIn = true
    var meReply: MeInfo?
    var timeReply: Date?
    var fail = false
    var asked: [String] = []

    func me(timeZone: String) async throws -> MeInfo {
        asked.append("me:\(timeZone)")
        if fail { throw URLError(.notConnectedToInternet) }
        return meReply!
    }

    func serverTime() async throws -> ServerTime {
        asked.append("time")
        if fail { throw URLError(.notConnectedToInternet) }
        return ServerTime(now: timeReply!)
    }
}

final class FakeClockSource: ClockSource, @unchecked Sendable {
    var samples: [ClockSample]
    init(_ samples: [ClockSample]) { self.samples = samples }
    func sample() -> ClockSample { samples.count > 1 ? samples.removeFirst() : samples[0] }
}

final class ClockSyncTests: XCTestCase {
    let rome = TimeZone(identifier: "Europe/Rome")!
    let t0 = Date(timeIntervalSince1970: 1_793_613_600)

    func sample(wall: Date, up: TimeInterval) -> ClockSample { ClockSample(wall: wall, uptime: up, bootID: "b") }

    func testSignedInSyncStoresTheRealTimeAndTheBackendCount() async {
        let api = FakeServerInfo()
        // The phone thinks it is a day later than the backend does.
        api.meReply = MeInfo(id: "u", serverTime: t0, today: .init(unlocksUsed: 2, limit: 4))
        let store = MemoryStateStore()
        let wrong = t0.addingTimeInterval(86400)
        let clock = FakeClockSource([sample(wall: wrong, up: 500), sample(wall: wrong, up: 502)])
        let ok = await ClockSync.run(store: store, api: api, clock: clock, timeZone: rome)
        XCTAssertTrue(ok)
        XCTAssertEqual(api.asked, ["me:Europe/Rome"])
        let s = store.load()
        XCTAssertEqual(s.serverUsage?.used, 2)
        XCTAssertEqual(s.clock.anchor?.uptime, 501)
        // Ten seconds later the trusted time is the backend's, not the phone's.
        let later = sample(wall: wrong.addingTimeInterval(10), up: 511)
        XCTAssertEqual(s.clock.trustedNow(later).timeIntervalSince(t0), 10, accuracy: 0.01)
        XCTAssertTrue(s.phoneClockLooksWrong(later))
    }

    func testSignedOutSyncUsesThePublicTimeEndpoint() async {
        let api = FakeServerInfo()
        api.isSignedIn = false
        api.timeReply = t0
        let store = MemoryStateStore()
        let clock = FakeClockSource([sample(wall: t0, up: 10)])
        let ok = await ClockSync.run(store: store, api: api, clock: clock, timeZone: rome)
        XCTAssertTrue(ok)
        XCTAssertEqual(api.asked, ["time"])
        XCTAssertNil(store.load().serverUsage)
        XCTAssertNotNil(store.load().clock.anchor)
    }

    func testNoConnectionLeavesTheStateAlone() async {
        let api = FakeServerInfo()
        api.fail = true
        let store = MemoryStateStore()
        let before = store.load()
        let ok = await ClockSync.run(store: store, api: api, clock: FakeClockSource([sample(wall: t0, up: 1)]), timeZone: rome)
        XCTAssertFalse(ok)
        XCTAssertEqual(store.load(), before)
    }

    func testAnAnswerThatTookTooLongIsNotTrusted() async {
        let api = FakeServerInfo()
        api.isSignedIn = false
        api.timeReply = t0
        let store = MemoryStateStore()
        let clock = FakeClockSource([sample(wall: t0, up: 100), sample(wall: t0, up: 130)])
        let ok = await ClockSync.run(store: store, api: api, clock: clock, timeZone: rome)
        XCTAssertFalse(ok)
        XCTAssertNil(store.load().clock.anchor)
    }

    func testThePendingQueueReportsWhatTheBackendSaid() async {
        final class Submitter: PaymentSubmitting {
            func submitPayment(signedTransaction: String, timeZone: String) async throws -> PaymentResult {
                PaymentResult(
                    duplicate: false, overLimit: true,
                    payment: PaymentRecord(
                        id: "p", transactionId: "t", amountMinor: 99, currency: "EUR", status: "paid",
                        purchasedAt: Date(timeIntervalSince1970: 1_793_613_600), refundedAt: nil, unlock: nil))
            }
        }
        let store = MemoryStateStore()
        store.update { $0.pendingTransactions = [PendingTransaction(signedTransaction: "x", timeZone: "Europe/Rome")] }
        var heard: [PaymentResult] = []
        let cleared = await PendingSync.flush(store: store, api: Submitter()) { heard.append($0) }
        XCTAssertEqual(cleared, 1)
        XCTAssertEqual(heard.map(\.overLimit), [true])
    }
}
