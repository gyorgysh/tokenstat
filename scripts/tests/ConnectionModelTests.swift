// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ConnectionModel.swift.
import Foundation

enum BridgeError: Error { case core(code: String, message: String) }
struct Peer { let key: String; let label: String }
@MainActor final class ConnectivityModel {
    var isOffline = false
    static let retryInterval: Duration = .seconds(30)
}

@main struct ConnectionModelTests {
    @MainActor static func main() {
        let connectivity = ConnectivityModel()
        let connection = ConnectionModel()
        connection.attach(connectivity)
        connectivity.isOffline = true
        for method in ["account.logout", "account.cancelLogin", "sync.scheduleStatus"] {
            // Both roots use this classification for their offline precheck.
            assert(NetworkPlane.of(method: method) == nil, method)
        }
        assert(NetworkPlane.of(method: "account.status") == .account)
        assert(NetworkPlane.of(method: "account.deviceStart") == .account)
        assert(NetworkPlane.of(method: "sync.run") == .account)
        assert(NetworkPlane.of(method: "remote.call") == .peer)
        connectivity.isOffline = false
        let failure = URLError(.cannotConnectToHost)
        connection.note(plane: .account, peer: nil, failure: failure)
        connection.note(plane: .account, peer: nil, failure: failure)
        assert(connection.serviceFailing)
        for method in ["account.logout", "account.cancelLogin", "sync.scheduleStatus"] {
            if let plane = NetworkPlane.of(method: method) {
                connection.note(plane: plane, peer: nil, failure: nil)
            }
        }
        assert(connection.serviceFailing, "Local success cannot hide a service outage")
        connection.note(plane: .account, peer: nil, failure: nil)
        assert(!connection.serviceFailing)
        print("Connection model: offline local operations and service evidence passed")
    }
}
