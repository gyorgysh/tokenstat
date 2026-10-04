// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// Pull beside Push, on the desktop and the phone. Drawing it reads nothing
/// remote: the sheet it opens is what fetches, because a person pressed it.
struct GitPullControl: View {
    let target: GitCommitTarget
    let folderName: String
    let hostName: String
    /// Commits the folder's last status said the upstream has. Only as fresh
    /// as the last fetch, which is why the sheet fetches again.
    let incoming: UInt32
    var onPulled: () async -> Void
    @State private var supported = false
    @State private var presenting = false

    var body: some View {
        Group {
            if supported {
                Button(incoming > 0 ? L10n.text("apple.gitpull.pull_count", "\(incoming)") : L10n.text("apple.gitpull.pull"), .download) {
                    presenting = true
                }
                .buttonStyle(SecondaryButtonStyle(comfortable: true))
                .help(L10n.text("apple.gitpull.help"))
            }
        }
        .task(id: target) {
            supported = await target.supportsReviewedPull()
        }
        .sheet(isPresented: $presenting) {
            GitPullSheet(service: target, folderName: folderName, hostName: hostName, onPulled: onPulled)
        }
    }
}

struct GitPullSheet: View {
    let service: GitPullService
    let folderName: String
    let hostName: String
    var onPulled: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var review: GitPullReview?
    @State private var outcome: GitPullOutcome?
    @State private var error: String?
    @State private var working = false

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ThemedSheet(title: L10n.text("apple.gitpull.title"), subtitle: [folderName, hostName].filter { !$0.isEmpty }.joined(separator: " · "),
                    icon: .download, onClose: { dismiss() }) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    if let review {
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            Text(review.branchName).font(Theme.title3.weight(.semibold))
                            Text(L10n.text("apple.gitpull.from", review.source))
                                .font(Theme.callout).foregroundStyle(Theme.controlGlyph)
                        }
                        if let outcome {
                            Text(outcome.message)
                                .font(Theme.callout)
                                .foregroundStyle(outcome.ok ? Theme.accent : Theme.danger)
                                .textSelection(.enabled)
                        } else {
                            Text(summary(review))
                                .font(Theme.callout)
                                .foregroundStyle(review.state == .diverged || review.state == .missing ? Theme.warning : .primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let error {
                        Text(error)
                            .font(Theme.callout)
                            .foregroundStyle(Theme.danger)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if working {
                        ProgressView(outcome == nil && review == nil ? L10n.text("apple.gitpull.checking") : L10n.text("apple.gitpull.pulling"))
                            .font(Theme.callout)
                    }
                    Text(L10n.text("apple.gitpull.help"))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.controlGlyph)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } actions: {
            if outcome?.ok == true || review?.state == .upToDate {
                Button(L10n.text("common.done"), .done) { dismiss() }
                    .buttonStyle(AccentButtonStyle(comfortable: true))
            } else if let review, review.state == .fastForward, outcome == nil {
                Button(review.incoming == 1 ? L10n.text("apple.gitpull.pull_commits.one", "1")
                       : L10n.text("apple.gitpull.pull_commits.other", "\(review.incoming)"), .download) {
                    Task { await pull(review) }
                }
                .buttonStyle(AccentButtonStyle(comfortable: true))
                .disabled(working)
            } else {
                Button(L10n.text("apple.gitpull.check_again"), .refresh) { Task { await check() } }
                    .buttonStyle(AccentButtonStyle(comfortable: true))
                    .disabled(working)
            }
        }
        .modalFrame(width: 520, height: 380)
        #if !os(macOS)
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.height(340), .large])
        #endif
        .interactiveDismissDisabled(working)
        .task { await check() }
    }

    private func summary(_ review: GitPullReview) -> String {
        switch review.state {
        case .upToDate:
            return L10n.text("apple.gitpull.up_to_date")
        case .ahead:
            return L10n.text("apple.gitpull.ahead")
        case .fastForward:
            return review.incoming == 1 ? L10n.text("apple.gitpull.incoming.one", "1")
                : L10n.text("apple.gitpull.incoming.other", "\(review.incoming)")
        case .diverged:
            return L10n.text("apple.gitpull.diverged", "\(review.incoming)", "\(review.outgoing)")
        case .missing:
            return L10n.text("apple.gitpull.missing")
        }
    }

    private func check() async {
        working = true
        defer { working = false }
        error = nil
        outcome = nil
        do {
            review = try await service.pullReview()
            // The fetch moved ahead and behind, so the folder's numbers move too.
            await onPulled()
        } catch {
            review = nil
            self.error = error.localizedDescription
        }
    }

    private func pull(_ reviewed: GitPullReview) async {
        working = true
        defer { working = false }
        error = nil
        do {
            outcome = try await service.pull(reviewed)
            await onPulled()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension BranchPull {
    /// The colours the pull request screens already use for each state.
    var tint: Color {
        if draft, state == "open" { return Theme.stateIdle }
        switch state {
        case "merged": return Theme.secondary
        case "closed": return Theme.danger
        default: return Theme.accent
        }
    }
}

/// The branch's pull request, or the way to open one. Beside Pull and Push
/// in Changes, so review, commit, push and the pull request are one place.
struct GitBranchPullControl: View {
    let workspaceID: String
    let peer: String?
    /// The folder's branch, so a checkout asks again.
    let branch: String?
    let folderName: String
    let hostName: String
    @State private var answer: BranchPullAnswer?
    @State private var creating = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if let pull = answer?.pull {
                Button(L10n.text("apple.branchpull.number", "\(pull.number)"), .external) {
                    if let url = URL(string: pull.url) { openURL(url) }
                }
                .buttonStyle(SecondaryButtonStyle(comfortable: true))
                .help(L10n.text("apple.branchpull.help", pull.stateLabel, "\(pull.number)", pull.title))
            } else if answer?.connected == true, answer?.branch != nil {
                Button(L10n.text("apple.branchpull.create"), .merge) { creating = true }
                    .buttonStyle(SecondaryButtonStyle(comfortable: true))
                    .help(L10n.text("apple.branchpull.create_help"))
            }
        }
        .task(id: "\(workspaceID)|\(branch ?? "")") { await load(refresh: false) }
        .sheet(isPresented: $creating) {
            PullCreateView(workspaceID: workspaceID, peer: peer, folderName: folderName, hostName: hostName) {
                await load(refresh: true)
            }
        }
    }

    private func load(refresh: Bool) async {
        answer = try? await Bridge.branchPull(workspaceID: workspaceID, peer: peer, refresh: refresh)
    }
}

