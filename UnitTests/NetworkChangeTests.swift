import Testing

@testable import OwnAudioMusic

/// What a change of network sets off, and when.
@Suite("Network changes")
@MainActor
struct NetworkChangeTests {
    @Test("the same interfaces in another order are the same network")
    func reorderIsNoChange() {
        let one = NetworkMonitor.signature(connected: true, interfaces: ["wifi-en0", "cellular-pdp_ip0", "other-utun3"])
        let two = NetworkMonitor.signature(connected: true, interfaces: ["other-utun3", "wifi-en0", "cellular-pdp_ip0"])
        #expect(one == two)
        #expect(one != NetworkMonitor.signature(connected: true, interfaces: ["cellular-pdp_ip0", "other-utun3"]), "Wi-Fi gone is a change")
        #expect(one != NetworkMonitor.signature(connected: false, interfaces: ["wifi-en0", "cellular-pdp_ip0", "other-utun3"]))
    }

    @Test("a burst of changes runs the action once, after it has been quiet")
    func burstRunsOnce() async throws {
        let debouncer = Debouncer(delay: .milliseconds(300))
        var runs: [Int] = []
        for index in 1...4 {
            debouncer.schedule { runs.append(index) }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(runs.isEmpty, "nothing while the changes keep coming")
        try await Task.sleep(for: .milliseconds(700))
        #expect(runs == [4], "once, for the last change")
    }

    @Test("losing the network cancels what waited for it to settle")
    func cancelDrops() async throws {
        let debouncer = Debouncer(delay: .milliseconds(200))
        var ran = false
        debouncer.schedule { ran = true }
        debouncer.cancel()
        try await Task.sleep(for: .milliseconds(500))
        #expect(!ran)
    }

    @Test("in the background only what waited is sent; addresses only for the player")
    func backgroundDoesLess() {
        #expect(AppModel.afterNetworkChange(inForeground: true, playerLoaded: false) == (true, true))
        #expect(AppModel.afterNetworkChange(inForeground: false, playerLoaded: true) == (true, false))
        #expect(AppModel.afterNetworkChange(inForeground: false, playerLoaded: false) == (false, false))
    }
}
