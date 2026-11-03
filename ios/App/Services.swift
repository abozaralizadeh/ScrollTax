import AuthenticationServices
import DeviceActivity
import FamilyControls
import Foundation
import ScrollTaxCore
import StoreKit

// MARK: - Blocking

/// Everything the app asks of Screen Time. `DemoBlocker` stands in where Apple's tools
/// can't run (the simulator) or aren't approved yet.
protocol Blocking: AnyObject {
    var isAuthorized: Bool { get }
    var hasSelection: Bool { get }
    func requestAuthorization() async throws
    func setShield(on: Bool)
    /// Asks the system to run our monitor extension when the unlock ends.
    func scheduleReblock(from start: Date, to end: Date)
    func cancelReblock()
}

final class RealBlocker: Blocking {
    private let selections = SelectionStore()
    private let center = DeviceActivityCenter()

    var isAuthorized: Bool { AuthorizationCenter.shared.authorizationStatus == .approved }

    var hasSelection: Bool {
        let s = selections.load()
        return !(s.applicationTokens.isEmpty && s.categoryTokens.isEmpty && s.webDomainTokens.isEmpty)
    }

    func requestAuthorization() async throws {
        try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
    }

    func setShield(on: Bool) {
        if on { Shield.apply(selections.load()) } else { Shield.clear() }
    }

    func scheduleReblock(from start: Date, to end: Date) {
        let cal = Calendar.current
        let parts: Set<Calendar.Component> = [.hour, .minute, .second]
        let schedule = DeviceActivitySchedule(
            intervalStart: cal.dateComponents(parts, from: start),
            intervalEnd: cal.dateComponents(parts, from: end),
            repeats: false)
        let name = DeviceActivityName(SharedConfig.activityName)
        center.stopMonitoring([name])
        try? center.startMonitoring(name, during: schedule)
    }

    func cancelReblock() {
        center.stopMonitoring([DeviceActivityName(SharedConfig.activityName)])
    }
}

final class DemoBlocker: Blocking {
    var isAuthorized = false
    var hasSelection = false
    private(set) var shieldOn = false

    func requestAuthorization() async throws {
        isAuthorized = true
        hasSelection = true
    }

    func setShield(on: Bool) { shieldOn = on }
    func scheduleReblock(from start: Date, to end: Date) {}
    func cancelReblock() {}
}

// MARK: - Purchasing

enum PurchaseOutcome {
    case success(signedTransaction: String, purchaseDate: Date, finish: () async -> Void)
    case cancelled
    case pending
}

protocol Purchasing: AnyObject {
    func displayPrice(productId: String) async -> String?
    func purchase(productId: String) async throws -> PurchaseOutcome
    /// Purchases that were paid for but not finished, for example if the app was closed mid-purchase.
    func unfinished() async -> [PurchaseOutcome]
}

enum PurchaseError: Error { case productNotFound, unverified }

final class StoreKitPurchaser: Purchasing {
    func displayPrice(productId: String) async -> String? {
        try? await Product.products(for: [productId]).first?.displayPrice
    }

    func purchase(productId: String) async throws -> PurchaseOutcome {
        guard let product = try await Product.products(for: [productId]).first else {
            throw PurchaseError.productNotFound
        }
        switch try await product.purchase() {
        case .success(let verification):
            return try outcome(from: verification)
        case .userCancelled:
            return .cancelled
        case .pending:
            return .pending
        @unknown default:
            return .pending
        }
    }

    func unfinished() async -> [PurchaseOutcome] {
        var out: [PurchaseOutcome] = []
        for await verification in Transaction.unfinished {
            if let o = try? outcome(from: verification) { out.append(o) }
        }
        return out
    }

    private func outcome(from verification: VerificationResult<Transaction>) throws -> PurchaseOutcome {
        guard case .verified(let transaction) = verification else { throw PurchaseError.unverified }
        return .success(
            signedTransaction: verification.jwsRepresentation,
            purchaseDate: transaction.purchaseDate,
            finish: { await transaction.finish() })
    }
}

/// Makes the same made up transactions the local backend accepts in APPLE_MODE=fake.
final class DemoPurchaser: Purchasing {
    var failNext = false

    func displayPrice(productId: String) async -> String? { nil }

    func purchase(productId: String) async throws -> PurchaseOutcome {
        try await Task.sleep(nanoseconds: 400_000_000)
        if failNext { failNext = false; throw PurchaseError.productNotFound }
        let id = UUID().uuidString
        let now = Date()
        let info: [String: Any] = [
            "transactionId": id, "originalTransactionId": id, "productId": productId,
            "bundleId": "app.scrolltax", "purchaseDate": Int(now.timeIntervalSince1970 * 1000),
            "environment": "Sandbox",
        ]
        let data = try JSONSerialization.data(withJSONObject: info)
        return .success(
            signedTransaction: "fake-txn." + data.base64URL, purchaseDate: now, finish: {})
    }

    func unfinished() async -> [PurchaseOutcome] { [] }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Keychain

/// Keeps the session token and, in demo mode, the made up user name.
enum Keychain {
    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "app.scrolltax",
         kSecAttrAccount as String: key]
    }

    static func get(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String?, for key: String) {
        SecItemDelete(query(key) as CFDictionary)
        guard let value else { return }
        var q = query(key)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }
}

// MARK: - Settings

struct RuntimeConfig {
    /// Demo mode uses a pretend blocker, pretend purchases and a fake sign in against the local backend.
    var demo: Bool
    var apiURL: URL

    static func load() -> RuntimeConfig {
        let info = Bundle.main.object(forInfoDictionaryKey: "ScrollTaxAPIURL") as? String
        let url = URL(string: info ?? "") ?? URL(string: "http://127.0.0.1:8787")!
        #if targetEnvironment(simulator)
        let demo = true
        #else
        let demo = ProcessInfo.processInfo.arguments.contains("-demo")
        #endif
        return RuntimeConfig(demo: demo, apiURL: url)
    }
}
