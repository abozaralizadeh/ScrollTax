import SwiftUI

@main
struct ScrollTaxApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .task { await model.start() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.refresh(); Task { await model.syncClock() } }
                }
                .alert("ScrollTax", isPresented: Binding(
                    get: { model.message != nil },
                    set: { if !$0 { model.message = nil } })
                ) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(model.message ?? "")
                }
        }
    }
}
