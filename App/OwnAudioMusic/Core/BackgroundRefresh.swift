import BackgroundTasks
import Foundation
import OSLog

private let log = Logger(subsystem: "audio.own.musicplayer", category: "backgroundRefresh")

/// Brings the library copies up to date and sends plays and edits still waiting while the app is
/// in the background, so the library is current when it opens. iOS decides when (and whether)
/// it runs; the app only asks for every hour or so. Copied from the books app.
enum BackgroundRefresh {
    static let identifier = "audio.own.musicplayer.refresh"

    /// At launch, before the app finishes launching, as `BGTaskScheduler` requires.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return task.setTaskCompleted(success: false) }
            schedule()
            // BackgroundTasks' task isn't Sendable; completing it is safe from any thread.
            nonisolated(unsafe) let refresh = task
            let work = Task { @MainActor in
                let model = AppModel.shared
                if !model.hasLoaded { await model.load() }
                await model.syncCatalogues()
                await model.flushPendingScrobbles()
                await model.flushPendingChanges()
                await model.refreshWidget(fetch: true)
                log.info("refreshed in the background")
                refresh.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    /// When the app goes to the background.
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            log.info("not scheduled: \(String(describing: error), privacy: .public)")
        }
    }
}
