import Foundation
import OwnAudioKit

/// What the server's event stream says about identify runs.
enum IdentifySignal: Sendable, Equatable {
    /// The server accepted the stream: it will tell about progress from now on.
    case open
    /// The connection ended; it is tried again after a pause.
    case closed
    case progress(IdentifyProgress)
}

enum IdentifyEvents {
    static let firstRetry: Duration = .seconds(2)
    static let longestRetry: Duration = .seconds(60)

    /// The stream opening and closing, and its `identify` events. Reconnects after a pause
    /// that doubles with every failed try, up to a minute, and starts over at 2 s once a
    /// connection opened: an unreachable server used to be asked every 15 s for as long as the
    /// screen was open.
    static func signals(_ client: OwnAudioClient) -> AsyncStream<IdentifySignal> {
        AsyncStream { continuation in
            let task = Task {
                var wait = firstRetry
                while !Task.isCancelled {
                    let opened = OpenFlag()
                    do {
                        let events = client.events(onOpen: {
                            opened.set()
                            continuation.yield(.open)
                        })
                        for try await event in events {
                            if let progress = IdentifyProgress(event) { continuation.yield(.progress(progress)) }
                        }
                    } catch {}
                    continuation.yield(.closed)
                    let (pause, next) = retry(after: wait, opened: opened.value)
                    wait = next
                    try? await Task.sleep(for: pause)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// How long to wait before the next try, and the wait after that one.
    static func retry(after wait: Duration, opened: Bool) -> (pause: Duration, next: Duration) {
        let pause = opened ? firstRetry : wait
        return (pause, min(pause * 2, longestRetry))
    }

    private final class OpenFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var opened = false
        var value: Bool { lock.withLock { opened } }
        func set() { lock.withLock { opened = true } }
    }
}

/// Runs an action at most once per `interval`. A call inside the interval is not lost: one run
/// follows when the interval is up, for every call made meanwhile. A run of identify events
/// (one per song matched) used to reload the whole list for each.
@MainActor
final class ReloadThrottle {
    let interval: TimeInterval
    private var last = Date.distantPast
    private var trailing: Task<Void, Never>?

    init(interval: TimeInterval) {
        self.interval = interval
    }

    func run(_ action: @escaping @MainActor @Sendable () async -> Void) async {
        guard trailing == nil else { return }
        let wait = interval - Date().timeIntervalSince(last)
        if wait <= 0 {
            last = Date()
            await action()
            return
        }
        trailing = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            self.trailing = nil
            self.last = Date()
            await action()
        }
    }

    /// A reload made some other way counts as a run.
    func noteRan() {
        last = Date()
    }

    func cancel() {
        trailing?.cancel()
        trailing = nil
    }
}

/// Keeps an identify screen current: the event stream says when something moved, and a reload
/// follows, at most every 2 s. A slow poll stands in only while a run is going and the stream
/// can't help — closed, or open but silent for half a minute (a server that sends no identify
/// events). Polling and listening at once used to load everything twice.
@MainActor
final class IdentifyFollower {
    static let pollEvery: Duration = .seconds(10)
    static let silenceBeforePolling: TimeInterval = 30

    private var isOpen = false
    private var lastHeard = Date.distantPast
    private let throttle = ReloadThrottle(interval: 2)

    static func shouldPoll(runActive: Bool, streamOpen: Bool, silentFor: TimeInterval) -> Bool {
        runActive && (!streamOpen || silentFor >= silenceBeforePolling)
    }

    /// Until the calling task is cancelled.
    func follow(
        _ client: OwnAudioClient,
        matching: @escaping @Sendable (IdentifyProgress) -> Bool = { _ in true },
        runActive: @escaping @MainActor @Sendable () -> Bool,
        reload: @escaping @MainActor @Sendable () async -> Void
    ) async {
        async let listening: Void = listen(client, matching: matching, reload: reload)
        async let polling: Void = poll(runActive: runActive, reload: reload)
        _ = await (listening, polling)
        throttle.cancel()
    }

    private func listen(
        _ client: OwnAudioClient, matching: @escaping @Sendable (IdentifyProgress) -> Bool,
        reload: @escaping @MainActor @Sendable () async -> Void
    ) async {
        for await signal in IdentifyEvents.signals(client) {
            switch signal {
            case .open:
                isOpen = true
                lastHeard = Date()
            case .closed:
                isOpen = false
            case .progress(let progress):
                lastHeard = Date()
                if matching(progress) { await throttle.run(reload) }
            }
        }
    }

    private func poll(runActive: @escaping @MainActor @Sendable () -> Bool, reload: @escaping @MainActor @Sendable () async -> Void) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.pollEvery)
            guard !Task.isCancelled else { return }
            guard Self.shouldPoll(runActive: runActive(), streamOpen: isOpen, silentFor: Date().timeIntervalSince(lastHeard)) else { continue }
            throttle.noteRan()
            await reload()
        }
    }
}
