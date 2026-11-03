import XCTest
@testable import ScrollTaxCore

final class FakeTransport: HTTPTransport, @unchecked Sendable {
    var requests: [URLRequest] = []
    var replies: [(Int, String)] = []
    var failWith: Error?

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if let failWith { throw failWith }
        let (status, body) = replies.isEmpty ? (200, "{}") : replies.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

final class APITests: XCTestCase {
    let base = URL(string: "https://api.example.test")!

    let paymentJSON = """
    {"duplicate":false,"overLimit":false,"payment":{"id":"p1","transactionId":"t1","amountMinor":99,
    "currency":"EUR","status":"paid","purchasedAt":"2026-11-02T10:00:00.000Z","refundedAt":null,
    "unlock":{"startedAt":"2026-11-02T10:00:00.000Z","endsAt":"2026-11-02T10:15:00.000Z"}}}
    """

    func testConfigIsDecoded() async throws {
        let t = FakeTransport()
        t.replies = [(200, """
        {"productId":"p","priceMinor":199,"currency":"EUR","unlockMinutes":30,"dailyUnlockLimit":2,
        "leaveWaitHours":48,"minAge":18,"termsVersion":"v2"}
        """)]
        let policy = try await APIClient(baseURL: base, transport: t).config()
        XCTAssertEqual(policy.unlockMinutes, 30)
        XCTAssertEqual(policy.leaveWaitHours, 48)
        XCTAssertEqual(t.requests[0].url?.absoluteString, "https://api.example.test/v1/config")
    }

