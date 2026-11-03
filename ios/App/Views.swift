import AuthenticationServices
import FamilyControls
import ScrollTaxCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        // The clock ticks once a second so countdowns and the end of an unlock stay current.
        // The start date is fixed on purpose. With `.now` every redraw restarted the timeline and caused an endless redraw loop.
        TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: 0), by: 1)) { timeline in
            content(now: timeline.date)
                .onChange(of: timeline.date) { _, date in model.refresh() }
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        if !model.signedIn {
            OnboardingView()
        } else if !model.authorized && model.phase(at: now) == .notStarted {
            PermissionView()
        } else if model.phase(at: now) == .notStarted {
            PickerView(starting: true)
        } else {
            HomeView(now: now)
        }
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @State private var step = 0
    @State private var ageOK = false
    @State private var termsOK = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                if step == 0 { welcome } else { terms }
                Spacer()
            }
            .padding(24)
            .navigationTitle("ScrollTax")
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Here's the deal").font(.title2.bold())
            Text("Your social media gets blocked. If you want to use it, you pay "
                + "\(model.priceLabel) for \(model.policy.unlockMinutes) minutes.")
            Text("You can unlock up to \(model.policy.dailyUnlockLimit) times a day.")
            Text("You can leave whenever you like, for free. It takes \(model.policy.leaveWaitHours) hours, "
                + "and deleting your account is instant.")
            Text("This isn't a medical product or a treatment.").font(.footnote).foregroundStyle(.secondary)
            Button("Continue") { step = 1 }
                .buttonStyle(.borderedProminent).controlSize(.large)
        }
    }

    private var terms: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("I am \(model.policy.minAge) or over", isOn: $ageOK)
            Toggle("I accept the terms and the privacy policy", isOn: $termsOK)
            HStack {
                Link("Terms", destination: model.legalBase.appendingPathComponent("terms"))
                Link("Privacy", destination: model.legalBase.appendingPathComponent("privacy"))
            }
            if model.config.demo {
                Button("Continue in demo mode") { Task { await model.demoSignIn(ageConfirmed: ageOK) } }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!(ageOK && termsOK) || model.busy)
            } else {
                SignInWithAppleButton(.continue, onRequest: { $0.requestedScopes = [] }) { result in
                    if case .success(let auth) = result,
                       let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                       let data = cred.identityToken, let token = String(data: data, encoding: .utf8) {
                        Task { await model.signIn(identityToken: token, ageConfirmed: ageOK) }
                    }
                }
                .frame(height: 50)
                .disabled(!(ageOK && termsOK) || model.busy)
            }
        }
    }
}

struct PermissionView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Allow Screen Time").font(.title2.bold())
            Text("ScrollTax uses Apple's Screen Time to block apps. Apple will ask you to allow it. "
                + "We never see which apps you pick or how long you use them.")
            Button("Allow Screen Time") { Task { await model.requestScreenTimeAccess() } }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.busy)
            Spacer()
        }
        .padding(24)
    }
}

struct PickerView: View {
    @EnvironmentObject var model: AppModel
    let starting: Bool
    @State private var selection = SelectionStore().load()
    @State private var showing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(starting ? "What should be blocked?" : "Block more").font(.title2.bold())
            Text("Open the list and choose the Social category. You can add more apps and sites too.")
            if model.config.demo {
                Text("Demo mode: nothing real is blocked here.").foregroundStyle(.secondary)
            } else {
                Button("Choose apps and sites") { showing = true }
                    .buttonStyle(.bordered).controlSize(.large)
            }
            if starting {
                Button("Turn on the block") { model.turnOnBlock() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!model.config.demo && !SelectionStore.hasAnything(selection))
            }
            Spacer()
        }
        .padding(24)
        .familyActivityPicker(isPresented: $showing, selection: $selection)
        .onChange(of: selection) { old, new in
            // Once the block is running you can add things but not take them away.
            let merged = starting ? new : SelectionStore.union(old, new)
            SelectionStore().save(merged)
            if merged != selection { selection = merged }
            model.refresh()
        }
    }
}

extension SelectionStore {
    static func hasAnything(_ s: FamilyActivitySelection) -> Bool {
        !(s.applicationTokens.isEmpty && s.categoryTokens.isEmpty && s.webDomainTokens.isEmpty)
    }

