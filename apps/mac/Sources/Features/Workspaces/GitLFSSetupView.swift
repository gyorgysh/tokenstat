// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// The setup action is the person's consent to install LFS on the host and
/// enable it for this repository. It never submits a pull or push.
struct GitLFSSetupView: View {
    let status: GitLFSStatus
    let working: Bool
    let setup: () async -> Void
    let check: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Label(L10n.text("apple.gitlfs.title"), systemImage: "externaldrive")
                .font(Theme.callout.weight(.semibold))
            Text(message)
                .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                .fixedSize(horizontal: false, vertical: true)
            if !status.ready {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Space.s) { actions }
                    VStack(alignment: .leading, spacing: Theme.Space.s) { actions }
                }
                .disabled(working)
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private var actions: some View {
        if status.installed || status.canInstall {
            Button(status.installed ? L10n.text("apple.gitlfs.enable") : L10n.text("apple.gitlfs.install"), .download) {
                Task { await setup() }
            }
            .buttonStyle(SecondaryButtonStyle(comfortable: true))
        } else {
            Link(L10n.text("apple.gitlfs.guide"), destination: URL(string: "https://git-lfs.com")!)
        }
        Button(L10n.text("apple.gitlfs.check"), .refresh) {
            Task { await check() }
        }
        .buttonStyle(SecondaryButtonStyle(comfortable: true))
    }

    private var message: String {
        if status.ready { return L10n.text("apple.gitlfs.ready") }
        if status.installed { return L10n.text("apple.gitlfs.enable_help") }
        if status.canInstall { return L10n.text("apple.gitlfs.install_help") }
        return L10n.text("apple.gitlfs.manual_help")
    }
}
