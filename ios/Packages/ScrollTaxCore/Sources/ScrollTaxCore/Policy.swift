import Foundation

/// The rules of the deal. The backend sends these (GET /v1/config) so a change
/// there shows up without a new app release. `proposed` holds the default numbers and
/// is what the app uses before it has heard from the backend.
public struct Policy: Codable, Equatable, Sendable {
    public var productId: String
    public var priceMinor: Int
    public var currency: String
    public var unlockMinutes: Int
    public var dailyUnlockLimit: Int
    public var leaveWaitHours: Int
    public var minAge: Int
    public var termsVersion: String

    public init(
        productId: String, priceMinor: Int, currency: String, unlockMinutes: Int,
        dailyUnlockLimit: Int, leaveWaitHours: Int, minAge: Int, termsVersion: String
    ) {
        self.productId = productId
        self.priceMinor = priceMinor
        self.currency = currency
        self.unlockMinutes = unlockMinutes
        self.dailyUnlockLimit = dailyUnlockLimit
        self.leaveWaitHours = leaveWaitHours
        self.minAge = minAge
        self.termsVersion = termsVersion
    }

    public static let proposed = Policy(
        productId: "app.scrolltax.unlock15", priceMinor: 99, currency: "EUR", unlockMinutes: 15,
        dailyUnlockLimit: 4, leaveWaitHours: 24, minAge: 18, termsVersion: "2026-11-draft")

    public func priceText(locale: Locale = .current) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.locale = locale
        return f.string(from: NSNumber(value: Double(priceMinor) / 100)) ?? "\(priceMinor) \(currency)"
    }

    public var unlockSeconds: TimeInterval { TimeInterval(unlockMinutes * 60) }
    public var leaveWaitSeconds: TimeInterval { TimeInterval(leaveWaitHours * 3600) }
}
