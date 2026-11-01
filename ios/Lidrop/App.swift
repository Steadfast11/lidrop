import SwiftUI

@main
struct LidropApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase
    @State private var bgTask = UIBackgroundTaskIdentifier.invalid

    init() {
        Looks.load()
        FxGPU.prepare()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.connector)
                .preferredColorScheme(.dark)
                .onAppear {
                    // test hooks: launch with `-connect HOST[:PORT]`, `-look A|B|C`
                    if let h = UserDefaults.standard.string(forKey: "connect") { model.connector.connectManual(h) }
                    if let l = UserDefaults.standard.string(forKey: "look") { Looks.save(l) }
                }
                .onChange(of: model.conn) { _, c in UIApplication.shared.isIdleTimerDisabled = c.isUp }
                .onChange(of: phase) { _, p in
                    switch p {
                    case .active: endBackgroundTask(); model.connector.onForeground()
                    case .background: model.connector.onBackground(); finishInBackground()
                    default: break
                    }
                }
        }
    }

    /// A transfer in flight gets the time iOS allows; everything else leaves at once, the sockets would die anyway.
    private func finishInBackground() {
        if !model.flags.sending && !model.flags.receiving { model.leave(); return }
        bgTask = UIApplication.shared.beginBackgroundTask { [self] in model.leave(); endBackgroundTask() }
        Task { @MainActor in
            while model.flags.sending || model.flags.receiving, bgTask != .invalid { try? await Task.sleep(nanoseconds: 300_000_000) }
            if bgTask != .invalid { model.leave(); endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid }
    }
}
