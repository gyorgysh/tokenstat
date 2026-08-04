// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// A new version exists, and what to do about it.
///
/// The app does not replace itself. It downloads a signed, notarized disk image
/// and lets the user drag the app into Applications, which is the update every
/// Mac user already knows how to perform and the one that needs no privileged
/// helper, no background daemon and no code that rewrites the running
/// application while it runs.
///
/// The honest trade is one manual step in exchange for an update path with
/// nothing in it that could go wrong quietly. See `docs/desktop-app.md`.
struct UpdateSheet: View {
    var update: AppUpdateModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("tokenstat \(update.latest) is out")
                        .font(.system(size: 15, weight: .semibold))
                    if !update.current.isEmpty {
                        Text("You are running \(update.current).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Text(update.hasDiskImage
                ? """
                  The download is a disk image. Open it and drag tokenstat into \
                  Applications, replacing the copy that is there. Quit this one \
                  first, or macOS will not let the file be replaced.
                  """
                : """
                  This release has no Mac download yet. The release page has \
                  what there is.
                  """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Skip this version") {
                    update.skipThisVersion()
                    dismiss()
                }
                Spacer()
                Button("Later", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    if let url = update.downloadURL { openURL(url) }
                    dismiss()
                } label: {
                    Label(update.hasDiskImage ? "Download" : "Open release page",
                          systemImage: update.hasDiskImage ? "arrow.down" : "safari")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(update.downloadURL == nil)
            }

            Text("""
            Downloads come from this project's GitHub releases and are signed \
            and notarized by pueev OÜ. Nothing about your archive is sent to \
            check for one.
            """)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.l)
        .frame(width: 460)
        .background(Theme.panel)
    }
}
