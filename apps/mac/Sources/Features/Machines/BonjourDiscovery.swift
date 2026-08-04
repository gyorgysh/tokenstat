// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation

struct DiscoveredDaemon: Identifiable, Hashable, Sendable {
    let key: String
    let fingerprint: String
    let label: String
    let address: String?

    var id: String { key }
}

#if os(macOS)
import Network

/// Finds advertised daemons, but never opens the remote protocol.
@MainActor
final class BonjourDiscovery {
    private var browser: NWBrowser?
    private var connections: [String: NWConnection] = [:]
    private var resolvedAddresses: [String: String] = [:]
    private(set) var daemons: [DiscoveredDaemon] = []
    var changed: (([DiscoveredDaemon]) -> Void)?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(
            for: .bonjour(type: "_tokenstat._tcp", domain: nil),
            using: .tcp
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.update(results)
            }
        }
        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                NSLog("tokenstat Bonjour discovery failed: %@", error.localizedDescription)
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        resolvedAddresses.removeAll()
        daemons = []
        changed?([])
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        var next: [DiscoveredDaemon] = []
        var activeKeys = Set<String>()

        for result in results {
            guard case let .bonjour(txt) = result.metadata,
                  let key = value(for: "key", in: txt),
                  let fingerprint = value(for: "fingerprint", in: txt),
                  let label = value(for: "label", in: txt)
            else { continue }

            activeKeys.insert(key)
            let address = resolvedAddress(for: result.endpoint, key: key)
            next.append(DiscoveredDaemon(
                key: key,
                fingerprint: fingerprint,
                label: label,
                address: address
            ))
        }

        for key in Array(connections.keys) where !activeKeys.contains(key) {
            connections[key]?.cancel()
            connections.removeValue(forKey: key)
            resolvedAddresses.removeValue(forKey: key)
        }

        daemons = next.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        changed?(daemons)
    }

    private func resolvedAddress(for endpoint: NWEndpoint, key: String) -> String? {
        if let address = resolvedAddresses[key] {
            return address
        }
        if case let .hostPort(host, port) = endpoint {
            return formatAddress(host: host, port: port)
        }

        if let connection = connections[key],
           case let .hostPort(host, port) = connection.currentPath?.remoteEndpoint {
            return formatAddress(host: host, port: port)
        }

        let connection = NWConnection(to: endpoint, using: .tcp)
        connections[key] = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard state == .ready else { return }
            Task { @MainActor in
                guard let self, let connection = self.connections[key],
                      case let .hostPort(host, port) = connection.currentPath?.remoteEndpoint,
                      let index = self.daemons.firstIndex(where: { $0.key == key })
                else { return }
                let address = self.formatAddress(host: host, port: port)
                self.resolvedAddresses[key] = address
                self.connections.removeValue(forKey: key)?.cancel()
                self.daemons[index] = DiscoveredDaemon(
                    key: self.daemons[index].key,
                    fingerprint: self.daemons[index].fingerprint,
                    label: self.daemons[index].label,
                    address: address
                )
                self.changed?(self.daemons)
            }
        }
        connection.start(queue: .main)
        return nil
    }

    private func value(for key: String, in record: NWTXTRecord) -> String? {
        guard let entry = record.getEntry(for: key), let data = entry.data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func formatAddress(host: NWEndpoint.Host, port: NWEndpoint.Port) -> String {
        let text = String(describing: host)
        if text.contains(":") && !text.hasPrefix("[") {
            return "[\(text)]:\(port.rawValue)"
        }
        return "\(text):\(port.rawValue)"
    }
}
#else
/// Discovery is a macOS feature until the iOS host/browser flow exists.
@MainActor
final class BonjourDiscovery {
    private(set) var daemons: [DiscoveredDaemon] = []
    var changed: (([DiscoveredDaemon]) -> Void)?

    func start() {}
    func stop() {}
}
#endif
