import ManagedSettings
import ManagedSettingsUI
import ScrollTaxCore
import UIKit

/// The words on Apple's block screen. Apple draws the screen, we only choose the text.
class ScrollTaxShieldConfiguration: ShieldConfigurationDataSource {
    private func make() -> ShieldConfiguration {
        let policy = SharedConfig.policyStore().load()
        return ShieldConfiguration(
            backgroundBlurStyle: .systemMaterial,
            backgroundColor: nil,
            icon: nil,
            title: .init(text: "Blocked by ScrollTax", color: .label),
            subtitle: .init(
                text: "Open ScrollTax to unlock for \(policy.priceText()) (\(policy.unlockMinutes) minutes). "
                    + "Or just close this and do something else.",
                color: .secondaryLabel),
            primaryButtonLabel: .init(text: "Close", color: .white),
            primaryButtonBackgroundColor: .systemBlue,
            secondaryButtonLabel: .init(text: "Remind me to open ScrollTax", color: .systemBlue))
    }

    override func configuration(shielding application: Application) -> ShieldConfiguration { make() }

    override func configuration(shielding application: Application, in category: ActivityCategory)
        -> ShieldConfiguration
    { make() }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration { make() }

    override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory)
        -> ShieldConfiguration
    { make() }
}