    func testSignInKeepsTheTokenAndSendsTheBoxes() async throws {
        let t = FakeTransport()
        t.replies = [(200, #"{"token":"abc","created":true,"user":{"id":"u","createdAt":"2026-11-02T10:00:00.000Z"}}"#)]
        let api = APIClient(baseURL: base, transport: t)
        let result = try await api.signIn(identityToken: "idt", ageConfirmed: true, termsVersion: "v1")
        XCTAssertEqual(result.token, "abc")
        XCTAssertEqual(api.token, "abc")
        let body = try JSONSerialization.jsonObject(with: t.requests[0].httpBody!) as! [String: Any]
        XCTAssertEqual(body["identityToken"] as? String, "idt")
        XCTAssertEqual(body["ageConfirmed"] as? Bool, true)
        XCTAssertEqual(body["termsVersion"] as? String, "v1")
    }

    func testRequestsCarryTheToken() async throws {
        let t = FakeTransport()
        t.replies = [(200, #"{"payments":[]}"#)]
        let api = APIClient(baseURL: base, transport: t, token: "tok")
        _ = try await api.payments()
        XCTAssertEqual(t.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    func testPaymentResultIsDecodedIncludingFractionalDates() async throws {
        let t = FakeTransport()
        t.replies = [(201, paymentJSON)]
        let result = try await APIClient(baseURL: base, transport: t).submitPayment(signedTransaction: "s", timeZone: "UTC")
        XCTAssertFalse(result.overLimit)
        XCTAssertEqual(result.payment.amountMinor, 99)
        XCTAssertEqual(result.payment.unlock?.endsAt.timeIntervalSince(result.payment.unlock!.startedAt), 900)
    }

    func testServerErrorsBecomeAPIErrors() async {
        let t = FakeTransport()
        t.replies = [(400, #"{"error":"age_not_confirmed","message":"You must confirm you are 18 or over"}"#)]
        do {
            _ = try await APIClient(baseURL: base, transport: t).signIn(identityToken: "x", ageConfirmed: false, termsVersion: "v")
            XCTFail("should have thrown")
        } catch let e as APIError {
            XCTAssertEqual(e.code, "age_not_confirmed")
            XCTAssertEqual(e.status, 400)
            XCTAssertTrue(e.isPermanent)
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testWhichErrorsAreWorthRetrying() {
        XCTAssertTrue(APIError(status: 422, code: "", message: "").isPermanent)
        XCTAssertTrue(APIError(status: 409, code: "", message: "").isPermanent)
        XCTAssertFalse(APIError(status: 500, code: "", message: "").isPermanent)
        XCTAssertFalse(APIError(status: 503, code: "", message: "").isPermanent)
        XCTAssertFalse(APIError(status: 429, code: "", message: "").isPermanent)
        XCTAssertFalse(APIError(status: 408, code: "", message: "").isPermanent)
    }

    func testDeleteAccountForgetsTheToken() async throws {
        let t = FakeTransport()
        t.replies = [(204, "")]
        let api = APIClient(baseURL: base, transport: t, token: "tok")
        try await api.deleteAccount()
        XCTAssertNil(api.token)
        XCTAssertEqual(t.requests[0].httpMethod, "DELETE")
    }

    func testLeaveCalls() async throws {
        let t = FakeTransport()
        let body = #"{"requestedAt":"2026-11-02T10:00:00.000Z","effectiveAt":"2026-11-03T10:00:00.000Z","complete":false}"#
        t.replies = [(200, body), (200, #"{"requestedAt":null,"effectiveAt":null,"complete":false}"#)]
        let api = APIClient(baseURL: base, transport: t)
        let started = try await api.startLeave()
        XCTAssertNotNil(started.effectiveAt)
        let cancelled = try await api.cancelLeave()
        XCTAssertNil(cancelled.requestedAt)
        XCTAssertEqual(t.requests.map(\.httpMethod), ["POST", "DELETE"])
    }
}

final class FakePayments: PaymentSubmitting, @unchecked Sendable {
    var script: [Result<Void, Error>]
    var sent: [String] = []
    init(_ script: [Result<Void, Error>]) { self.script = script }

    func submitPayment(signedTransaction: String, timeZone: String) async throws -> PaymentResult {
        sent.append(signedTransaction)
        if case .failure(let e) = script.removeFirst() { throw e }
        let json = """
        {"duplicate":false,"overLimit":false,"payment":{"id":"p","transactionId":"t","amountMinor":99,
        "currency":"EUR","status":"paid","purchasedAt":"2026-11-02T10:00:00.000Z","refundedAt":null,"unlock":null}}
        """
        return try JSONCoding.decoder.decode(PaymentResult.self, from: Data(json.utf8))
    }
}

final class PendingSyncTests: XCTestCase {
    func queue(_ names: String...) -> MemoryStateStore {
        let store = MemoryStateStore()
        store.update { s in names.forEach { s.pendingTransactions.append(.init(signedTransaction: $0, timeZone: "UTC")) } }
        return store
    }

    func testEverythingGoesThroughWhenTheBackendIsUp() async {
        let store = queue("a", "b")
        let api = FakePayments([.success(()), .success(())])
        let n = await PendingSync.flush(store: store, api: api)
        XCTAssertEqual(n, 2)
        XCTAssertEqual(api.sent, ["a", "b"])
        XCTAssertTrue(store.load().pendingTransactions.isEmpty)
    }

    func testANetworkProblemStopsAndKeepsTheRest() async {
        let store = queue("a", "b", "c")
        let api = FakePayments([.success(()), .failure(URLError(.notConnectedToInternet))])
        let n = await PendingSync.flush(store: store, api: api)
        XCTAssertEqual(n, 1)
        XCTAssertEqual(store.load().pendingTransactions.map(\.signedTransaction), ["b", "c"])
    }

    func testAServerOutageIsRetriedLater() async {
        let store = queue("a")
        let api = FakePayments([.failure(APIError(status: 503, code: "x", message: ""))])
        let n = await PendingSync.flush(store: store, api: api)
        XCTAssertEqual(n, 0)
        XCTAssertEqual(store.load().pendingTransactions.count, 1)
    }

    func testAPurchaseRefusedForGoodIsDroppedSoItDoesNotBlockTheQueue() async {
        let store = queue("bad", "good")
        let api = FakePayments([.failure(APIError(status: 422, code: "bad_transaction", message: "")), .success(())])
        let n = await PendingSync.flush(store: store, api: api)
        XCTAssertEqual(n, 2)
        XCTAssertTrue(store.load().pendingTransactions.isEmpty)
    }

    func testAnEmptyQueueDoesNothing() async {
        let api = FakePayments([])
        let n = await PendingSync.flush(store: MemoryStateStore(), api: api)
        XCTAssertEqual(n, 0)
    }
}
