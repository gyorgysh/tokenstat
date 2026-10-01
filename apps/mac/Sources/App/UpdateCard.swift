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
        } else if update.failure != nil && !update.failureDismissed {
            failedCard
        } else if update.checkNotice == AppUpdateModel.upToDateMessage {
            status(title: L10n.text("apple.updatecard.up_to_date.ce29b7f8"), subtitle: L10n.text("apple.updatecard.v_0.9ad023b9", "\(update.current)"),
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
        case .checking: return L10n.text("apple.updatecard.checking_for_updates.53b276ad")
        case .downloading: return L10n.text("apple.updatecard.downloading_update.01436823")
        default: return L10n.text("apple.updatecard.preparing_update.e2562d8c")
        }
    }

    private var progressDetail: String {
        switch update.stage {
        case .checking: return L10n.text("apple.updatecard.looking_for_the_latest_release.c835769a")
        case .downloading: return L10n.text("apple.updatecard.fetching_v_0_securely.1e4bf8c3", "\(update.latest)")
        default: return L10n.text("apple.updatecard.verifying_and_installing_v_0.c39d2002", "\(update.latest)")
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
            Text(L10n.text("apple.updatecard.you_can_keep_working.7f151a6e")).font(Theme.caption2).foregroundStyle(.secondary)
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
            Label(L10n.text("apple.updatecard.ready_to_restart.6a6c90ba"), systemImage: "checkmark.circle.fill")
                .font(Theme.callout.weight(.medium)).foregroundStyle(Theme.accent)
            Text(L10n.text("apple.updatecard.v_0_is_installed_restart_when_you_re_ready.e317415f", "\(update.latest)"))
                .font(Theme.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.s) {
                Button(L10n.text("apple.updatecard.restart.6b983a81"), .refresh) { update.relaunch() }
                    .buttonStyle(AccentButtonStyle(small: true))
                    .help(L10n.text("apple.updatecard.restarts_tokenstat_to_finish_the_update_sa.2c3392cc"))
                Button(L10n.text("common.skip"), .dismiss) { update.skipThisVersion() }
                    .buttonStyle(SecondaryButtonStyle(small: true))
                    .help(L10n.text("apple.updatecard.stops_this_card_until_you_check_for_update.4e19dc95"))
            }
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
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(Theme.fixed(15))
                    .foregroundStyle(Theme.warning)
                VStack(alignment: .leading, spacing: 1) {
                    Text(update.retryAfter != nil ? L10n.text("apple.updatecard.update_checks_paused.fc82663e") : (update.isAvailable ? L10n.text("apple.updatecard.update_didn_t_finish.d1b16ee1") : L10n.text("apple.updatecard.couldn_t_check_for_updates.b6108d62")))
                        .font(Theme.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(update.failure ?? L10n.text("apple.updatecard.please_try_again.eea4fb33"))
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .help(update.failure ?? "")
                }
                Spacer(minLength: Theme.Space.s)
                NoticeDismissButton { update.dismissFailure() }
            }
            HStack(spacing: Theme.Space.s) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Button(L10n.text("common.retry"), .refresh) {
                        Task { await update.retry() }
                    }
                    .buttonStyle(AccentButtonStyle(small: true))
                    .disabled(update.retryAfter.map { $0 > context.date } ?? false)
                    .help(L10n.text("apple.updatecard.check_again_when_github_s_waiting_period_h.a5314d1b"))
                }

                if update.isAvailable {
                Button(L10n.text("apple.updatecard.manual.b0b9fe24"), .download) {
                    if let url = update.downloadURL { openURL(url) }
                }
                .buttonStyle(SecondaryButtonStyle(small: true))
                .disabled(update.downloadURL == nil)
                .help(L10n.text("apple.updatecard.open_the_download_page_and_install_by_hand.4dd377fb"))
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
