// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Observation
import SwiftUI

/// Connection boundary for the pull-request workspace.
///
/// The same view ships on Mac, iPhone and iPad. A phone reads availability
/// through its host, but authorization itself stays on that computer so a
/// paired client can never retrieve the secret half of a login.
struct PullsView: View {
    let workspaceID: String
    var peer: String? = nil
    var connectionHostName: String? = nil

    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model = PullsModel()
    @State private var selectedPull: PullSummary?

    private var canConnectHere: Bool { connectionHostName == nil }

    var body: some View {
        Group {
            if let selectedPull {
                PullDetailView(
                    workspaceID: workspaceID,
                    peer: peer,
                    summary: selectedPull,
                    onBack: { self.selectedPull = nil }
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.l) {
                        heading
                        content
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(Theme.Space.xl)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .refreshable { await model.load(workspaceID: workspaceID, peer: peer, refresh: true) }
            }
        }
        .background(Theme.background)
        .task(id: workspaceID) { await model.load(workspaceID: workspaceID, peer: peer) }
        .onChange(of: model.scope) { _, _ in
            Task { await model.loadList(workspaceID: workspaceID, peer: peer) }
        }
        .onChange(of: model.state) { _, _ in
            Task { await model.loadList(workspaceID: workspaceID, peer: peer) }
        }
        .sheet(isPresented: loginPresented) { loginSheet }
    }

    private var loginPresented: Binding<Bool> {
        Binding(
            get: { model.login != nil },
            set: { presented in
                if !presented { Task { await model.cancelLogin() } }
            }
        )
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "arrow.triangle.merge")
                    .font(Theme.fixed(17, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 34, height: 34)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pull requests")
                        .font(Theme.title2.weight(.semibold))
                    Text(model.availability?.repositoryName ?? "Review the work around this branch")
                        .font(Theme.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isLoading && model.availability == nil {
                    ProgressView().controlSize(.small)
                }
                if model.availability?.state == "ready" {
                    ToolbarIconButton(
                        systemImage: "arrow.clockwise",
                        help: "Refresh pull requests",
                        isBusy: model.isLoadingList
                    ) {
                        Task {
                            await model.loadList(
                                workspaceID: workspaceID,
                                peer: peer,
                                refresh: true
                            )
                        }
                    }
                }
            }
            Rectangle()
                .fill(Theme.border)
                .frame(height: 1)
                .padding(.top, Theme.Space.s)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.errorMessage {
            errorCard(error)
        } else if let availability = model.availability {
            switch availability.state {
            case "notRepository":
                empty(
                    title: "This folder is not a Git repository",
                    message: "Pull requests appear for folders with a Git repository and a GitHub origin."
                )
            case "noRemote":
                empty(
                    title: "No GitHub origin yet",
                    message: "Add an origin remote to this repository, then refresh this screen."
                )
            case "signedOut":
                connectionCard(availability)
            case "needsInstallation":
                accessCard(
                    availability,
                    title: "Choose repositories",
                    message: "You are connected as @\(availability.login ?? "your GitHub account"). Now choose the repositories tokenstat may open."
                )
            case "noRepositoryAccess":
                accessCard(
                    availability,
                    title: "Grant this repository access",
                    message: "The connection works, but \(availability.repositoryName ?? "this repository") is not in tokenstat's selected repositories."
                )
            case "ready":
                pullList(availability)
            default:
                empty(
                    title: "GitHub returned an unfamiliar state",
                    message: "Refresh after updating tokenstat on the computer that owns this workspace."
                )
            }
        } else if !model.isLoading {
            empty(
                title: "Pull requests are unavailable",
                message: "Refresh to ask the workspace's computer again."
            )
        }
    }

    private func connectionCard(_ availability: PullAvailability) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            ZStack {
                Circle().fill(Theme.accent.opacity(0.08)).frame(width: 104, height: 104)
                Circle().stroke(Theme.accent.opacity(0.18), lineWidth: 1).frame(width: 78, height: 78)
                Image(systemName: "arrow.triangle.merge")
                    .font(Theme.fixed(30, weight: .light))
                    .foregroundStyle(Theme.accent)
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Bring the review into tokenstat")
                    .font(Theme.title3.weight(.semibold))
                Text("Read the conversation, inspect the same diff as Changes, follow checks, and review without losing the workspace around it.")
                    .font(Theme.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if canConnectHere {
                Button {
                    Task {
                        if let url = await model.beginLogin() { openURL(url) }
                    }
                } label: {
                    Label("Connect GitHub", systemImage: "link")
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(model.isConnecting)
            } else {
                Label(
                    "Connect Pull Requests on \(connectionHostName ?? "the workspace's computer"), then return here.",
                    systemImage: "laptopcomputer"
                )
                .font(Theme.callout)
                .foregroundStyle(.secondary)
            }
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
    }

    private func accessCard(
        _ availability: PullAvailability,
        title: String,
        message: String
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Label(title, systemImage: "lock.open")
                .font(Theme.title3.weight(.semibold))
                .foregroundStyle(Theme.accent)
            Text(message)
                .font(Theme.body)
                .foregroundStyle(.secondary)
            if let raw = availability.installUrl, let url = URL(string: raw) {
                Button { openURL(url) } label: {
                    Label("Choose repositories", systemImage: "arrow.up.right")
                }
                .buttonStyle(AccentButtonStyle())
            }
            Text("tokenstat only sees repositories selected for its GitHub App installation.")
                .font(Theme.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.accent.opacity(0.24)))
    }

    private func pullList(_ availability: PullAvailability) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.s) {
                Circle()
                    .fill(Theme.success)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text("@\(availability.login ?? "connected")")
                    .font(Theme.caption.weight(.medium))
                    .foregroundStyle(.primary)
                Text("· \(sourceLabel(availability.source))")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if !model.rows.isEmpty {
                    Text("\(model.rows.count) shown")
                        .font(Theme.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            PullFilters(scope: $model.scope, state: $model.state)

            if let error = model.listError {
                errorCard(error)
            } else if model.isLoadingList && model.rows.isEmpty {
                PullListSkeleton()
                    .transition(.smoothIn(reduceMotion: reduceMotion))
            } else if model.rows.isEmpty {
                filteredEmpty
                    .transition(.smoothIn(reduceMotion: reduceMotion))
            } else {
                LazyVStack(spacing: Theme.Space.s) {
                    ForEach(model.rows) { pull in
                        Button { selectedPull = pull } label: {
                            PullRow(pull: pull)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens pull request details")
                    }
                }
                .transition(.smoothIn(reduceMotion: reduceMotion))
                .opacity(model.isLoadingList ? 0.62 : 1)
                .animation(.easeOut(duration: 0.16), value: model.isLoadingList)
            }
        }
    }

    private var filteredEmpty: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            EmptyState(
                symbol: model.state == .draft ? "pencil.line" : "arrow.triangle.merge",
                title: "No \(model.state.label.lowercased()) pull requests",
                message: emptyMessage
            )
            if model.scope != .all || model.state != .open {
                Button {
                    withAnimation(.snappy(duration: 0.22)) {
                        model.scope = .all
                        model.state = .open
                    }
                } label: {
                    Label("Show open pull requests", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(AccentButtonStyle(small: true))
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
    }

    private var emptyMessage: String {
        switch model.scope {
        case .all: return "Nothing in this repository matches the selected state."
        case .mine: return "You have no pull requests matching the selected state."
        case .assigned: return "No matching pull requests are assigned to you."
        case .reviewRequested: return "No matching pull requests are waiting for your review."
        }
    }

    private func sourceLabel(_ source: String?) -> String {
        switch source {
        case "gitCredential": return "using Git's saved credential"
        case "environment": return "using the shell credential"
        case "pasted": return "using a token you supplied"
        default: return "tokenstat GitHub App"
        }
    }

    private func empty(title: String, message: String) -> some View {
        EmptyState(symbol: "arrow.triangle.merge", title: title, message: message)
            .padding(Theme.Space.l)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(FriendlyError.from(message).message)
                    .font(Theme.callout)
                Button("Try again") {
                    Task { await model.load(workspaceID: workspaceID, peer: peer) }
                }
                    .buttonStyle(AccentButtonStyle(small: true))
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.warning.opacity(0.25)))
    }

    @ViewBuilder
    private var loginSheet: some View {
        if let login = model.login {
            VStack(spacing: Theme.Space.l) {
                ZStack {
                    Circle().fill(Theme.accent.opacity(0.10)).frame(width: 82, height: 82)
                    Image(systemName: "link")
                        .font(Theme.fixed(26, weight: .light))
                        .foregroundStyle(Theme.accent)
                }
                VStack(spacing: Theme.Space.xs) {
                    Text("Connect GitHub")
                        .font(Theme.title2.weight(.semibold))
                    Text("Enter this one-time code in the GitHub page that just opened.")
                        .font(Theme.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Text(login.userCode)
                    .font(Theme.monoText(30, weight: .semibold, relativeTo: .title))
                    .tracking(2)
                    .foregroundStyle(Theme.accent)
                    .textSelection(.enabled)
                    .padding(.horizontal, Theme.Space.l)
                    .frame(height: 58)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.accent.opacity(0.3)))
                HStack(spacing: Theme.Space.s) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for GitHub…")
                        .font(Theme.callout)
                        .foregroundStyle(.secondary)
                }
                if let error = model.loginError {
                    Text(FriendlyError.from(error).message)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.danger)
                        .multilineTextAlignment(.center)
                }
                Button("Cancel") { Task { await model.cancelLogin() } }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(Theme.Space.xl)
            .frame(minWidth: 340, idealWidth: 420)
            .background(Theme.panel)
            .task(id: login.userCode) {
                await model.pollLogin(workspaceID: workspaceID, peer: peer)
            }
            #if !os(macOS)
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            #endif
        }
    }
}

/// The two questions are separate: whose pull requests, and which lifecycle
/// state. Keeping both visible avoids a menu whose current answer is hidden.
private struct PullFilters: View {
    @Binding var scope: PullScope
    @Binding var state: PullStateFilter
    @Namespace private var scopeSlide
    @Namespace private var stateSlide

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("SCOPE")
                    .font(Theme.caption2.weight(.semibold))
                    .tracking(0.7)
                    .foregroundStyle(.tertiary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) {
                        ForEach(PullScope.allCases) { option in
                            filterButton(
                                title: option.label,
                                selected: scope == option,
                                tint: Theme.accent,
                                namespace: scopeSlide
                            ) {
                                withAnimation(.snappy(duration: 0.22)) { scope = option }
                            }
                        }
                    }
                    .padding(2)
                }
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border))
            }

            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("STATE")
                    .font(Theme.caption2.weight(.semibold))
                    .tracking(0.7)
                    .foregroundStyle(.tertiary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Space.xs) {
                        ForEach(PullStateFilter.allCases) { option in
                            stateButton(option)
                        }
                    }
                }
            }
        }
        .padding(Theme.Space.m)
        .background(Theme.accent.opacity(0.035), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
    }

    private func filterButton(
        title: String,
        selected: Bool,
        tint: Color,
        namespace: Namespace.ID,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.caption.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? tint : Color.secondary)
                .padding(.horizontal, Theme.Space.m)
                .frame(height: Theme.Control.height)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(tint.opacity(0.12))
                            .matchedGeometryEffect(id: "selection", in: namespace)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func stateButton(_ option: PullStateFilter) -> some View {
        let selected = state == option
        let tint = tint(for: option)
        return Button {
            guard !selected else { return }
            withAnimation(.snappy(duration: 0.22)) { state = option }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(option.label)
            }
            .font(Theme.caption.weight(selected ? .semibold : .medium))
            .foregroundStyle(selected ? tint : Color.secondary)
            .padding(.horizontal, 11)
            .frame(height: Theme.Control.heightSmall)
            .background {
                if selected {
                    Capsule()
                        .fill(tint.opacity(0.13))
                        .matchedGeometryEffect(id: "state", in: stateSlide)
                }
            }
            .overlay(Capsule().strokeBorder(selected ? tint.opacity(0.34) : Theme.border))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func tint(for state: PullStateFilter) -> Color {
        switch state {
        case .open: return Theme.accent
        case .merged: return Theme.secondary
        case .closed: return Theme.danger
        case .draft: return Theme.stateIdle
        }
    }
}

