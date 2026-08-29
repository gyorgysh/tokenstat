// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Observation
import SwiftUI

/// A pull request as part of the workspace, not a small GitHub-shaped web page.
/// Conversation is the default; expensive diff bytes arrive only when Changes
/// is opened, and the inspector yields below the reading column on a phone.
struct PullDetailView: View {
    let workspaceID: String
    let peer: String?
    let summary: PullSummary
    let onBack: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var model = PullDetailModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                topBar
                if let error = model.error, model.detail == nil {
                    errorCard(error)
                } else if let detail = model.detail {
                    hero(detail)
                    DetailTabs(selection: $model.tab, checks: detail.checks.count)
                    if let notice = model.actionNotice { actionBanner(notice, tint: Theme.success, symbol: "checkmark.circle.fill") }
                    if let error = model.actionError { actionBanner(FriendlyError.from(error).message, tint: Theme.warning, symbol: "exclamationmark.triangle.fill") }
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: Theme.Space.l) {
                            selectedContent(detail).frame(maxWidth: .infinity, alignment: .topLeading)
                            inspector(detail).frame(width: 248)
                        }
                        VStack(alignment: .leading, spacing: Theme.Space.l) {
                            selectedContent(detail)
                            inspector(detail)
                        }
                    }
                } else {
                    detailSkeleton
                }
            }
            .frame(maxWidth: 1040, alignment: .leading)
            .padding(Theme.Space.xl)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Theme.background)
        .task(id: summary.number) {
            await model.load(workspaceID: workspaceID, peer: peer, number: summary.number)
        }
        .onChange(of: model.tab) { _, tab in
            guard tab == .changes else { return }
            Task { await model.loadDiff(workspaceID: workspaceID, peer: peer, number: summary.number) }
        }
        .refreshable {
            await model.load(workspaceID: workspaceID, peer: peer, number: summary.number, refresh: true)
        }
        .confirmationDialog("Close this pull request?", isPresented: $model.confirmingClose, titleVisibility: .visible) {
            Button("Close pull request", role: .destructive) {
                Task { await model.setOpen(false, workspaceID: workspaceID, peer: peer, number: summary.number) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Other people will see it as closed. You can reopen it later.")
        }
        .confirmationDialog("Merge this pull request?", isPresented: $model.confirmingMerge, titleVisibility: .visible) {
            Button("Merge with \(model.mergeMethod.title.lowercased())") {
                Task { await model.merge(workspaceID: workspaceID, peer: peer, number: summary.number) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This changes the shared repository and cannot be undone from tokenstat.")
        }
    }

    private var topBar: some View {
        HStack(spacing: Theme.Space.s) {
            Button(action: onBack) { ActionIcon.back.label("Pull requests") }
                .buttonStyle(SecondaryButtonStyle(small: true))
            Spacer()
            if let raw = model.detail?.url, let url = URL(string: raw) {
                Button { openURL(url) } label: { ActionIcon.external.label("Open on GitHub") }
                    .buttonStyle(SecondaryButtonStyle(small: true))
            }
            ToolbarIconButton(systemImage: "arrow.clockwise", help: "Refresh pull request", isBusy: model.loading) {
                Task { await model.load(workspaceID: workspaceID, peer: peer, number: summary.number, refresh: true) }
            }
        }
    }

    private func hero(_ detail: PullDetail) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                PullStateMark(detail: detail)
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(detail.title)
                        .font(Theme.title2.weight(.semibold))
                        .textSelection(.enabled)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Theme.Space.s) {
                            authorIdentity(detail)
                            openingTime(detail)
                        }
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            authorIdentity(detail)
                            openingTime(detail)
                                .padding(.leading, 22 + Theme.Space.s)
                        }
                    }
                    .font(Theme.callout)
                }
            }
            HStack(spacing: Theme.Space.s) {
                branch(detail.headRef)
                Image(systemName: "arrow.right").font(Theme.caption2).foregroundStyle(.tertiary)
                branch(detail.baseRef)
                Spacer()
                changeCount("+\(detail.additions)", tint: Theme.diffAdded)
                changeCount("−\(detail.deletions)", tint: Theme.diffRemoved)
                changeCount("\(detail.changedFiles) files", tint: .secondary)
            }
        }
        .padding(Theme.cardPadding)
        .background(
            LinearGradient(colors: [Theme.accentSoft, Theme.panel], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: Theme.cardRadius)
        )
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.accent.opacity(0.18)))
    }

    private func authorIdentity(_ detail: PullDetail) -> some View {
        HStack(spacing: Theme.Space.s) {
            Avatar(url: detail.author.avatar, handle: detail.author.login, size: 22, tint: Avatar.tint(for: detail.author.login))
            Text(detail.author.login).font(Theme.callout.weight(.medium))
        }
        .fixedSize()
    }

    private func openingTime(_ detail: PullDetail) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text("opened #\(detail.number)")
            if let date = detail.createdDate {
                Text("·").foregroundStyle(.tertiary)
                RelativeTimeText(date: date, unitsStyle: .abbreviated)
            }
        }
        .foregroundStyle(.secondary)
        .fixedSize()
    }

    private func branch(_ value: String) -> some View {
        Text(value).font(Theme.monoText(11, weight: .medium, relativeTo: .caption))
            .lineLimit(1).padding(.horizontal, 9).padding(.vertical, 5)
            .background(Theme.accent.opacity(0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.16)))
    }

    private func changeCount(_ value: String, tint: Color) -> some View {
        Text(value).font(Theme.caption.weight(.semibold)).foregroundStyle(tint)
    }

    @ViewBuilder private func selectedContent(_ detail: PullDetail) -> some View {
        switch model.tab {
        case .conversation: conversation(detail)
        case .changes: changes
        case .checks: checks(detail)
        }
    }

    private func inspector(_ detail: PullDetail) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            PullInspector(detail: detail)
            PullActionPanel(
                detail: detail,
                model: model,
                workspaceID: workspaceID,
                peer: peer
            )
        }
    }

    private func conversation(_ detail: PullDetail) -> some View {
        LazyVStack(alignment: .leading, spacing: Theme.Space.m) {
            PullConversationCard(actor: detail.author, date: detail.createdDate) {
                if detail.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("No description was added.").font(Theme.body).foregroundStyle(.tertiary)
                } else { MarkdownText(detail.body) }
            }
            ForEach(model.events) { event in TimelineCard(event: event) }
            if model.loadingTimeline { ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding() }
            if let error = model.timelineError { inlineError(error) }
            if model.nextCursor != nil {
                Button {
                    Task { await model.moreTimeline(workspaceID: workspaceID, peer: peer, number: summary.number) }
                } label: { ActionIcon.more.label("Earlier activity") }
                .buttonStyle(SecondaryButtonStyle(small: true))
                .frame(maxWidth: .infinity)
            }
            PullCommentComposer(
                text: $model.commentDraft,
                busy: model.actionBusy,
                send: {
                    Task { await model.comment(workspaceID: workspaceID, peer: peer, number: summary.number) }
                }
            )
        }
    }

    private var changes: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if model.loadingDiff { detailSkeleton }
            else if let error = model.diffError { inlineError(error) }
            else if model.diffs.isEmpty {
                EmptyState(symbol: "doc.text.magnifyingglass", title: "No text changes", message: "This pull request has no line-by-line diff to show.")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Space.xs) {
                        ForEach(model.diffs, id: \.path) { diff in
                            Button { model.selectedPath = diff.path } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "doc.text").imageScale(.small)
                                    Text(diff.fileName).lineLimit(1)
                                }
                                .font(Theme.caption.weight(model.selectedPath == diff.path ? .semibold : .medium))
                                .foregroundStyle(model.selectedPath == diff.path ? Theme.accent : Color.secondary)
                                .padding(.horizontal, 10).frame(height: Theme.Control.height)
                                .background(model.selectedPath == diff.path ? Theme.accentSoft : Theme.panel, in: Capsule())
                                .overlay(Capsule().strokeBorder(model.selectedPath == diff.path ? Theme.accent.opacity(0.3) : Theme.border))
                            }.buttonStyle(.plain)
                        }
                    }
                }
                if let diff = model.diffs.first(where: { $0.path == model.selectedPath }) ?? model.diffs.first {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(diff.path).font(Theme.monoText(11, weight: .medium, relativeTo: .caption))
                            .padding(Theme.Space.m).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.accent.opacity(0.055))
                        ScrollView(.horizontal) { DiffBody(diff: diff) }
                    }
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
                }
            }
        }
    }

    private func checks(_ detail: PullDetail) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            let passed = detail.checks.filter { $0.state == "passing" }.count
            HStack(spacing: Theme.Space.m) {
                ZStack {
                    Circle().fill(checksTint(detail).opacity(0.11)).frame(width: 46, height: 46)
                    Image(systemName: checksSymbol(detail)).foregroundStyle(checksTint(detail)).font(Theme.fixed(18, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(detail.checks.isEmpty ? "No checks reported" : "\(passed) of \(detail.checks.count) checks passed")
                        .font(Theme.body.weight(.semibold))
                    Text(checksMessage(detail)).font(Theme.caption).foregroundStyle(.secondary)
                }
            }
            .padding(Theme.cardPadding).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
            ForEach(detail.checks) { check in CheckRow(check: check) }
        }
    }

    private func checksTint(_ detail: PullDetail) -> Color {
        if detail.checks.contains(where: { $0.state == "failing" }) { return Theme.danger }
        if detail.checks.contains(where: { $0.state == "pending" }) { return Theme.warning }
        return Theme.success
    }
    private func checksSymbol(_ detail: PullDetail) -> String {
        if detail.checks.contains(where: { $0.state == "failing" }) { return "xmark" }
        if detail.checks.contains(where: { $0.state == "pending" }) { return "ellipsis" }
        return "checkmark"
    }
    private func checksMessage(_ detail: PullDetail) -> String {
        if detail.checks.isEmpty { return "The head commit does not publish a check suite." }
        if detail.checks.contains(where: { $0.state == "failing" }) { return "Something needs attention before this is ready." }
        if detail.checks.contains(where: { $0.state == "pending" }) { return "The remaining work is still running." }
        return "Everything reported by the head commit is green."
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            inlineError(message)
            Button { Task { await model.load(workspaceID: workspaceID, peer: peer, number: summary.number, refresh: true) } }
                label: { ActionIcon.refresh.label("Try again") }
                .buttonStyle(AccentButtonStyle(small: true))
        }
    }
    private func inlineError(_ message: String) -> some View {
        Label(FriendlyError.from(message).message, systemImage: "exclamationmark.triangle.fill")
            .font(Theme.callout).foregroundStyle(Theme.warning).padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.warning.opacity(0.09), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
    }
    private func actionBanner(_ message: String, tint: Color, symbol: String) -> some View {
        Label(message, systemImage: symbol)
            .font(Theme.callout.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, Theme.Space.m)
            .frame(minHeight: 42)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(tint.opacity(0.16)))
    }
    private var detailSkeleton: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Skeleton.Bar(width: 240, height: 18)
            Skeleton.Bar(width: 160)
            ForEach(0..<4, id: \.self) { index in Skeleton.Bar(width: index == 3 ? 190 : 480, phase: Double(index) * 0.08) }
        }.padding(Theme.cardPadding).background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
    }
}

