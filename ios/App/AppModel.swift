import FamilyControls
import Foundation
import ScrollTaxCore
import SwiftUI
@preconcurrency import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var state: AppState
    @Published private(set) var policy: Policy
    @Published private(set) var signedIn: Bool
    @Published private(set) var authorized: Bool
    @Published private(set) var history: [PaymentRecord] = []
    @Published private(set) var priceLabel: String
    /// The phone's date is clearly off and the backend's time is being used instead.
    @Published private(set) var phoneClockWrong = false
    /// A file with the person's own data, ready to share, once they ask for it.
    @Published private(set) var exportFile: URL?
    @Published var busy = false
    @Published var message: String?

    let config: RuntimeConfig
    private let api: APIClient
    private let blocker: Blocking
    private let purchaser: Purchasing
    private let store: StateStore
    private let policies: PolicyStore
    private var lastShield: Bool?
    private var lastClockSync: Date?

    var timeZone: TimeZone { .current }

    init(config: RuntimeConfig = .load(), blocker: Blocking? = nil, purchaser: Purchasing? = nil,
         store: StateStore? = nil, policies: PolicyStore? = nil, api: APIClient? = nil) {
        self.config = config
        if config.demo && ProcessInfo.processInfo.arguments.contains("-reset") {
            // For UI tests: start from a clean demo install.
            UserDefaults.standard.removeObject(forKey: "scrolltax.demo.state")
            Keychain.set(nil, for: "session")
            Keychain.set(nil, for: "demoUser")
        }
        self.blocker = blocker ?? (config.demo ? DemoBlocker() : RealBlocker())
        self.purchaser = purchaser ?? (config.demo ? DemoPurchaser() : StoreKitPurchaser())
        self.store = store ?? (config.demo
            ? UserDefaultsStateStore(suiteName: nil, key: "scrolltax.demo.state")
            : SharedConfig.stateStore())
        self.policies = policies ?? (config.demo ? PolicyStore(suiteName: nil) : SharedConfig.policyStore())
        let token = Keychain.get("session")
        self.api = api ?? APIClient(baseURL: config.apiURL, token: token)
        self.signedIn = token != nil
        let initialState = self.store.load()
        let initialPolicy = self.policies.load()
        self.state = initialState
        self.policy = initialPolicy
        self.priceLabel = initialPolicy.priceText()
        self.authorized = self.blocker.isAuthorized
    }

    /// `now` only makes the screen redraw each second. The real time comes from the clock guard.
    func phase(at now: Date) -> Phase { state.phase(clock: .current(), policy: policy) }

    var unlockDecision: UnlockDecision {
        state.unlockDecision(clock: .current(), timeZone: timeZone, policy: policy)
    }

    /// The block is meant to be on, but Screen Time access has been switched off.
    var blockIsOffBySystem: Bool {
        state.blockEnabled && !state.hasLeft && !authorized && signedIn
    }

    var legalBase: URL { config.apiURL.appendingPathComponent("legal") }

    // MARK: start up and clock

    func start() async {
        refresh()
        await retryAccountDeletion()
        if let fresh = try? await api.config() {
            policy = fresh
            policies.save(fresh)
        }
        await syncClock(force: true)
        if let price = await purchaser.displayPrice(productId: policy.productId) { priceLabel = price }
        for case .success(let jws, let date, let finish) in await purchaser.unfinished() {
            await record(signed: jws, purchaseDate: date, finish: finish)
        }
        await flushPending()
        refresh()
    }

    /// Asks the backend for the real time and today's count, at most every ten minutes.
    func syncClock(force: Bool = false) async {
        if !force, let last = lastClockSync, Date().timeIntervalSince(last) < 600 { return }
        if await ClockSync.run(store: store, api: api, timeZone: timeZone) { lastClockSync = Date() }
        refresh()
    }

    /// Sends queued purchases. If the backend didn't count one (over the daily limit), its unlock is taken back.
    private func flushPending() async {
        await PendingSync.flush(store: store, api: api) { [self] result in
            guard result.payment.unlock == nil, !result.payment.isRefunded else { return }
            store.update { $0.revokeUnlock(startedAt: result.payment.purchasedAt) }
            lastShield = nil
            message = "That purchase went over today's limit of \(policy.dailyUnlockLimit), so it didn't unlock anything. "
                + "You can ask Apple for a refund."
        }
    }

    /// Called every second while the app is open, and when it comes to the front.
    func refresh() {
        let sample = ClockSample.current()
        var s = store.load()
        let leftNow = s.completeLeaveIfDue(clock: sample, policy: policy)
        let moved = s.clock.observe(sample)
        if leftNow || moved { store.save(s) }
        let wrong = s.phoneClockLooksWrong(sample)
        if phoneClockWrong != wrong { phoneClockWrong = wrong }
        // Only publish real changes. Publishing every tick would redraw the whole UI every second.
        if state != s { state = s }
        let nowAuthorized = blocker.isAuthorized
        if authorized != nowAuthorized { authorized = nowAuthorized }

        let wantShield = s.shieldShouldBeOn(clock: sample, policy: policy)
        if lastShield != wantShield {
            blocker.setShield(on: wantShield)
            lastShield = wantShield
            if wantShield { blocker.cancelReblock() }
        }
    }

    // MARK: sign in

    func signIn(identityToken: String, ageConfirmed: Bool) async {
        await run {
            let result = try await self.api.signIn(
                identityToken: identityToken, ageConfirmed: ageConfirmed, termsVersion: self.policy.termsVersion)
            Keychain.set(result.token, for: "session")
            self.signedIn = true
        }
    }

    /// Demo mode only: a made up Apple user, accepted by the local backend in APPLE_MODE=fake.
    func demoSignIn(ageConfirmed: Bool) async {
        let name = Keychain.get("demoUser") ?? UUID().uuidString
        Keychain.set(name, for: "demoUser")
        await signIn(identityToken: "fake-user:\(name)", ageConfirmed: ageConfirmed)
    }

    // MARK: block

    func requestScreenTimeAccess() async {
        await run {
            try await self.blocker.requestAuthorization()
            self.authorized = self.blocker.isAuthorized
        }
    }

    func turnOnBlock() {
        store.update { $0.enableBlock() }
        lastShield = nil
        refresh()
    }

    // MARK: unlock

    func unlock() async {
        guard case .allowed = unlockDecision else { return }
        await run {
            switch try await self.purchaser.purchase(productId: self.policy.productId) {
            case .success(let jws, let date, let finish):
                await self.record(signed: jws, purchaseDate: date, finish: finish)
                await self.flushPending()
            case .cancelled:
                break
            case .pending:
                self.message = "The purchase is waiting for approval. Nothing is unlocked yet."
            }
        }
    }

    /// Saves a paid purchase first, so it can't be lost, then starts the unlock and tells Apple we're done.
    private func record(signed: String, purchaseDate: Date, finish: () async -> Void) async {
        let sample = ClockSample.current()
        let before = store.load()
        let start = min(purchaseDate, before.clock.trustedNow(sample))
        let alreadyCounted = before.unlockStarts.contains { abs($0.timeIntervalSince(start)) < 1 }
        if !alreadyCounted {
            store.update { s in
                s.pendingTransactions.append(PendingTransaction(signedTransaction: signed, timeZone: timeZone.identifier))
                s.startUnlock(purchasedAt: purchaseDate, clock: sample, policy: policy)
            }
        }
        await finish()
        lastShield = nil
        refresh()
        let left = store.load().unlockRemaining(clock: .current())
        if left > 0 {
            // The system's timer runs on the phone's calendar, so give it the end as the calendar sees it.
            let wallEnd = Date().addingTimeInterval(left)
            blocker.scheduleReblock(from: Date(), to: wallEnd)
            scheduleWarning(endsAt: wallEnd)
        }
    }

    private func scheduleWarning(endsAt end: Date) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "ScrollTax"
            content.body = "Your unlock ends in one minute."
            let wait = max(1, end.timeIntervalSinceNow - 60)
            center.add(UNNotificationRequest(
                identifier: "scrolltax.warning", content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: wait, repeats: false)))
        }
    }

    // MARK: history

    func loadHistory() async {
        await run { self.history = try await self.api.payments() }
    }

    // MARK: your data

    /// Asks the backend for everything it holds about the person and saves it as a file they can share.
    func prepareDataCopy() async {
        await run {
            let data = try await self.api.exportData()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("scrolltax-my-data.json")
            try data.write(to: url, options: .atomic)
            self.exportFile = url
        }
    }

    // MARK: leaving and deleting

    func requestLeave() {
        store.update { $0.requestLeave(now: Date()) }
        refresh()
        Task { _ = try? await api.startLeave() }
    }

    func cancelLeave() {
        store.update { $0.cancelLeave() }
        lastShield = nil
        refresh()
        Task { _ = try? await api.cancelLeave() }
    }

    /// Wipes the phone first so nobody is stuck behind a missing connection, then tells the backend.
    func deleteAccount() async {
        blocker.cancelReblock()
        blocker.setShield(on: false)
        store.update { s in
            s.reset()
            s.accountDeletionPending = true
        }
        lastShield = nil
        refresh()
        await retryAccountDeletion()
    }

    private func retryAccountDeletion() async {
        guard store.load().accountDeletionPending else { return }
        do {
            try await api.deleteAccount()
        } catch let error as APIError where error.status == 401 {
            // The account is already gone or the session ended. Nothing left to delete.
        } catch {
            return
        }
        Keychain.set(nil, for: "session")
        store.update { $0.accountDeletionPending = false }
        signedIn = false
        refresh()
    }

    // MARK: helpers

    private func run(_ work: @escaping () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await work()
        } catch let error as APIError {
            message = error.message
        } catch is CancellationError {
        } catch {
            message = "That didn't work: \(error.localizedDescription)"
        }
    }
}
