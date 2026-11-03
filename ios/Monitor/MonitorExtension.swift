import DeviceActivity
import Foundation

/// Runs when the unlock window ends, even if the main app is closed, and puts the block back.
class ScrollTaxMonitor: DeviceActivityMonitor {
    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        Shield.syncFromSavedState()
    }

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        // Also covers the leave wait finishing while the unlock window is open.
        Shield.syncFromSavedState()
    }
}