/// The pull request for the branch a chat is on, as a small chip. Opens it
/// on the forge.
struct BranchPullChip: View {
    let pull: BranchPull
    @Environment(\.openURL) private var openURL

    #if os(macOS)
    private static let font = Theme.font(12, weight: .medium)
    #else
    private static let font = ClientType.caption.weight(.medium)
    #endif

    var body: some View {
        Button {
            if let url = URL(string: pull.url) { openURL(url) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: pull.symbol)
                Text(L10n.text("apple.branchpull.chip", "\(pull.number)", pull.stateLabel))
                    .lineLimit(1)
            }
            .font(Self.font)
            .foregroundStyle(pull.tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(pull.tint.opacity(0.12), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(L10n.text("apple.branchpull.help", pull.stateLabel, "\(pull.number)", pull.title))
        .accessibilityLabel(L10n.text("apple.branchpull.help", pull.stateLabel, "\(pull.number)", pull.title))
    }
}

/// "Changes +382 −236" above the composer: the folder's uncommitted work,
/// one press from being reviewed beside the chat.
struct ChatChangesPill: View {
    let git: GitStatus
    let review: () -> Void

    #if os(macOS)
    private static let font = Theme.font(12, weight: .medium)
    private static let numbers = Theme.numeric(12)
    #else
    private static let font = ClientType.caption.weight(.medium)
    private static let numbers = ClientType.caption
    #endif

    var body: some View {
        Button(action: review) {
            HStack(spacing: 6) {
                Text(L10n.text("apple.chatchanges.bar"))
                    .font(Self.font)
                    .foregroundStyle(.secondary)
                DiffStat(added: Int(git.added), removed: Int(git.removed), font: Self.numbers)
                    .fixedSize()
                Text(git.files.count == 1
                     ? L10n.text("apple.chatchanges.bar_files.one", "1")
                     : L10n.text("apple.chatchanges.bar_files.other", "\(git.files.count)"))
                    .font(Self.numbers)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Theme.panel, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.border))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(L10n.text("apple.chatchanges.bar_help"))
    }
}
