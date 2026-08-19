// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI

/// One launcher tile on the phone: mark, name, the same panel the Mac uses.
///
/// No path badge. That control is hover and a 300pt bubble.
struct ClientLaunchTile: View {
    let profile: RemoteLaunchProfile
    var isLaunching: Bool = false
    var isMuted: Bool = false
    var isBusy: Bool = false
    var caption: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Theme.Space.s) {
                if isLaunching || isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .frame(height: 34)
                } else {
                    mark
                }
                Text(caption ?? profile.name)
                    .font(ClientType.caption.weight(.medium))
                    .foregroundStyle(isMuted ? .secondary : .primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Space.m)
            .background(
                isLaunching
                    ? Theme.accent.opacity(0.12)
                    : (isMuted ? Theme.panel.opacity(0.4) : Theme.panel),
                in: RoundedRectangle(cornerRadius: Theme.cardRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(
                        isLaunching ? Theme.accent : Theme.border.opacity(isMuted ? 0.5 : 1),
                        style: StrokeStyle(lineWidth: 1, dash: isMuted ? [4, 3] : [])
                    )
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isLaunching || isBusy)
        .opacity(isLaunching ? 1 : (isBusy ? 0.5 : 1))
        .accessibilityLabel(caption ?? profile.name)
    }

    @ViewBuilder
    private var mark: some View {
        if let harness = profile.harnessId, harnessBrandAsset(harness) != nil {
            HarnessMark(id: harness, size: 34)
                .opacity(isMuted ? 0.45 : 1)
                .saturation(isMuted ? 0.3 : 1)
        } else {
            Image(systemName: profile.symbol ?? "terminal")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(isMuted ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Theme.accent))
                .frame(height: 34)
        }
    }
}

/// The + tile that opens the rest of the catalog.
struct ClientMoreTile: View {
    let showing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Theme.Space.s) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(height: 34)
                Text(showing ? "Hide" : "More")
                    .font(ClientType.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Space.m)
            .background(Theme.panel.opacity(0.4), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(Theme.border.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showing ? "Hide extra tools" : "Show more tools")
    }
}

/// A launch tile before the host has said which tiles it has.
///
/// Same box, same corner radius, same height as the real one, so the grid is
/// already the right shape when the catalog lands and the tiles fill in where
/// the placeholders were rather than growing the row under a thumb.
struct ClientLaunchTilePlaceholder: View {
    var phase: Double = 0

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            Skeleton.Bar(width: 34, height: 34, phase: phase)
            Skeleton.Bar(width: 52, height: 10, phase: phase + 0.05)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.m)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .accessibilityHidden(true)
    }
}

#endif