private enum PullDetailTab: String, CaseIterable, Identifiable {
    case conversation = "Conversation", changes = "Changes", checks = "Checks"
    var id: String { rawValue }
    var symbol: String { switch self { case .conversation: "bubble.left.and.bubble.right"; case .changes: "doc.text"; case .checks: "checkmark.circle" } }
}

private struct DetailTabs: View {
    @Binding var selection: PullDetailTab
    let checks: Int
    @Namespace private var slide
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(PullDetailTab.allCases) { tab in
                    Button { withAnimation(.snappy(duration: 0.22)) { selection = tab } } label: {
                        HStack(spacing: 7) {
                            Image(systemName: tab.symbol)
                            Text(tab.rawValue)
                            if tab == .checks, checks > 0 {
                                Text("\(checks)")
                                    .foregroundStyle(Theme.accent.opacity(selection == tab ? 1 : 0.48))
                            }
                        }
                        .font(Theme.caption.weight(selection == tab ? .semibold : .medium))
                        .foregroundStyle(selection == tab ? Theme.accent : Color.secondary)
                        .padding(.horizontal, Theme.Space.m).frame(height: 34)
                        .background { if selection == tab { RoundedRectangle(cornerRadius: 9).fill(Theme.accentSoft).matchedGeometryEffect(id: "tab", in: slide) } }
                    }.buttonStyle(.plain).accessibilityAddTraits(selection == tab ? .isSelected : [])
                }
            }.padding(3)
        }
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }
}

