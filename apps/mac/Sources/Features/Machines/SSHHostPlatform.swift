// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import Observation

/// Confirmed server metadata, local to this device. Never infer an OS from an address.
@MainActor @Observable
final class SSHHostPlatformCache {
    static let shared = SSHHostPlatformCache()
    private static let storageKey = "ssh.confirmedPlatforms.v1"
    struct Entry: Codable {
        let label: String
        /// The endpoint this label was confirmed for, so editing the address
        /// invalidates old metadata instead of showing Ubuntu for a new box.
        let hostname: String
        let port: Int
        /// The trusted identity at confirmation time. Empty where the check
        /// ran before the fingerprint was trusted (the setup wizard probes
        /// first), so a later trust must not orphan the label.
        let hostKeys: [String]
        let saved: Date
    }
    private var entries: [String: Entry]
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Current shape is keyed by host.id and kept as-is. Older hash-keyed
        // v1 entries are unreachable via host.id but harmless: they expire
        // by age and the 128-cap still bounds the store.
        if let data = defaults.data(forKey: Self.storageKey),
           let migrated = try? JSONDecoder().decode([String: Entry].self, from: data),
           !migrated.isEmpty
        {
            entries = migrated
        } else {
            entries = [:]
        }
    }
    func label(for host: SSHHost, now: Date = Date()) -> String? {
        guard let entry = entries[host.id],
              now.timeIntervalSince(entry.saved) < 90 * 86400
        else { return nil }
        // An edited endpoint invalidates old metadata.
        if !entry.hostname.isEmpty,
           (entry.hostname != host.hostname.lowercased() || entry.port != host.port)
        { return nil }
        // A changed trusted identity invalidates it too, but only where the
        // label was confirmed against a known identity: a check that ran
        // before the first trust carries no keys and must survive it.
        // Upgrade the provisional entry on first trust (TOFU, like SSH
        // itself: the pre-trust probe may have seen an attacker, and only
        // a fresh post-trust probe could prove otherwise). Binding the
        // label to the first trusted keys means a later identity change
        // invalidates it instead of hiding behind the pre-trust label.
        if entry.hostKeys.isEmpty, !host.hostKeys.isEmpty {
            entries[host.id] = Entry(label: entry.label, hostname: entry.hostname, port: entry.port, hostKeys: host.hostKeys.sorted(), saved: entry.saved)
            if let data = try? JSONEncoder().encode(entries) {
                defaults.set(data, forKey: Self.storageKey)
            }
            return entry.label
        }
        if !entry.hostKeys.isEmpty, entry.hostKeys.sorted() != host.hostKeys.sorted() { return nil }
        return entry.label
    }
    func remember(_ check: ServerCheck, for host: SSHHost, now: Date = Date()) {
        let label = (check.distro?.isEmpty == false ? check.distro : check.os) ?? ""
        let clean = String(label.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ").prefix(80))
        guard !clean.isEmpty else { return }
        entries[host.id] = Entry(
            label: clean,
            hostname: host.hostname.lowercased(),
            port: host.port,
            hostKeys: host.hostKeys.sorted(),
            saved: now
        )
        if entries.count > 128 {
            entries = Dictionary(uniqueKeysWithValues: entries.sorted { $0.value.saved > $1.value.saved }.prefix(128).map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
    /// Forget what was confirmed for a host, after its endpoint or identity
    /// was edited into something the label no longer describes.
    func forget(hostID: String) {
        entries.removeValue(forKey: hostID)
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}

/// Asset name for a Linux distribution's mark, or nil when none is bundled.
///
/// Vendor marks, not ours: see TRADEMARK.md. The SVGs are Simple Icons
/// renditions (CC0) of each distribution's own logo, used only to identify
/// the OS the host itself reported in `/etc/os-release`. A distribution with
/// no bundled mark falls back to the generic Linux mark, then to a neutral
/// server glyph: never an invented initial, and never another distro's logo.
func distroBrandAsset(_ label: String?) -> String? {
    guard let id = distroBrandID(label) else { return nil }
    return "brand_distro_\(id)"
}

/// Simple Icons slug for the distribution named in a platform label, or nil
/// when the label names nothing this build ships a mark for.
///
/// Matches on token boundaries (os-release ID or word split), not bare
/// substrings: `arch` inside another word must not claim Arch Linux.
func distroBrandID(_ label: String?) -> String? {
    guard let label, !label.isEmpty else { return nil }
    let name = label.lowercased()
    let tokens = Set(name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    if name.contains("ubuntu") { return "ubuntu" }
    if name.contains("debian") { return "debian" }
    if name.contains("fedora") { return "fedora" }
    if name.contains("alpine") { return "alpinelinux" }
    if tokens.contains("arch") || name.contains("arch linux") { return "archlinux" }
    if name.contains("nixos") || name.contains("nix os") { return "nixos" }
    if tokens.contains("mint") || name.contains("linux mint") { return "linuxmint" }
    if name.contains("gentoo") { return "gentoo" }
    if name.contains("rocky") { return "rockylinux" }
    if tokens.contains("alma") || name.contains("almalinux") { return "almalinux" }
    if name.contains("centos") { return "centos" }
    if name.contains("red hat") || tokens.contains("rhel") { return "redhat" }
    if name.contains("opensuse") { return "opensuse" }
    if tokens.contains("suse") || tokens.contains("sles") { return "suse" }
    if tokens.contains("linux") { return "linux" }
    return nil
}
