// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// The same host-owned Push entry in desktop and mobile Changes. Loading this
/// control restores an operation identity; it never reads a remote or pushes.
struct GitPushControl: View {
    let target: GitCommitTarget
    let folderName: String
    let hostName: String
    let outgoing: UInt32
    var onPushed: () async -> Void
    @State private var session: GitPushSession?
    @State private var presenting = false

    var body: some View {
        Button(session?.draft.submitted == nil ? (outgoing > 0 ? L10n.text("apple.gitpushview.push_0.a738ad29", "\(outgoing)") : L10n.text("apple.gitpushview.push.92363252")) : L10n.text("apple.gitpushview.check_push.c821c305"), .upload) {
            presenting = true
        }
        .buttonStyle(SecondaryButtonStyle(comfortable: true))
        .disabled(session == nil)
        .task(id: target) {
            session = nil
            if target.peer == nil { await WorkSessionContext.shared.resolveLocalHostIdentity() }
            guard !Task.isCancelled else { return }
            let restored = GitPushSessions.session(target: target)
            await restored.load()
            guard !Task.isCancelled else { return }
            session = restored
        }
        .sheet(isPresented: $presenting) {
            if let session {
                GitPushView(session: session, folderName: folderName, hostName: hostName, onPushed: onPushed)
            }
        }
    }
}

struct GitPushView: View {
    @Bindable var session: GitPushSession
    let folderName: String
    let hostName: String
    var onPushed: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ThemedSheet(title: L10n.text("apple.gitpushview.push_branch.97deb7c0"), subtitle: [folderName, hostName].filter { !$0.isEmpty }.joined(separator: " · "),
                    icon: .upload, onClose: { dismiss() }) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    if let review = session.review ?? session.draft.submitted?.review ?? session.outcome?.review {
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            Text(review.branchName).font(Theme.title3.weight(.semibold))
                            Text(L10n.text("apple.gitpushview.to_0.e7bc111d", "\(review.destination)")).font(Theme.callout).foregroundStyle(Theme.controlGlyph)
                            Text(String(review.head.prefix(10))).font(Theme.monoText(12, relativeTo: .caption)).foregroundStyle(Theme.controlGlyph)
                        }
                        if review.upToDate {
                            Text(L10n.text("apple.gitpushview.this_branch_is_up_to_date.01b49ce3")).font(Theme.callout).foregroundStyle(Theme.accent)
                        } else if review.outgoing == 0 {
                            Text(L10n.text("apple.gitpushview.no_outgoing_commits_the_remote_branch_is_a.7072ceca")).font(Theme.callout)
                        } else if review.remoteHead == nil {
                            Text(L10n.text("apple.gitpushview.publish_this_branch_to_0.e623bfa9", "\(review.remote)")).font(Theme.callout)
                        } else if let count = review.outgoing {
                            Text(L10n.text("apple.gitpushview.0_1_to_push.190b18e2", "\(count)", "\(count == 1 ? L10n.text("apple.gitpushview.commit.9505cacb") : "commits")")).font(Theme.callout)
                        } else {
                            Text(L10n.text("apple.gitpushview.the_computer_will_check_whether_the_remote.2c0a07ce")).font(Theme.callout)
                        }
                        if review.setUpstream {
                            Text(L10n.text("apple.gitpushview.this_will_also_set_the_branch_s_tracking_d.95dfeac0")).font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                        }
                    }
                    if let outcome = session.outcome {
                        Text(outcome.message).font(Theme.callout)
                            .foregroundStyle(outcome.succeeded ? Theme.accent : Theme.danger)
                            .textSelection(.enabled)
                    }
                    if let error = session.errorMessage {
                        Text(error).font(Theme.callout).foregroundStyle(Theme.danger).textSelection(.enabled)
                    }
                    if session.working {
                        ProgressView(session.draft.submitted == nil ? L10n.text("apple.gitpushview.checking_the_branch.3733503a") : L10n.text("apple.gitpushview.checking_push.00fa6ce0"))
                            .font(Theme.callout)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        } actions: {
            if session.draft.submitted != nil {
                if session.canRetry {
                    Button(L10n.text("apple.gitpushview.retry_same_push.d4ab8f02"), .upload) { Task { await session.retry(); await refreshIfPushed() } }
                        .buttonStyle(SecondaryButtonStyle(comfortable: true)).disabled(session.working)
                }
                Button(L10n.text("apple.gitpushview.check_outcome.9200a2fd"), .refresh) { Task { await session.checkOutcome(); await refreshIfPushed() } }
                    .buttonStyle(AccentButtonStyle(comfortable: true)).disabled(session.working)
            } else if session.outcome?.succeeded == true || session.review?.upToDate == true || session.review?.outgoing == 0 {
                Button(L10n.text("common.done"), .done) { dismiss() }.buttonStyle(AccentButtonStyle(comfortable: true))
            } else if session.review != nil {
                Button(session.review?.remoteHead == nil ? L10n.text("apple.gitpushview.publish_branch.e1f5968c") : L10n.text("apple.gitpushview.push_branch.97deb7c0"), .upload) { Task { await session.submit(); await refreshIfPushed() } }
                    .buttonStyle(AccentButtonStyle(comfortable: true)).disabled(session.working)
            } else {
                Button(L10n.text("apple.gitpushview.check_branch.8128e71f"), .refresh) { Task { await session.prepare() } }
                    .buttonStyle(AccentButtonStyle(comfortable: true)).disabled(session.working)
            }
        }
        .modalFrame(width: 520, height: 430)
        #if !os(macOS)
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.height(360), .large])
        #endif
        .interactiveDismissDisabled(session.working)
        .task { await session.prepare() }
    }

    private func refreshIfPushed() async {
        if session.outcome?.succeeded == true { await onPushed() }
    }
}