private struct PullStateMark: View {
    let detail: PullDetail
    var body: some View {
        Image(systemName: detail.draft ? "pencil.line" : detail.state == "merged" ? "arrow.triangle.merge" : "arrow.triangle.branch")
            .font(Theme.fixed(17, weight: .semibold)).foregroundStyle(tint).frame(width: 38, height: 38)
            .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 11))
    }
    private var tint: Color { detail.draft ? Theme.stateIdle : detail.state == "closed" ? Theme.danger : detail.state == "merged" ? Theme.secondary : Theme.accent }
}

private struct PullConversationCard<Content: View>: View {
    let actor: PullActor
    let date: Date?
    let content: Content

    init(actor: PullActor, date: Date?, @ViewBuilder content: () -> Content) {
        self.actor = actor
        self.date = date
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.s) {
                Avatar(url: actor.avatar, handle: actor.login, size: 24, tint: Avatar.tint(for: actor.login))
                Text(actor.login).font(Theme.callout.weight(.semibold))
                Spacer()
                if let date { RelativeTimeText(date: date, unitsStyle: .abbreviated).font(Theme.caption).foregroundStyle(.tertiary) }
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            content
        }
        .padding(Theme.cardPadding).background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
    }
}

private struct TimelineCard: View {
    let event: PullTimelineEvent
    var body: some View {
        if event.kind == "commented" || event.kind == "reviewed" {
            PullConversationCard(actor: event.actor, date: event.createdDate) {
                if event.kind == "reviewed", let state = event.state { Label(state.replacingOccurrences(of: "_", with: " ").capitalized, systemImage: state == "approved" ? "checkmark.circle.fill" : "eye.fill").font(Theme.caption.weight(.semibold)).foregroundStyle(state == "approved" ? Theme.success : Theme.warning) }
                if let body = event.body, !body.isEmpty { MarkdownText(body) }
            }
        } else {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Image(systemName: symbol).font(Theme.fixed(11, weight: .semibold)).foregroundStyle(Theme.accent)
                    .frame(width: 28, height: 28).background(Theme.accentSoft, in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(sentence).font(Theme.callout)
                    if let date = event.createdDate { RelativeTimeText(date: date, unitsStyle: .abbreviated).font(Theme.caption2).foregroundStyle(.tertiary) }
                }
            }.padding(.horizontal, Theme.Space.s)
        }
    }
    private var sentence: String {
        let suffix = event.subject.map { " · \($0)" } ?? ""
        let verb = switch event.kind {
        case "committed": "committed"
        case "labeled": "added a label"
        case "unlabeled": "removed a label"
        case "assigned": "assigned"
        case "unassigned": "unassigned"
        case "reviewRequested": "requested a review"
        case "forcePushed": "force-pushed"
        case "renamed": "renamed the pull request"
        case "readyForReview": "marked this ready for review"
        case "closed": "closed the pull request"
        case "reopened": "reopened the pull request"
        case "merged": "merged the pull request"
        default: "updated the pull request"
        }
        return "\(event.actor.login) \(verb)\(suffix)"
    }
    private var symbol: String { switch event.kind { case "committed": "point.topleft.down.to.point.bottomright.curvepath"; case "merged": "arrow.triangle.merge"; case "closed": "xmark"; case "labeled", "unlabeled": "tag"; default: "circle.fill" } }
}