private struct PullRow: View {
    let pull: PullSummary

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text("#\(pull.number)")
                    .font(Theme.numeric(12, weight: .semibold))
                    .foregroundStyle(stateTint)
                Text(pull.title)
                    .font(Theme.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer(minLength: Theme.Space.s)
                if let checks = pull.checks { PullChecksPill(state: checks) }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Space.s) { identity; branchAndCounts }
                VStack(alignment: .leading, spacing: Theme.Space.xs) { identity; branchAndCounts }
            }

            if !pull.labels.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(pull.labels.prefix(5), id: \.self) { label in
                            Text(label)
                                .font(Theme.caption2.weight(.medium))
                                .foregroundStyle(Theme.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Theme.secondary.opacity(0.10), in: Capsule())
                        }
                    }
                }
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(stateTint)
                .frame(width: 3)
                .padding(.vertical, 9)
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
        .accessibilityElement(children: .combine)
    }

    private var identity: some View {
        HStack(spacing: 6) {
            Avatar(
                url: pull.authorAvatar,
                handle: pull.author,
                size: 18,
                tint: Avatar.tint(for: pull.author)
            )
            Text(pull.author).lineLimit(1)
            if let date = pull.updatedDate {
                Text("·").foregroundStyle(.tertiary)
                RelativeTimeText(date: date, unitsStyle: .abbreviated)
            }
            if pull.comments > 0 {
                Label("\(pull.comments)", systemImage: "bubble.left")
                    .labelStyle(.titleAndIcon)
            }
            if let review = reviewLabel {
                Label(review.text, systemImage: review.symbol)
                    .foregroundStyle(review.tint)
            }
        }
        .font(Theme.caption)
        .foregroundStyle(.secondary)
    }

    private var branchAndCounts: some View {
        HStack(spacing: Theme.Space.s) {
            Text("\(pull.headRef) → \(pull.baseRef)")
                .font(Theme.monoText(10, relativeTo: .caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("+\(pull.additions)").foregroundStyle(Theme.diffAdded)
            Text("−\(pull.deletions)").foregroundStyle(Theme.diffRemoved)
            Text("\(pull.changedFiles) files").foregroundStyle(.tertiary)
        }
        .font(Theme.caption2.weight(.medium))
    }

    private var stateTint: Color {
        if pull.draft { return Theme.stateIdle }
        switch pull.state {
        case "merged": return Theme.secondary
        case "closed": return Theme.danger
        default: return Theme.accent
        }
    }

    private var reviewLabel: (text: String, symbol: String, tint: Color)? {
        switch pull.reviewDecision {
        case "approved": return ("Approved", "checkmark", Theme.success)
        case "changes_requested": return ("Changes requested", "exclamationmark", Theme.danger)
        case "review_required": return ("Review needed", "eye", Theme.warning)
        default: return nil
        }
    }
}

private struct PullChecksPill: View {
    let state: PullCheckState

    var body: some View {
        Label(label, systemImage: symbol)
            .font(Theme.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.11), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.25)))
            .fixedSize()
    }

    private var label: String {
        switch state {
        case .passing: return "Passing"
        case .failing: return "Failing"
        case .pending: return "Running"
        }
    }

    private var symbol: String {
        switch state {
        case .passing: return "checkmark"
        case .failing: return "xmark"
        case .pending: return "ellipsis"
        }
    }

    private var tint: Color {
        switch state {
        case .passing: return Theme.success
        case .failing: return Theme.danger
        case .pending: return Theme.warning
        }
    }
}

