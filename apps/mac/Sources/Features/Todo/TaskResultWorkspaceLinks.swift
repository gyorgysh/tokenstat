// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// Review Changes and History for the folder that produced a task result.
///
/// Whole-surface rows, the same shape as a folder's own sections, so the
/// destination is the folder rather than a second run action.
struct TaskResultWorkspaceLinks: View {
    let route: TaskResultRoute
    var onSelect: (TaskResultWorkspaceSurface) -> Void
    /// When the surrounding chrome already names the folder, skip the extra heading.
    var showsContext: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if showsContext {
                VStack(alignment: .leading, spacing: 2) {
                    Text("This folder")
                        .font(Theme.callout.weight(.semibold))
                    Text(contextLine)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.controlGlyph)
                        .lineLimit(2)
                }
            }
            if let message = route.reviewAvailability.message(hostName: route.hostName) {
                Text(message)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.controlGlyph)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Theme.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                            .strokeBorder(Theme.border)
                    )
            } else {
                ForEach(TaskResultWorkspaceSurface.allCases) { surface in
                    Button {
                        onSelect(surface)
                    } label: {
                        TaskResultWorkspaceRow(
                            surface: surface,
                            caption: route.caption(for: surface),
                            count: surface == .changes ? route.changeCount : nil
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(surface == .changes
                        ? "Opens uncommitted files for this folder"
                        : "Opens commits for this folder")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var contextLine: String {
        let host = route.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.isEmpty { return route.folderLabel }
        return "\(route.folderLabel) · \(host)"
    }
}

/// One destination in a task result. The glyph is the folder section, not a
/// generic preview eye, so Changes and History cannot be mistaken for View run.
struct TaskResultWorkspaceRow: View {
    let surface: TaskResultWorkspaceSurface
    var caption: String
    var count: Int?

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: surface.symbol)
                .font(Theme.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(surface.title)
                    .font(Theme.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text(caption)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.controlGlyph)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if let count, count > 0 {
                Text("\(count)")
                    .font(Theme.callout.monospacedDigit())
                    .foregroundStyle(Theme.controlGlyph)
            }
            Image(systemName: "chevron.right")
                .font(Theme.caption.weight(.semibold))
                .foregroundStyle(Theme.controlGlyph)
                .accessibilityHidden(true)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Theme.border)
        )
        .contentShape(.rect)
    }
}