private struct PullInspector: View {
    let detail: PullDetail
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            section("REVIEW", icon: "eye") {
                inspectorValue(reviewText, tint: reviewTint)
                ForEach(detail.reviews) { review in actorRow(review.author, note: review.state.replacingOccurrences(of: "_", with: " ").capitalized) }
                ForEach(detail.reviewRequests) { actor in actorRow(actor, note: "Requested") }
            }
            if !detail.assignees.isEmpty { section("ASSIGNEES", icon: "person.2") { ForEach(detail.assignees) { actor in actorRow(actor, note: nil) } } }
            if !detail.labels.isEmpty { section("LABELS", icon: "tag") { FlowLabels(labels: detail.labels) } }
            section("MERGE", icon: "arrow.triangle.merge") {
                inspectorValue(detail.mergeable == "mergeable" ? "Ready to merge" : detail.mergeState.replacingOccurrences(of: "_", with: " ").capitalized, tint: detail.mergeable == "mergeable" ? Theme.success : Theme.warning)
            }
        }
        .padding(Theme.cardPadding).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
    }
    private func section<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Label(title, systemImage: icon).font(Theme.caption2.weight(.semibold)).tracking(0.7).foregroundStyle(.tertiary)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func actorRow(_ actor: PullActor, note: String?) -> some View {
        HStack(spacing: Theme.Space.s) {
            Avatar(url: actor.avatar, handle: actor.login, size: 22, tint: Avatar.tint(for: actor.login))
            VStack(alignment: .leading, spacing: 1) { Text(actor.login).font(Theme.caption.weight(.medium)); if let note { Text(note).font(Theme.caption2).foregroundStyle(.tertiary) } }
        }
    }
    private func inspectorValue(_ text: String, tint: Color) -> some View { Label(text, systemImage: "circle.fill").font(Theme.caption.weight(.medium)).foregroundStyle(tint) }
    private var reviewText: String { switch detail.reviewDecision { case "approved": "Approved"; case "changes_requested": "Changes requested"; default: "Review pending" } }
    private var reviewTint: Color { switch detail.reviewDecision { case "approved": Theme.success; case "changes_requested": Theme.danger; default: Theme.warning } }
}

