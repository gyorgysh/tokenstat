// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// Sidebar activity for real updater stages. Download bytes are not exposed by
/// the host, so progress is indeterminate rather than an invented percentage.
struct UpdateCard: View {
    var update: AppUpdateModel

    @Environment(\.openURL) private var openURL
    @State private var showCheckingProgress = false

    var body: some View {
        Group {
        if update.isChecking {
            if update.stage != .checking || showCheckingProgress {
                progressCard
            }
        } else if update.isReady {
            readyCard
        } else if update.failure != nil {
            failedCard
        } else if update.checkNotice == AppUpdateModel.upToDateMessage {
            status(title: "Up to date", subtitle: "v\(update.current)",
                   symbol: "checkmark.seal.fill", tint: Theme.accent)
        }
        }
        .task(id: update.stage == .checking) {
            showCheckingProgress = false
            guard update.stage == .checking else { return }
            do {
                try await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, update.stage == .checking else { return }
                showCheckingProgress = true
            } catch { }
        }
    }

    private var progressTitle: String {
        switch update.stage {
        case .checking: return "Checking for updates"
        case .downloading: return "Downloading update"
        default: return "Preparing update"
        }
    }

    private var progressDetail: String {
        switch update.stage {
        case .checking: return "Looking for the latest release…"
        case .downloading: return "Fetching v\(update.latest) securely…"
        default: return "Verifying and installing v\(update.latest)…"
        }
    }

    private var progressStep: Int {
        switch update.stage {
        case .checking: return 0
        case .downloading: return 1
        default: return 2
        }
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                ProgressView().controlSize(.small).tint(Theme.accent)
                Text(progressTitle).font(Theme.callout.weight(.medium))
            }
            Text(progressDetail).font(Theme.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                ForEach(0..<3) { step in
                    Capsule().fill(step <= progressStep ? Theme.accent : Theme.accent.opacity(0.15))
                        .frame(height: 3)
                }
            }.accessibilityHidden(true)
            Text("You can keep working.").font(Theme.caption2).foregroundStyle(.secondary)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.accent.opacity(0.35)))
        .padding(.horizontal, Theme.Space.s)
        .padding(.bottom, Theme.Space.s)
        .accessibilityElement(children: .combine)
    }

    private var readyCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Label("Ready to restart", systemImage: "checkmark.circle.fill")
                .font(Theme.callout.weight(.medium)).foregroundStyle(Theme.accent)
            Text("v\(update.latest) is installed. Restart when you’re ready to use it.")
                .font(Theme.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Restart now", .refresh) { update.relaunch() }
                .buttonStyle(AccentButtonStyle(small: true))
                .help("Restarts tokenstat to finish the update. Save your work first.")
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.accent.opacity(0.35)))
        .padding(.horizontal, Theme.Space.s)
        .padding(.bottom, Theme.Space.s)
    }

    /// A non-interactive confirmation row, for states that have no action.
    private func status(
        title: String,
        subtitle: String,
        symbol: String,
        tint: Color,
        spinner: Bool = false
    ) -> some View {
        HStack(spacing: Theme.Space.s) {
            Group {
                if spinner {
                    ProgressView()
                        .controlSize(.small)
                        .tint(tint)
                } else {
                    Image(systemName: symbol)
                        .font(Theme.fixed(15))
                }
            }
            .foregroundStyle(tint)
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.callout.weight(.medium))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Theme.Space.s)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
        )
        .padding(.horizontal, Theme.Space.s)
        .padding(.bottom, Theme.Space.s)
    }

    /// The automatic install failed: retry it here, or go get it by hand.
    ///
    /// Two buttons rather than one "Update by hand" row, because a person who
    /// pressed nothing and still got an update that failed deserves a way to
    /// try the automatic path again without leaving the app.
    private var failedCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(Theme.fixed(15))
                    .foregroundStyle(Theme.warning)
                VStack(alignment: .leading, spacing: 1) {
                    Text(update.isAvailable ? "Update didn’t finish" : "Couldn’t check for updates")
                        .font(Theme.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(update.failure ?? "Please try again.")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .help(update.failure ?? "")
                }
                Spacer(minLength: Theme.Space.s)
            }
            HStack(spacing: Theme.Space.s) {
                Button("Retry", .refresh) {
                    Task { await update.retry() }
                }
                .buttonStyle(AccentButtonStyle(small: true))
                .help("Try the automatic install again")

                if update.isAvailable {
                Button("Manual", .download) {
                    if let url = update.downloadURL { openURL(url) }
                }
                .buttonStyle(SecondaryButtonStyle(small: true))
                .disabled(update.downloadURL == nil)
                .help("Open the download page and install by hand")
                }
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(Theme.warning.opacity(0.35), lineWidth: 1)
        )
        .padding(.horizontal, Theme.Space.s)
        .padding(.bottom, Theme.Space.s)
    }

}
