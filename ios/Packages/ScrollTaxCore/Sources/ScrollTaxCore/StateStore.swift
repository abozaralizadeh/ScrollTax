import Foundation

public protocol StateStore: AnyObject {
    func load() -> AppState
    func save(_ state: AppState)
}

extension StateStore {
    /// Load, change, save. Keeps each change to one short step.
    @discardableResult
    public func update<T>(_ change: (inout AppState) -> T) -> T {
        var s = load()
        let result = change(&s)
        save(s)
        return result
    }
}

public final class MemoryStateStore: StateStore {
    private var state = AppState()
    public init() {}
    public func load() -> AppState { state }
    public func save(_ s: AppState) { state = s }
}

/// Keeps the state in UserDefaults. Pass the app group's suite name so the app
/// and its extensions see the same data.
public final class UserDefaultsStateStore: StateStore {
    private let defaults: UserDefaults
    private let key: String

    public init(suiteName: String?, key: String = "scrolltax.state") {
        self.defaults = suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        self.key = key
    }

    public func load() -> AppState {
        guard let data = defaults.data(forKey: key),
              let state = try? JSONCoding.decoder.decode(AppState.self, from: data)
        else { return AppState() }
        return state
    }

    public func save(_ state: AppState) {
        if let data = try? JSONCoding.encoder.encode(state) { defaults.set(data, forKey: key) }
    }
}

public enum JSONCoding {
    private static func parse(_ s: String) -> Date? {
        let withMs = ISO8601DateFormatter()
        withMs.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withMs.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            guard let date = parse(s) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Bad date: \(s)"))
            }
            return date
        }
        return d
    }

    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var c = encoder.singleValueContainer()
            try c.encode(f.string(from: date))
        }
        return e
    }
}

/// The policy is stored next to the state so the extensions use the same numbers as the app.
public final class PolicyStore {
    private let defaults: UserDefaults
    private let key = "scrolltax.policy"

    public init(suiteName: String?) {
        self.defaults = suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    public func load() -> Policy {
        guard let data = defaults.data(forKey: key),
              let policy = try? JSONDecoder().decode(Policy.self, from: data)
        else { return .proposed }
        return policy
    }

    public func save(_ policy: Policy) {
        if let data = try? JSONEncoder().encode(policy) { defaults.set(data, forKey: key) }
    }
}
