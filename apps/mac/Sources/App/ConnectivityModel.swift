// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

import Foundation
import Network
import Observation

extension Notification.Name {
    /// The network came back after an offline stretch. Anything that was
    /// waiting on the internet refreshes now instead of on the next retry
    /// tick.
    static let connectivityRestored = Notification.Name("tokenstat.connectivityRestored")
    /// The network state changed in either direction.
    static let connectivityChanged = Notification.Name("tokenstat.connectivityChanged")
}

/// Whether this machine can reach the internet, and the retry that watches
/// for it to come back.
///
/// Two sources of truth, deliberately:
/// - `NWPathMonitor` notices a path change instantly (Wi-Fi off, Ethernet
///   unplugged, the machine waking), so the moment the path is back the app
///   hears about it without polling.
/// - A real egress probe decides "online": a satisfied path is not the same
///   thing as a working internet connection (a captive portal, a router with
///   no upstream, DNS that answers nothing). While offline the probe reruns
///   every 30 seconds, so a connection that comes back without the path ever
///   changing is still caught on the next tick.
///
/// The probe asks `captive.apple.com/hotspot-detect.html`, which macOS itself
/// uses for this exact question: it returns the literal string "Success" when
/// the internet is reachable and gets intercepted when it is not.
@MainActor
@Observable
final class ConnectivityModel {
    enum Status: Equatable {
        case unknown
        case online
        case offline
    }

    /// Nil until the first probe answers, so the UI can tell "not checked
    /// yet" from "definitely offline".
    private(set) var status: Status = .unknown

    /// When the current offline stretch began. Nil while online or unknown.
    private(set) var offlineSince: Date?

    /// How long an offline stretch waits between egress probes.
    static let retryInterval: Duration = .seconds(30)

    var isOnline: Bool { status == .online }
    var isOffline: Bool { status == .offline }

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ai.tokenstat.connectivity")
    private var probeTask: Task<Void, Never>?
    private var started = false
    private var pathSatisfied = false

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.pathDidChange(satisfied: path.status == .satisfied)
            }
        }
        monitor.start(queue: queue)
        // The monitor's first path update lands asynchronously. Probe once
        // now so a launch without internet shows the offline card right away.
        scheduleProbe()
    }

    func stop() {
        monitor.cancel()
        probeTask?.cancel()
        started = false
    }

    /// The path changed. A satisfied path does not prove egress, so confirm
    /// with a probe before announcing online. An unsatisfied path is
    /// definitive.
    private func pathDidChange(satisfied: Bool) {
        pathSatisfied = satisfied
        if satisfied {
            scheduleProbe()
        } else {
            probeTask?.cancel()
            setOffline()
        }
    }

    private func setOffline() {
        let changed = !isOffline
        status = .offline
        offlineSince = offlineSince ?? Date()
        if changed {
            NotificationCenter.default.post(name: .connectivityChanged, object: self)
        }
    }

    private func setOnline() {
        let wasOffline = isOffline
        status = .online
        offlineSince = nil
        probeTask?.cancel()
        NotificationCenter.default.post(name: .connectivityChanged, object: self)
        if wasOffline {
            // The connectionBack hook: refresh immediately, not on the next
            // 30-second tick.
            NotificationCenter.default.post(name: .connectivityRestored, object: self)
        }
    }

    /// Probe now, then keep probing every `retryInterval` until online. One
    /// task per trigger: starting a probe cancels whatever retry is running,
    /// so a path change restarts the timer instead of stacking them.
    private func scheduleProbe() {
        probeTask?.cancel()
        probeTask = Task { [weak self] in
            while !Task.isCancelled {
                let ok = await Self.probe()
                guard !Task.isCancelled else { return }
                guard let self = self else { return }
                if ok {
                    self.setOnline()
                    return
                }
                if !self.isOffline {
                    self.setOffline()
                }
                try? await Task.sleep(for: Self.retryInterval)
            }
        }
    }

    /// One egress check. Anything that is not the success page counts as
    /// offline, so a captive portal is not mistaken for the internet.
    private static func probe() async -> Bool {
        var request = URLRequest(url: URL(string: "https://captive.apple.com/hotspot-detect.html")!)
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let body = String(data: data, encoding: .utf8)
        else { return false }
        return body.contains("Success")
    }
}
