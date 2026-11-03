import ManagedSettings
import UserNotifications

/// What the two buttons on the block screen do. The block screen can't open our app or take a
/// payment, so the second button sends a notification that opens the app when tapped.
class ScrollTaxShieldAction: ShieldActionDelegate {
    private func respond(to action: ShieldAction, completionHandler: @escaping (ShieldActionResponse) -> Void) {
        switch action {
        case .primaryButtonPressed:
            completionHandler(.close)
        case .secondaryButtonPressed:
            let content = UNMutableNotificationContent()
            content.title = "ScrollTax"
            content.body = "Tap to open ScrollTax if you want to unlock."
            let request = UNNotificationRequest(
                identifier: "scrolltax.remind", content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
            UNUserNotificationCenter.current().add(request) { _ in completionHandler(.close) }
        default:
            completionHandler(.close)
        }
    }

    override func handle(action: ShieldAction, for application: ApplicationToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        respond(to: action, completionHandler: completionHandler)
    }

    override func handle(action: ShieldAction, for webDomain: WebDomainToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        respond(to: action, completionHandler: completionHandler)
    }

    override func handle(action: ShieldAction, for category: ActivityCategoryToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        respond(to: action, completionHandler: completionHandler)
    }
}
