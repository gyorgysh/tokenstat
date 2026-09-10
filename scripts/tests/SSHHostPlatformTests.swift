// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with SSHHostPlatform.swift; no network or system preferences are used.
import Foundation
struct SSHHost { var id = "one"; var hostname = "host"; var port = 22; var hostKeys = ["trusted"] }
struct ServerCheck { var distro: String?; var os: String? }
@main enum SSHHostPlatformTests {
    @MainActor static func main() {
        let suite = "SSHHostPlatformTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = SSHHostPlatformCache(defaults: defaults)
        var host = SSHHost()
        let now = Date()
        let check = ServerCheck(distro: "Ubuntu\n24.04", os: "Linux")
        precondition(cache.label(for: host) == nil)
        cache.remember(check, for: host, now: now)
        precondition(cache.label(for: host, now: now) == "Ubuntu 24.04")
        precondition(SSHHostPlatformCache(defaults: defaults).label(for: host) == "Ubuntu 24.04")
        precondition(cache.label(for: host, now: now.addingTimeInterval(91 * 86400)) == nil)
        host.port = 2222
        precondition(cache.label(for: host) == nil)
        host = SSHHost(); host.hostKeys = ["changed"]
        precondition(cache.label(for: host) == nil)
        host.hostKeys = []
        cache.remember(check, for: host)
        precondition(cache.label(for: host) == nil)
        for n in 1...128 {
            var other = SSHHost(); other.id = "host-\(n)"
            cache.remember(check, for: other, now: now.addingTimeInterval(Double(n)))
        }
        precondition(cache.label(for: SSHHost()) == nil, "oldest metadata must be evicted")
        print("SSH platform cache: persistence, identity changes, trust, expiry, and capacity passed")
    }
}
