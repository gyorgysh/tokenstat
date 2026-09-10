// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// A legible platform badge; initials identify distributions without invented vendor logos.
struct SSHHostPlatformMark: View {
    let label: String?
    private var initials: String? {
        guard let label else { return nil }
        let name = label.lowercased()
        if name.contains("ubuntu") { return "U" }
        if name.contains("debian") { return "D" }
        if name.contains("fedora") { return "F" }
        if name.contains("alpine") { return "A" }
        if name.contains("arch") { return "Ar" }
        if name.contains("linux") { return "L" }
        return String(label.prefix(2)).uppercased()
    }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9).fill(Theme.accentSoft)
            if let initials {
                Text(initials).font(Theme.font(13, weight: .semibold))
            } else {
                Image(systemName: "server.rack").font(Theme.font(16))
            }
        }
        .foregroundStyle(Theme.accent)
        .frame(width: 34, height: 34)
        .accessibilityLabel(label ?? "Server; platform not checked")
        .help(label ?? "Platform appears after a server check")
    }
}