private struct PullCommentComposer: View {
    @Binding var text: String
    let busy: Bool
    let send: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: ActionIcon.comment.symbol)
                    .foregroundStyle(Theme.accent)
                Text("Join the conversation")
                    .font(Theme.callout.weight(.semibold))
            }
            composerField("Write a comment…", text: $text, minHeight: 92)
            HStack {
                Text("Markdown is supported")
                    .font(Theme.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Comment", .comment, action: send)
                    .buttonStyle(AccentButtonStyle(small: true))
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
            }
        }
        .padding(Theme.cardPadding)
        .background(
            LinearGradient(colors: [Theme.accentSoft.opacity(0.72), Theme.panel], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: Theme.cardRadius)
        )
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.accent.opacity(0.18)))
    }
}

private struct PullActionPanel: View {
    let detail: PullDetail
    @Bindable var model: PullDetailModel
    let workspaceID: String
    let peer: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Label("ACTIONS", systemImage: "sparkles")
                .font(Theme.caption2.weight(.semibold))
                .tracking(0.7)
                .foregroundStyle(.tertiary)

            if detail.state == "open" {
                reviewActions
                if detail.draft {
                    Button("Ready for review", .done) {
                        Task { await model.ready(workspaceID: workspaceID, peer: peer, number: detail.number) }
                    }
                    .buttonStyle(AccentButtonStyle(small: true))
                    .disabled(model.actionBusy)
                }
                mergeActions
                Button("Close pull request", .dismiss) { model.confirmingClose = true }
                    .buttonStyle(DestructiveButtonStyle(small: true))
                    .disabled(model.actionBusy)
            } else if detail.state == "closed" {
                Button("Reopen pull request", .reopen) {
                    Task { await model.setOpen(true, workspaceID: workspaceID, peer: peer, number: detail.number) }
                }
                .buttonStyle(AccentButtonStyle(small: true))
                .disabled(model.actionBusy)
            }

