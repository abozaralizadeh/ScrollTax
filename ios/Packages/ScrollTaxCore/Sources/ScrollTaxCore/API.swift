import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct UnlockInfo: Codable, Equatable, Sendable {
    public var startedAt: Date
    public var endsAt: Date
}

public struct PaymentRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var transactionId: String
    public var amountMinor: Int
    public var currency: String
    public var status: String
    public var purchasedAt: Date
    public var refundedAt: Date?
    public var unlock: UnlockInfo?

    public var isRefunded: Bool { status == "refunded" }
}

public struct PaymentResult: Codable, Equatable, Sendable {
    public var duplicate: Bool
    public var overLimit: Bool
    public var payment: PaymentRecord
}

public struct SignInResult: Codable, Equatable, Sendable {
    public struct User: Codable, Equatable, Sendable {
        public var id: String
        public var createdAt: Date
    }
    public var token: String
    public var created: Bool
    public var user: User
}

public struct LeaveStatus: Codable, Equatable, Sendable {
    public var requestedAt: Date?
    public var effectiveAt: Date?
    public var complete: Bool
}

public struct MeInfo: Codable, Equatable, Sendable {
    public struct Today: Codable, Equatable, Sendable {
        public var unlocksUsed: Int
        public var limit: Int
    }
    public var id: String
    public var serverTime: Date
    public var today: Today?
}

public struct ServerTime: Codable, Equatable, Sendable {
    public var now: Date
}

public struct APIError: Error, Equatable, Sendable {
    public var status: Int
    public var code: String
    public var message: String

    /// True for problems that retrying won't fix.
    public var isPermanent: Bool { (400..<500).contains(status) && status != 408 && status != 429 }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

public protocol ServerInfoProviding: AnyObject {
    var isSignedIn: Bool { get }
    func me(timeZone: String) async throws -> MeInfo
    func serverTime() async throws -> ServerTime
}

public protocol PaymentSubmitting: AnyObject {
    func submitPayment(signedTransaction: String, timeZone: String) async throws -> PaymentResult
}

public final class APIClient: PaymentSubmitting, ServerInfoProviding, @unchecked Sendable {
    public let baseURL: URL
    public var token: String?
    private let transport: HTTPTransport

    public init(baseURL: URL, transport: HTTPTransport = URLSessionTransport(), token: String? = nil) {
        self.baseURL = baseURL
        self.transport = transport
        self.token = token
    }

    private func request(_ method: String, _ path: String, query: [String: String] = [:], body: [String: Any]? = nil)
        throws -> URLRequest
    {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.timeoutInterval = 20
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    private func run<T: Decodable>(_ req: URLRequest, as type: T.Type) async throws -> T {
        let data = try await runRaw(req)
        return try JSONCoding.decoder.decode(T.self, from: data)
    }

    @discardableResult
    private func runRaw(_ req: URLRequest) async throws -> Data {
        let (data, http) = try await transport.send(req)
        guard (200..<300).contains(http.statusCode) else {
            struct Body: Decodable { var error: String?; var message: String? }
            let body = try? JSONDecoder().decode(Body.self, from: data)
            throw APIError(
                status: http.statusCode, code: body?.error ?? "error",
                message: body?.message ?? "Request failed (\(http.statusCode))")
        }
        return data
    }

    public func config() async throws -> Policy {
        try await run(request("GET", "v1/config"), as: Policy.self)
    }

    public func signIn(identityToken: String, ageConfirmed: Bool, termsVersion: String) async throws -> SignInResult {
        let result = try await run(
            request(
                "POST", "v1/auth/apple",
                body: ["identityToken": identityToken, "ageConfirmed": ageConfirmed, "termsVersion": termsVersion]),
            as: SignInResult.self)
        token = result.token
        return result
    }

    public var isSignedIn: Bool { token != nil }

    public func me(timeZone: String) async throws -> MeInfo {
        try await run(request("GET", "v1/me", query: ["tz": timeZone]), as: MeInfo.self)
    }

    public func serverTime() async throws -> ServerTime {
        try await run(request("GET", "v1/time"), as: ServerTime.self)
    }

    /// The raw JSON of everything the backend holds about the person, for them to keep.
    public func exportData() async throws -> Data {
        try await runRaw(request("GET", "v1/me/export"))
    }

    public func deleteAccount() async throws {
        try await runRaw(request("DELETE", "v1/me"))
        token = nil
    }

    public func submitPayment(signedTransaction: String, timeZone: String) async throws -> PaymentResult {
        try await run(
            request("POST", "v1/payments", body: ["signedTransaction": signedTransaction, "timeZone": timeZone]),
            as: PaymentResult.self)
    }

    public func payments() async throws -> [PaymentRecord] {
        struct Body: Decodable { var payments: [PaymentRecord] }
        return try await run(request("GET", "v1/payments"), as: Body.self).payments
    }

    public func startLeave() async throws -> LeaveStatus {
        try await run(request("POST", "v1/leave"), as: LeaveStatus.self)
    }

    public func cancelLeave() async throws -> LeaveStatus {
        try await run(request("DELETE", "v1/leave"), as: LeaveStatus.self)
    }
}
