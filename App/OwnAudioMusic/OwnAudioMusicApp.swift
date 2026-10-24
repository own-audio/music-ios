import SwiftUI

/// Registers the background refresh, and hands the background download session's events back
/// to the app: iOS relaunches it when a download finishes while it was gone.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BackgroundRefresh.register()
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            guard identifier == DownloadManager.sessionIdentifier else { return completionHandler() }
            let model = AppModel.shared
            model.downloads.backgroundCompletion = completionHandler
            // The next songs need the servers' addresses, which loading sets up.
            if !model.hasLoaded { await model.load() } else { model.downloads.resume() }
        }
    }
}

@main
struct OwnAudioMusicApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { if !model.hasLoaded { await model.load() } }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            // Audio keeps playing in the background, so this is a save, not a pause.
            if phase == .background { model.engine.saveProgressForTeardown() }
            model.sceneBecame(active: phase != .background)
        }
    }
}
