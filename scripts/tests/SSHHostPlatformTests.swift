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
        // Editing the endpoint invalidates old metadata.
        host.port = 2222
        precondition(cache.label(for: host) == nil)
        // A changed trusted identity invalidates a label confirmed with keys…
        host = SSHHost(); host.hostKeys = ["changed"]
        precondition(cache.label(for: host) == nil)
        // …but a check that ran before the first trust carries no keys and
        // must survive trusting: the setup wizard probes before it trusts.
        host.hostKeys = []
        cache.remember(check, for: host)
        precondition(cache.label(for: host) == "Ubuntu 24.04")
        host.hostKeys = ["freshly-trusted"]
        precondition(cache.label(for: host) == "Ubuntu 24.04")
        for n in 1...128 {
            var other = SSHHost(); other.id = "host-\(n)"
            cache.remember(check, for: other, now: now.addingTimeInterval(Double(n)))
        }
        precondition(cache.label(for: SSHHost()) == nil, "oldest metadata must be evicted")
        // Distro marks: legit bundled marks resolve, everything else is nil
        // so the row falls back to the neutral server glyph. Never initials.
        precondition(distroBrandAsset("Ubuntu 24.04") == "brand_distro_ubuntu")
        precondition(distroBrandAsset("Debian GNU/Linux 12") == "brand_distro_debian")
        precondition(distroBrandAsset("Arch Linux") == "brand_distro_archlinux")
        precondition(distroBrandAsset("Alpine Linux v3.20") == "brand_distro_alpinelinux")
        precondition(distroBrandAsset("openSUSE Leap 15.6") == "brand_distro_opensuse")
        precondition(distroBrandAsset("Linux") == "brand_distro_linux")
        precondition(distroBrandAsset("Some New Distro 99") == nil)
        precondition(distroBrandAsset(nil) == nil)
        print("SSH platform cache: persistence, identity changes, trust, expiry, and capacity passed")
    }
}
