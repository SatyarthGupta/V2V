import Foundation
import Network

nonisolated protocol NetworkMonitoring: Sendable {
    /// Whether the device has a usable network path (Wi-Fi/cellular up).
    /// This says nothing about the Mac's token server, or about Local Network permission.
    func isInternetReachable() -> Bool
}

/// Tracks the device's network path with `NWPathMonitor` (PRD E10, D-021).
nonisolated final class NetworkMonitor: NetworkMonitoring, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "V2V.NetworkMonitor")
    private let lock = NSLock()
    /// Optimistic until the first update arrives: we'd rather show the more specific
    /// "can't reach the token server" checklist than a wrong "no internet".
    private var reachable = true

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.withLock { self.reachable = path.status == .satisfied }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    func isInternetReachable() -> Bool {
        lock.withLock { reachable }
    }
}

/// Test/UI-test double.
nonisolated final class FakeNetworkMonitor: NetworkMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var _reachable: Bool

    init(reachable: Bool = true) { _reachable = reachable }

    var reachable: Bool {
        get { lock.withLock { _reachable } }
        set { lock.withLock { _reachable = newValue } }
    }

    func isInternetReachable() -> Bool { reachable }
}