private struct PullListSkeleton: View {
    var body: some View {
        VStack(spacing: Theme.Space.s) {
            ForEach(0..<4, id: \.self) { index in
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    HStack {
                        Skeleton.Bar(width: 42, phase: Double(index) * 0.08)
                        Skeleton.Bar(width: index.isMultiple(of: 2) ? 220 : 170, phase: Double(index) * 0.08 + 0.03)
                        Spacer()
                        Skeleton.Bar(width: 58, height: 10, phase: Double(index) * 0.08 + 0.06)
                    }
                    Skeleton.Bar(width: 132, height: 9, phase: Double(index) * 0.08 + 0.09)
                    Skeleton.Bar(width: 196, height: 9, phase: Double(index) * 0.08 + 0.12)
                }
                .padding(Theme.Space.m)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
            }
        }
        .accessibilityLabel("Loading pull requests")
    }
}

@MainActor
@Observable
private final class PullsModel {
    var availability: PullAvailability?
    var login: PullDeviceLogin?
    var isLoading = false
    var isConnecting = false
    var isLoadingList = false
    var errorMessage: String?
    var listError: String?
    var loginError: String?
    var rows: [PullSummary] = []
    var scope: PullScope = .all
    var state: PullStateFilter = .open
    private var listGeneration = 0

