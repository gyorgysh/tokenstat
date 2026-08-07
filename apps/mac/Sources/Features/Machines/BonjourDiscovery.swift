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
    /// From the advertisement, so a machine found nearby is named the same way
    /// on both screens without this process hashing anything.
    let words: String?
    let label: String
    let address: String?
    /// Whether the far machine is accepting connections right now. The daemon
    /// advertises whenever it runs, so a machine with remote linking turned
    /// off still shows up; the row must not offer a Connect that can only fail.
    let serving: Bool

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
    /// Why the browse is not producing results, when it is not. The two cases
    /// worth naming are the local network permission being denied and the
    /// system's responder refusing the browse type; both leave the list empty
    /// and both need a different fix than "wait".
    private(set) var browseError: String?
    var changed: (([DiscoveredDaemon]) -> Void)?
    var errorChanged: ((String?) -> Void)?

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
        browser.stateUpdateHandler = { [weak self] state in
            let message = Self.errorMessage(for: state)
            Task { @MainActor in
                guard let self else { return }
                self.browseError = message
                self.errorChanged?(message)
            }
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
        browseError = nil
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
            let serving = value(for: "serving", in: txt) == "1"
            next.append(DiscoveredDaemon(
                key: key,
                fingerprint: fingerprint,
                words: value(for: "words", in: txt),
                label: label,
                address: serving ? resolvedAddress(for: result.endpoint, key: key) : nil,
                serving: serving
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

    /// mDNS hands the endpoint straight to the browser in almost every case;
    /// the connection-based resolution below is only for the rare endpoint
    /// that arrives unresolved, and it gives up fast so the row is not the
    /// thing holding the list up.
    private func resolvedAddress(for endpoint: NWEndpoint, key: String) -> String? {
        if let address = resolvedAddresses[key] {
            return address
        }
        if case let .hostPort(host, port) = endpoint {
            return formatAddress(host: host, port: port)
        }

        let connection = NWConnection(to: endpoint, using: .tcp)
        connections[key] = connection
        var timedOut = false
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
                    words: self.daemons[index].words,
                    label: self.daemons[index].label,
                    address: address,
                    serving: self.daemons[index].serving
                )
                self.changed?(self.daemons)
            }
        }
        connection.start(queue: .main)
        Task { @MainActor [weak self] in
            // A name that will not resolve in two seconds is not going to be
            // the machine the user is waiting for. Drop the probe; the row
            // stays visible with its key, ready to pair the moment it answers.
            try? await Task.sleep(for: .seconds(2))
            guard let self, !timedOut, self.connections[key] != nil else { return }
            timedOut = true
            self.connections.removeValue(forKey: key)?.cancel()
        }
        return nil
    }

    /// A readable reason the browse is stuck, or nil while it is fine.
    nonisolated private static func errorMessage(for state: NWBrowser.State) -> String? {
        switch state {
        case .failed(let error), .waiting(let error):
            let text = error.localizedDescription
            let lower = text.lowercased()
            if lower.contains("denied") || lower.contains("permission") || lower.contains("local network") {
                return "Local network access is blocked. Allow tokenstat in System Settings → Privacy & Security → Local Network, then reopen this screen."
            }
            if lower.contains("dns") || lower.contains("service") {
                return "The system could not browse for tokenstat machines on this network (\(text))."
            }
            return nil
        default:
            return nil
        }
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
    private(set) var browseError: String?
    var changed: (([DiscoveredDaemon]) -> Void)?
    var errorChanged: ((String?) -> Void)?

    func start() {}
    func stop() {}
}
#endif
