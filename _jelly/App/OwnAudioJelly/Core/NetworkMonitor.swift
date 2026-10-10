import Network
import Observation

/// Whether the phone has a network path at all. It can't tell a Wi-Fi with no internet from a
/// working one; short request timeouts and the saved answers cover that case.
@Observable
@MainActor
final class NetworkMonitor {
    private(set) var isConnected = true
    /// Mobile data or a phone's hotspot: the system's own idea of a connection that costs.
    private(set) var isExpensive = false
    @ObservationIgnored var onChange: ((Bool) -> Void)?
    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            let expensive = path.isExpensive
            Task { @MainActor in
                guard let self, self.isConnected != connected || self.isExpensive != expensive else { return }
                self.isConnected = connected
                self.isExpensive = expensive
                self.onChange?(connected)
            }
        }
        monitor.start(queue: DispatchQueue(label: "NetworkMonitor"))
    }
}