            checkoutActions
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
    }

    private var reviewActions: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Review")
                .font(Theme.caption.weight(.semibold))
            Button("Approve", .approve) {
                Task { await model.review(.approve, workspaceID: workspaceID, peer: peer, number: detail.number) }
            }
            .buttonStyle(SecondaryButtonStyle(small: true))
            .disabled(model.actionBusy)
            Button("Request changes", .edit) { model.beginReview(.requestChanges) }
                .buttonStyle(SecondaryButtonStyle(small: true))
                .disabled(model.actionBusy)
            Button("Comment review", .comment) { model.beginReview(.comment) }
                .buttonStyle(SecondaryButtonStyle(small: true))
                .disabled(model.actionBusy)
            if let mode = model.reviewMode {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    composerField(
                        mode == .requestChanges ? "Explain what needs to change…" : "Add a review note…",
                        text: $model.reviewDraft,
                        minHeight: 82
                    )
                    HStack {
                        Button("Cancel", .dismiss) { model.cancelReview() }
                            .buttonStyle(SecondaryButtonStyle(small: true))
                        Spacer()
                        Button("Send review", .send) {
                            Task { await model.review(mode, workspaceID: workspaceID, peer: peer, number: detail.number) }
                        }
                        .buttonStyle(AccentButtonStyle(small: true))
                        .disabled(model.reviewDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.actionBusy)
                    }
                }
                .padding(Theme.Space.s)
                .background(Theme.accentSoft.opacity(0.58), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var mergeActions: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Merge method")
                .font(Theme.caption.weight(.semibold))
            SegmentedTabs(
                options: PullMergeMethod.allCases,
                selection: $model.mergeMethod,
                title: \PullMergeMethod.title
            )
            Button("Merge pull request", .merge) { model.confirmingMerge = true }
                .buttonStyle(AccentButtonStyle(small: true))
                .disabled(detail.draft || model.actionBusy)
        }
        .padding(.top, Theme.Space.xs)
    }

    private var checkoutActions: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Local checkout")
                .font(Theme.caption.weight(.semibold))
            TextField("Local branch name", text: $model.checkoutBranch)
                .textFieldStyle(.plain)
                .font(Theme.monoText(11, weight: .medium, relativeTo: .caption))
                .padding(.horizontal, 10)
                .frame(height: Theme.Control.height)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border))
            Button("Check out locally", .checkout) {
                Task { await model.checkout(workspaceID: workspaceID, peer: peer, number: detail.number) }
            }
            .buttonStyle(SecondaryButtonStyle(small: true))
            .disabled(model.checkoutBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.actionBusy)
        }
        .padding(.top, Theme.Space.xs)
    }
}