    static func union(_ a: FamilyActivitySelection, _ b: FamilyActivitySelection) -> FamilyActivitySelection {
        var out = b
        out.applicationTokens.formUnion(a.applicationTokens)
        out.categoryTokens.formUnion(a.categoryTokens)
        out.webDomainTokens.formUnion(a.webDomainTokens)
        return out
    }
}

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    let now: Date
    @State private var confirming = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if model.blockIsOffBySystem { offBanner }
                    if model.phoneClockWrong { clockNote }
                    status
                    actions
                }
                .padding(24)
            }
            .navigationTitle("ScrollTax")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink("History") { HistoryView() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink("Settings") { SettingsView() }
                }
            }
            .sheet(isPresented: $confirming) { ConfirmUnlockView(isPresented: $confirming) }
        }
    }

    private var offBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("The block is off", systemImage: "exclamationmark.triangle.fill").font(.headline)
            Text("Screen Time access was switched off, so nothing is blocked right now.")
            Button("Turn it back on") { Task { await model.requestScreenTimeAccess() } }
                .buttonStyle(.borderedProminent)
        }
        .padding().frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
    }

    private var clockNote: some View {
        Label("Your phone's date looks wrong. ScrollTax is using the right time.", systemImage: "clock.badge.exclamationmark")
            .font(.footnote).foregroundStyle(.secondary)
    }

    @ViewBuilder private var status: some View {
        switch model.phase(at: now) {
        case .unlocked(let end):
            VStack(alignment: .leading, spacing: 4) {
                Label("Unlocked", systemImage: "lock.open.fill").font(.title2.bold())
                Text(end, style: .timer).font(.system(size: 54, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("until the block comes back").foregroundStyle(.secondary)
            }
        case .leaving(let at):
            VStack(alignment: .leading, spacing: 4) {
                Label("Leaving", systemImage: "arrow.right.circle").font(.title2.bold())
                Text("The block comes off in").foregroundStyle(.secondary)
                Text(at, style: .timer).font(.title.bold()).monospacedDigit()
            }
        case .left:
            VStack(alignment: .leading, spacing: 4) {
                Label("The block is off", systemImage: "lock.open").font(.title2.bold())
                Text("You've left. Your social media works as normal.").foregroundStyle(.secondary)
            }
        default:
            VStack(alignment: .leading, spacing: 4) {
                Label("Blocked", systemImage: "lock.fill").font(.title2.bold())
                Text("Your social media is blocked.").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var actions: some View {
        switch model.phase(at: now) {
        case .left:
            Button("Turn the block back on") { model.turnOnBlock() }
                .buttonStyle(.borderedProminent).controlSize(.large)
        case .unlocked:
            leaveNote
        default:
            unlockButton
            if case .leaving = model.phase(at: now) {
                Button("Cancel leaving") { model.cancelLeave() }.buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder private var leaveNote: some View {
        if model.state.leaveRequestedAt != nil {
            Text("You're leaving. The block won't come back after this unlock.").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var unlockButton: some View {
        switch model.unlockDecision {
        case .allowed(let left):
            Button("Unlock for \(model.priceLabel)") { confirming = true }
                .buttonStyle(.borderedProminent).controlSize(.large)
            Text("\(model.policy.unlockMinutes) minutes. \(left) of \(model.policy.dailyUnlockLimit) left today.")
                .font(.footnote).foregroundStyle(.secondary)
        case .limitReached(let resets):
            VStack(alignment: .leading, spacing: 4) {
                Text("No more unlocks today").font(.headline)
                Text("You've used all \(model.policy.dailyUnlockLimit). It resets at midnight, in ")
                    .foregroundStyle(.secondary) + Text(resets, style: .relative).foregroundStyle(.secondary)
            }
        default:
            EmptyView()
        }
    }
}

struct ConfirmUnlockView: View {
    @EnvironmentObject var model: AppModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Unlock for \(model.policy.unlockMinutes) minutes?").font(.title2.bold())
            Text("You'll pay \(model.priceLabel). When the time's up, the block comes back by itself.")
            if case .allowed(let left) = model.unlockDecision {
                Text("This uses 1 of your \(left) unlocks left today.").foregroundStyle(.secondary)
            }
            Button("Pay \(model.priceLabel) and unlock") {
                Task {
                    await model.unlock()
                    isPresented = false
                }
            }
            .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.busy)
            Button("Not now", role: .cancel) { isPresented = false }.buttonStyle(.bordered)
            Spacer()
        }
        .padding(24)
        .presentationDetents([.medium])
    }
}

// MARK: - History and settings

struct HistoryView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List {
            if model.history.isEmpty { Text("No payments yet.").foregroundStyle(.secondary) }
            ForEach(model.history) { p in
                HStack {
                    VStack(alignment: .leading) {
                        Text(p.purchasedAt, style: .date) + Text(" ") + Text(p.purchasedAt, style: .time)
                        if p.isRefunded { Text("Refunded").font(.footnote).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Text(String(format: "%.2f %@", Double(p.amountMinor) / 100, p.currency))
                        .strikethrough(p.isRefunded)
                }
            }
        }
        .navigationTitle("Payments")
        .task { await model.loadHistory() }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmDelete = false
    @State private var confirmLeave = false

    var body: some View {
        List {
            Section("Blocking") {
                NavigationLink("Block more apps and sites") { PickerView(starting: false) }
            }
            Section("Leaving") {
                if model.state.leaveRequestedAt == nil {
                    Button("Leave ScrollTax") { confirmLeave = true }
                    Text("Leaving is free. The block comes off \(model.policy.leaveWaitHours) hours after you ask. "
                        + "You can still unlock while you wait, and you can change your mind.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Button("Cancel leaving") { model.cancelLeave() }
                }
                Button("Delete my account now", role: .destructive) { confirmDelete = true }
                Text("This removes the block straight away and deletes your account.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Your data") {
                if let file = model.exportFile {
                    ShareLink("Share my data file", item: file)
                } else {
                    Button("Get a copy of my data") { Task { await model.prepareDataCopy() } }
                }
                Text("A file with your account and payment records, as we hold them.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("About") {
                Link("Terms", destination: model.legalBase.appendingPathComponent("terms"))
                Link("Privacy", destination: model.legalBase.appendingPathComponent("privacy"))
                Link("Support", destination: model.legalBase.appendingPathComponent("support"))
                Link("Where to get help", destination: model.legalBase.appendingPathComponent("help"))
                Text("ScrollTax isn't a medical product or a treatment. If social media is causing you real "
                    + "harm, a doctor or counsellor can help.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Leave ScrollTax?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Start the \(model.policy.leaveWaitHours) hour wait") { model.requestLeave() }
        }
        .confirmationDialog("Delete your account?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete and remove the block", role: .destructive) { Task { await model.deleteAccount() } }
        }
    }
}
