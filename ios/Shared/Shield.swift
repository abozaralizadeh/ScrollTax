import FamilyControls
import Foundation
import ManagedSettings
import ScrollTaxCore

/// Names and storage that the app and its extensions share.
enum SharedConfig {
    /// Placeholder. Must match the app group created in the Apple developer account.
    static let appGroup = "group.app.scrolltax"
    static let selectionKey = "scrolltax.selection"
    static let activityName = "scrolltax.unlock"

    static func stateStore() -> UserDefaultsStateStore { UserDefaultsStateStore(suiteName: appGroup) }
    static func policyStore() -> PolicyStore { PolicyStore(suiteName: appGroup) }
}

/// What the person chose to block, kept as Apple's private tokens. We never see which apps these are.
struct SelectionStore {
    private let defaults = UserDefaults(suiteName: SharedConfig.appGroup) ?? .standard

    func load() -> FamilyActivitySelection {
        guard let data = defaults.data(forKey: SharedConfig.selectionKey),
              let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
        else { return FamilyActivitySelection() }
        return selection
    }

    func save(_ selection: FamilyActivitySelection) {
        if let data = try? JSONEncoder().encode(selection) { defaults.set(data, forKey: SharedConfig.selectionKey) }
    }
}

/// Puts the shield up or takes it down. The app and the monitor extension both call this.
enum Shield {
    private static let store = ManagedSettingsStore(named: .init("scrolltax"))

    static func apply(_ selection: FamilyActivitySelection) {
        store.shield.applications = selection.applicationTokens.isEmpty ? nil : selection.applicationTokens
        store.shield.applicationCategories =
            selection.categoryTokens.isEmpty ? nil : .specific(selection.categoryTokens)
        store.shield.webDomains = selection.webDomainTokens.isEmpty ? nil : selection.webDomainTokens
        store.shield.webDomainCategories =
            selection.categoryTokens.isEmpty ? nil : .specific(selection.categoryTokens)
    }

    static func clear() {
        store.clearAllSettings()
    }

    /// Decides from the saved state whether the shield should be up, and does it.
    static func syncFromSavedState(clock: ClockSample = .current()) {
        let state = SharedConfig.stateStore().load()
        let policy = SharedConfig.policyStore().load()
        if state.shieldShouldBeOn(clock: clock, policy: policy) {
            apply(SelectionStore().load())
        } else {
            clear()
        }
    }
}