private func composerField(_ placeholder: String, text: Binding<String>, minHeight: CGFloat) -> some View {
    ZStack(alignment: .topLeading) {
        if text.wrappedValue.isEmpty {
            Text(placeholder)
                .font(Theme.callout)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 9)
                .padding(.vertical, 10)
                .allowsHitTesting(false)
        }
        TextEditor(text: text)
            .font(Theme.callout)
            .scrollContentBackground(.hidden)
            .padding(4)
    }
    .frame(height: minHeight)
    .background(Theme.background, in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
}

private struct FlowLabels: View {
    let labels: [String]
    var body: some View { VStack(alignment: .leading, spacing: 5) { ForEach(labels, id: \.self) { label in Text(label).font(Theme.caption2.weight(.medium)).foregroundStyle(Theme.secondary).padding(.horizontal, 8).padding(.vertical, 4).background(Theme.secondary.opacity(0.10), in: Capsule()) } } }
}

private struct CheckRow: View {
    let check: PullCheck
    @Environment(\.openURL) private var openURL
    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: symbol).font(Theme.fixed(12, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 30, height: 30).background(tint.opacity(0.10), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(check.name).font(Theme.callout.weight(.medium))
                HStack(spacing: 5) {
                    if let workflow = check.workflow { Text(workflow) }
                    if let duration = check.durationText {
                        if check.workflow != nil { Text("·").foregroundStyle(.tertiary) }
                        Text(duration)
                    }
                }
                .font(Theme.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(check.state.capitalized).font(Theme.caption.weight(.semibold)).foregroundStyle(tint)
            if let raw = check.url, let url = URL(string: raw) { Button { openURL(url) } label: { Image(systemName: ActionIcon.external.symbol).accessibilityLabel("Open check") }.buttonStyle(.plain).foregroundStyle(Theme.accent) }
        }
        .padding(Theme.Space.m).background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
    }
    private var symbol: String { check.state == "passing" ? "checkmark" : check.state == "failing" ? "xmark" : "ellipsis" }
    private var tint: Color { check.state == "passing" ? Theme.success : check.state == "failing" ? Theme.danger : Theme.warning }
}

@MainActor @Observable
private final class PullDetailModel {
    var detail: PullDetail?
    var events: [PullTimelineEvent] = []
    var nextCursor: String?
    var diffs: [FileDiff] = []
    var selectedPath: String?
    var tab: PullDetailTab = .conversation
    var loading = false
    var loadingTimeline = false
    var loadingDiff = false
    var error: String?
    var timelineError: String?
    var diffError: String?
    var commentDraft = ""
    var reviewDraft = ""
    var reviewMode: PullReviewVerdict?
    var checkoutBranch = ""
    var mergeMethod: PullMergeMethod = .squash
    var actionBusy = false
    var actionNotice: String?
    var actionError: String?
    var confirmingClose = false
    var confirmingMerge = false

    func load(workspaceID: String, peer: String?, number: UInt32, refresh: Bool = false) async {
        loading = true; error = nil; defer { loading = false }
        do {
            async let detail = Bridge.pullView(workspaceID: workspaceID, peer: peer, number: number, refresh: refresh)
            async let timeline = Bridge.pullTimeline(workspaceID: workspaceID, peer: peer, number: number, refresh: refresh)
            let loaded = try await detail
            self.detail = loaded
            if checkoutBranch.isEmpty { checkoutBranch = loaded.headRef }
            let page = try await timeline
            events = page.events; nextCursor = page.nextCursor; timelineError = nil
        } catch { self.error = error.localizedDescription }
        if tab == .changes { await loadDiff(workspaceID: workspaceID, peer: peer, number: number, refresh: refresh) }
    }
    func moreTimeline(workspaceID: String, peer: String?, number: UInt32) async {
        guard let cursor = nextCursor, !loadingTimeline else { return }
        loadingTimeline = true; timelineError = nil; defer { loadingTimeline = false }
        do { let page = try await Bridge.pullTimeline(workspaceID: workspaceID, peer: peer, number: number, cursor: cursor); events += page.events; nextCursor = page.nextCursor }
        catch { timelineError = error.localizedDescription }
    }
    func loadDiff(workspaceID: String, peer: String?, number: UInt32, refresh: Bool = false) async {
        guard diffs.isEmpty || refresh, !loadingDiff else { return }
        loadingDiff = true; diffError = nil; defer { loadingDiff = false }
        do { diffs = try await Bridge.pullDiff(workspaceID: workspaceID, peer: peer, number: number, refresh: refresh); selectedPath = diffs.first?.path }
        catch { diffError = error.localizedDescription }
    }