    func load(workspaceID: String, peer: String?, refresh: Bool = false) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            availability = try await Bridge.pullAvailability(workspaceID: workspaceID, peer: peer)
            if availability?.state == "ready" {
                await loadList(workspaceID: workspaceID, peer: peer, refresh: refresh)
            } else {
                rows = []
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadList(workspaceID: String, peer: String?, refresh: Bool = false) async {
        guard availability?.state == "ready" else { return }
        listGeneration += 1
        let generation = listGeneration
        let requestedScope = scope
        let requestedState = state
        isLoadingList = true
        listError = nil
        do {
            let loaded = try await Bridge.pullList(
                workspaceID: workspaceID,
                peer: peer,
                scope: requestedScope,
                state: requestedState,
                refresh: refresh
            )
            guard generation == listGeneration else { return }
            rows = loaded
        } catch {
            guard generation == listGeneration else { return }
            listError = error.localizedDescription
        }
        if generation == listGeneration { isLoadingList = false }
    }

    func beginLogin() async -> URL? {
        isConnecting = true
        loginError = nil
        defer { isConnecting = false }
        do {
            let login = try await Bridge.startPullLogin()
            self.login = login
            return URL(string: login.openUrl)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func pollLogin(workspaceID: String, peer: String?) async {
        while let login, !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(Double(max(login.interval, 1))))
                let result = try await Bridge.pollPullLogin()
                if result.state == "confirmed" {
                    self.login = nil
                    await load(workspaceID: workspaceID, peer: peer)
                    return
                }
                if let interval = result.interval {
                    self.login?.interval = interval
                }
            } catch is CancellationError {
                return
            } catch {
                loginError = error.localizedDescription
                return
            }
        }
    }

    func cancelLogin() async {
        login = nil
        loginError = nil
        await Bridge.cancelPullLogin()
    }
}
