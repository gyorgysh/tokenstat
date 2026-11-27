// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)

import SwiftUI

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
                        ? L10n.text("apple.deviceaccesscard.0_permission_requests.5d8938e4", "\(model.pending.count)")
                        : L10n.text("apple.deviceaccesscard.permission_request.93dfd0b5"))
                        .font(Theme.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(request.displayName)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Theme.Space.s)
                Button(L10n.text("apple.deviceaccesscard.view.dcc839a4"), .preview) { model.askAboutOldest() }
                    .buttonStyle(AccentButtonStyle(small: true))
                    .help(L10n.text("apple.deviceaccesscard.answer_this_request.9f9a1d73"))
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