    func beginReview(_ verdict: PullReviewVerdict) {
        reviewMode = verdict
        reviewDraft = ""
        actionError = nil
    }

    func cancelReview() {
        reviewMode = nil
        reviewDraft = ""
    }

    func comment(workspaceID: String, peer: String?, number: UInt32) async {
        let body = commentDraft
        if await perform("Comment posted", refresh: true, workspaceID: workspaceID, peer: peer, number: number, action: {
            try await Bridge.pullComment(workspaceID: workspaceID, peer: peer, number: number, body: body)
        }) {
            commentDraft = ""
        }
    }

    func review(
        _ verdict: PullReviewVerdict,
        workspaceID: String,
        peer: String?,
        number: UInt32
    ) async {
        let body = verdict == .approve ? "" : reviewDraft
        let message = switch verdict {
        case .approve: "Review approved"
        case .requestChanges: "Changes requested"
        case .comment: "Review comment posted"
        }
        if await perform(message, refresh: true, workspaceID: workspaceID, peer: peer, number: number, action: {
            try await Bridge.pullReview(
                workspaceID: workspaceID, peer: peer, number: number,
                verdict: verdict, body: body
            )
        }) {
            cancelReview()
        }
    }

    func ready(workspaceID: String, peer: String?, number: UInt32) async {
        _ = await perform("Ready for review", refresh: true, workspaceID: workspaceID, peer: peer, number: number) {
            try await Bridge.pullReady(workspaceID: workspaceID, peer: peer, number: number)
        }
    }

    func setOpen(_ open: Bool, workspaceID: String, peer: String?, number: UInt32) async {
        _ = await perform(open ? "Pull request reopened" : "Pull request closed", refresh: true, workspaceID: workspaceID, peer: peer, number: number) {
            try await Bridge.pullSetOpen(workspaceID: workspaceID, peer: peer, number: number, open: open)
        }
    }

    func merge(workspaceID: String, peer: String?, number: UInt32) async {
        _ = await perform("Pull request merged", refresh: true, workspaceID: workspaceID, peer: peer, number: number) {
            try await Bridge.pullMerge(
                workspaceID: workspaceID, peer: peer, number: number, method: mergeMethod
            )
        }
    }

    func checkout(workspaceID: String, peer: String?, number: UInt32) async {
        guard !actionBusy else { return }
        actionBusy = true
        actionError = nil
        actionNotice = nil
        defer { actionBusy = false }
        do {
            let outcome = try await Bridge.pullCheckout(
                workspaceID: workspaceID, peer: peer, number: number, branch: checkoutBranch
            )
            if outcome.ok {
                actionNotice = "Checked out \(checkoutBranch)"
            } else {
                actionError = outcome.message
            }
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func perform(
        _ success: String,
        refresh: Bool,
        workspaceID: String,
        peer: String?,
        number: UInt32,
        action: () async throws -> Void
    ) async -> Bool {
        guard !actionBusy else { return false }
        actionBusy = true
        actionError = nil
        actionNotice = nil
        defer { actionBusy = false }
        do {
            try await action()
            actionNotice = success
            if refresh {
                await load(workspaceID: workspaceID, peer: peer, number: number, refresh: true)
            }
            return true
        } catch {
            actionError = error.localizedDescription
            return false
        }
    }
}
