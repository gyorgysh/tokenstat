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
        Button(session?.draft.submitted == nil ? (outgoing > 0 ? "Push \(outgoing)" : "Push…") : "Check push", .upload) {
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
        ThemedSheet(title: "Push branch", subtitle: [folderName, hostName].filter { !$0.isEmpty }.joined(separator: " · "),
                    icon: .upload, onClose: { dismiss() }) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    if let review = session.review ?? session.draft.submitted?.review ?? session.outcome?.review {
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            Text(review.branchName).font(Theme.title3.weight(.semibold))
                            Text("To \(review.destination)").font(Theme.callout).foregroundStyle(Theme.controlGlyph)
                            Text(String(review.head.prefix(10))).font(Theme.monoText(12, relativeTo: .caption)).foregroundStyle(Theme.controlGlyph)
                        }
                        if review.upToDate {
                            Text("This branch is up to date.").font(Theme.callout).foregroundStyle(Theme.accent)
                        } else if review.outgoing == 0 {
                            Text("No outgoing commits. The remote branch is ahead.").font(Theme.callout)
                        } else if review.remoteHead == nil {
                            Text("Publish this branch to \(review.remote).").font(Theme.callout)
                        } else if let count = review.outgoing {
                            Text("\(count) \(count == 1 ? "commit" : "commits") to push").font(Theme.callout)
                        } else {
                            Text("The computer will check whether the remote branch can accept this commit.").font(Theme.callout)
                        }
                        if review.setUpstream {
                            Text("This will also set the branch's tracking destination.").font(Theme.caption).foregroundStyle(Theme.controlGlyph)
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
                        ProgressView(session.draft.submitted == nil ? "Checking the branch" : "Checking push")
                            .font(Theme.callout)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        } actions: {
            if session.draft.submitted != nil {
                if session.canRetry {
                    Button("Retry same push", .upload) { Task { await session.retry(); await refreshIfPushed() } }
                        .buttonStyle(SecondaryButtonStyle(comfortable: true)).disabled(session.working)
                }
                Button("Check outcome", .refresh) { Task { await session.checkOutcome(); await refreshIfPushed() } }
                    .buttonStyle(AccentButtonStyle(comfortable: true)).disabled(session.working)
            } else if session.outcome?.succeeded == true || session.review?.upToDate == true || session.review?.outgoing == 0 {
                Button("Done", .done) { dismiss() }.buttonStyle(AccentButtonStyle(comfortable: true))
            } else if session.review != nil {
                Button(session.review?.remoteHead == nil ? "Publish branch" : "Push branch", .upload) { Task { await session.submit(); await refreshIfPushed() } }
                    .buttonStyle(AccentButtonStyle(comfortable: true)).disabled(session.working)
            } else {
                Button("Check branch", .refresh) { Task { await session.prepare() } }
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
