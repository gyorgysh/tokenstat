// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)

import SwiftUI

/// A device is waiting on an answer, in the corner where the app already says
/// what is going on.
///
/// The same slot and the same language as the update, sync and offline cards:
/// above the account row, in the sidebar, in the app's own colours. It was a
/// toast in the opposite corner first, which was wrong twice over. A toast
/// takes itself away after a few seconds, and somebody who looked up to read it
/// had already missed the only chance to answer. And a question about who may
/// open your work is not a passing notice, it is a thing that stays until it is
/// dealt with.
struct DeviceAccessCard: View {
    var model: DeviceAccessRequests

    var body: some View {
        if let request = model.oldest {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: request.kind == .screen ? "eye" : "folder")
                    .font(Theme.fixed(15))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.pending.count > 1
                        ? "\(model.pending.count) permission requests"
                        : "Permission request")
                        .font(Theme.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(request.displayName)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Theme.Space.s)
                Button("View", .preview) { model.askAboutOldest() }
                    .buttonStyle(AccentButtonStyle(small: true))
                    .help("Answer this request")
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1)
            )
            .padding(.horizontal, Theme.Space.s)
            .padding(.bottom, Theme.Space.s)
        }
    }
}

#endif
