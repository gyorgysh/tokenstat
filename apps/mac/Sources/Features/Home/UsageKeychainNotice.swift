// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if os(macOS)
import SwiftUI

struct UsageKeychainNotice: View {
    var openSettings: () -> Void
    @AppStorage("usage.keychain.notice.dismissedSources") private var dismissed = ""
    @Environment(\.scenePhase) private var scenePhase
    @State private var waiting = false
    @State private var result: String?

    private var affected: [String] {
        PlanLimitsStore.shared.visible.filter {
            $0.note?.localizedCaseInsensitiveContains("keychain") == true
        }.map(\.source)
    }

    private var offered: String? {
        UsageKeychainNoticePolicy(saved: dismissed).offer(affected: affected)
    }

    var body: some View {
        if scenePhase == .active, waiting || result != nil || offered != nil {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Label(L10n.text("apple.usage.keychain.notice.title"), systemImage: ActionIcon.permissions.symbol)
                    .font(Theme.callout.weight(.medium))
                Text(result ?? (waiting
                     ? L10n.text("apple.usage.keychain.waiting")
                     : L10n.text("apple.usage.keychain.notice.detail", harnessName(offered ?? ""))))
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Theme.Space.m) {
                    if let source = offered, result == nil, !waiting {
                        Button(L10n.text("apple.usage.keychain.allow"), .permissions) {
                            authorize(source)
                        }
                        .buttonStyle(AccentButtonStyle(small: true))
                        Button(L10n.text("apple.usage.keychain.notice.later"), .dismiss) {
                            dismissOffer()
                            result = L10n.text("apple.usage.keychain.notice.settings_hint")
                        }
                    } else if !waiting {
                        Button(L10n.text("common.settings"), .settings) {
                            result = nil
                            openSettings()
                        }
                        Button(L10n.text("common.close"), .dismiss) { result = nil }
                    }
                }
                .font(Theme.caption)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: 340, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border, lineWidth: 1))
            .shadow(color: Theme.shadow(0.2), radius: 14, y: 6)
            .padding(Theme.Space.m)
            .task(id: result) {
                guard result != nil else { return }
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                result = nil
            }
        }
    }

    private func dismissOffer() {
        var policy = UsageKeychainNoticePolicy(saved: dismissed)
        policy.dismiss(affected: affected)
        dismissed = policy.saved
    }

    private func authorize(_ source: String) {
        dismissOffer()
        waiting = true
        Task {
            defer { waiting = false }
            do {
                try await Bridge.authorizeUsageKeychain(source: source)
                if PlanLimitsStore.shared.isRefreshing {
                    try? await PlanLimitsStore.shared.refresh()
                }
                try await PlanLimitsStore.shared.refresh(force: true)
                result = L10n.text("apple.usage.keychain.notice.allowed")
            } catch {
                result = error.localizedDescription + " " + L10n.text("apple.usage.keychain.notice.settings_hint")
            }
        }
    }
}
#endif
