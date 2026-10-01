// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Observation
import SwiftUI

/// Open-list counts already seen by this app process. Sidebar badges read this
/// synchronously; writing it never performs a request.
@MainActor @Observable
final class PullCountStore {
    static let shared = PullCountStore()
    private var values: [String: Int] = [:]

    func count(workspaceID: String, peer: String? = nil) -> Int? {
        values[key(workspaceID: workspaceID, peer: peer)]
    }

    func count(key: String) -> Int? { values[key] }

    func set(_ count: Int, workspaceID: String, peer: String?) {
        values[key(workspaceID: workspaceID, peer: peer)] = count
    }

    private func key(workspaceID: String, peer: String?) -> String {
        guard let peer, !workspaceID.hasPrefix("remote:") else { return workspaceID }
        return "remote:\(peer):\(workspaceID)"
    }
}

/// Connection boundary for the pull-request workspace.
///
/// The same view ships on Mac, iPhone and iPad. A phone reads availability
/// through its host, but authorization itself stays on that computer so a
/// paired client can never retrieve the secret half of a login.
struct PullsView: View {
    let workspaceID: String
    var peer: String? = nil
    var connectionHostName: String? = nil
    /// The folder named in the shared Mac chrome. Clients already name it in
    /// their navigation stack, so this stays optional for those call sites.
    var workspaceName: String? = nil
    var workspaceIsRemote = false
    /// Root keeps this pane mounted after a visit so a return is instant.
    /// When false, skip loading and heavy layout; opacity alone still measures.
    var isActive: Bool = true

    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model = PullsModel()
    @State private var selectedPull: PullSummary?

    private var canConnectHere: Bool { connectionHostName == nil }

    var body: some View {
        Group {
        if !isActive {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
        } else {
        RemoteHostFeatureGate(feature: .pulls, peer: peer, hostName: connectionHostName) {
            Group {
            if let selectedPull {
                PullDetailView(
                    workspaceID: workspaceID,
                    peer: peer,
                    summary: selectedPull,
                    scope: scopeChip,
                    onBack: {
                        self.selectedPull = nil
                        Task { await model.loadList(workspaceID: workspaceID, peer: peer, refresh: true) }
                    }
                )
            } else {
                VStack(spacing: 0) {
                    #if os(macOS)
                    DetailChromeBar(scope: scopeChip) {
                        if model.availability?.state == "ready" {
                            refreshButton
                        }
                    }
                    #endif
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.Space.l) {
                            heading
                            content
                        }
                        .frame(maxWidth: ReadingRoom.listWidth, alignment: .leading)
                        .padding(Theme.Space.xl)
                        // Top as well as leading. `ReadingRoom.alignment` is
                        // `.topLeading`, but a frame only honours the vertical
                        // half of an alignment when it is also given a height,
                        // so without `maxHeight` this was a leading alignment
                        // and nothing held the screen to the top of the
                        // column. A short list sat in the middle of the page.
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: ReadingRoom.alignment
                        )
                    }
                    .refreshable { await model.load(workspaceID: workspaceID, peer: peer, refresh: true) }
                }
            }
            }
            .background(Theme.background)
            // What every other section gets from `ClientCardList`, which this
            // screen does not use because it is shared with the Mac. Without
            // it the bar keeps the default large-title mode with no title in
            // it, and reserves the height of one: the empty strip that pushed
            // this screen down the page while Tasks and Notes sat at the top.
            #if !os(macOS)
            .navigationTitle(L10n.text("apple.pullsview.pull_requests.d9e3f260"))
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .task(id: "\(workspaceID)-\(peer ?? "")-\(isActive)") {
                guard isActive else { return }
                await model.load(workspaceID: workspaceID, peer: peer)
            }
            .onChange(of: model.scope) { _, _ in
                guard isActive else { return }
                Task { await model.loadList(workspaceID: workspaceID, peer: peer) }
            }
            .onChange(of: model.state) { _, _ in
                Task { await model.loadList(workspaceID: workspaceID, peer: peer) }
            }
            .sheet(isPresented: loginPresented) { loginSheet }
            .onChange(of: workspaceID) { _, _ in selectedPull = nil }
            .onChange(of: peer) { _, _ in selectedPull = nil }
            .onChange(of: WorkSessionContext.shared.scope) { _, _ in
                selectedPull = nil
                model = PullsModel()
                Task { if isActive { await model.load(workspaceID: workspaceID, peer: peer) } }
            }
        }
        }
        }
    }

    private var scopeChip: ScopeChip? {
        guard let workspaceName, !workspaceName.isEmpty else { return nil }
        return ScopeChip(
            label: workspaceName,
            symbol: workspaceIsRemote ? "network" : "folder.fill"
        )
    }

    private var refreshButton: some View {
        ToolbarIconButton(
            systemImage: "arrow.clockwise",
            help: L10n.text("apple.pullsview.refresh_pull_requests.d2fd16c2"),
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
                // The mark and the name are the screen's own on the Mac, where
                // there is no navigation bar to carry them. On a phone or an
                // iPad the bar has the name, so repeating it here would be the
                // title twice with a gap between.
                #if os(macOS)
                Image(systemName: "arrow.triangle.merge")
                    .font(Theme.fixed(17, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 34, height: 34)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("apple.pullsview.pull_requests.d9e3f260"))
                        .font(Theme.title2.weight(.semibold))
                    Text(model.availability?.repositoryName ?? L10n.text("apple.pullsview.review_the_work_around_this_branch.4ca99549"))
                        .font(Theme.callout)
                        .foregroundStyle(.secondary)
                }
                #else
                Text(model.availability?.repositoryName ?? L10n.text("apple.pullsview.review_the_work_around_this_branch.4ca99549"))
                    .font(Theme.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                #endif
                Spacer()
                if model.isLoading && model.availability == nil {
                    ProgressView().controlSize(.small)
                }
                #if !os(macOS)
                if model.availability?.state == "ready" { refreshButton }
                #endif
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
                    title: L10n.text("apple.pullsview.this_folder_is_not_a_git_repository.a1da5b0e"),
                    message: L10n.text("apple.pullsview.pull_requests_appear_for_folders_with_a_gi.33e92947")
                )
            case "noRemote":
                empty(
                    title: L10n.text("apple.pullsview.no_github_origin_yet.0478e3f8"),
                    message: L10n.text("apple.pullsview.add_an_origin_remote_to_this_repository_th.1e168c71")
                )
            case "signedOut":
                connectionCard(availability)
            case "needsInstallation":
                accessCard(
                    availability,
                    title: L10n.text("apple.pullsview.choose_repositories.df6de593"),
                    message: L10n.text("apple.pullsview.you_are_connected_as_0_now_choose_the_repo.e86599a5", "\(availability.login ?? L10n.text("apple.pullsview.your_github_account.abf08edf"))")
                )
            case "noRepositoryAccess":
                accessCard(
                    availability,
                    title: L10n.text("apple.pullsview.grant_this_repository_access.481d9dab"),
                    message: L10n.text("apple.pullsview.the_connection_works_but_0_is_not_in_token.a97dfb79", "\(availability.repositoryName ?? L10n.text("apple.pullsview.this_repository.044fb600"))")
                )
            case "ready":
                pullList(availability)
            default:
                empty(
                    title: L10n.text("apple.pullsview.github_returned_an_unfamiliar_state.c035dfcb"),
                    message: L10n.text("apple.pullsview.refresh_after_updating_tokenstat_on_the_co.3ab687ce")
                )
            }
        } else if model.isLoading {
            PullListSkeleton()
        } else {
            empty(
                title: L10n.text("apple.pullsview.pull_requests_are_unavailable.086a162b"),
                message: L10n.text("apple.pullsview.refresh_to_ask_the_project_s_computer_agai.dc978d57")
            )
        }
    }

    /// Where GitHub keeps the repository selection for tokenstat's app.
    ///
    /// `installUrl` comes back on the states that need it and is absent once a
    /// repository works, which is exactly when somebody wants to add another
    /// one. The fallback is the same address the Account screen uses.
    private var installationURL: URL? {
        if let raw = model.availability?.installUrl, let url = URL(string: raw) {
            return url
        }
        return URL(string: "https://github.com/apps/tokenstat/installations/new")
    }

    private func connectionCard(_ availability: PullAvailability) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            // Centred across the card. Concentric rings around a glyph read as
            // a centred mark wherever else they appear, so left-aligning this
            // one against a column of text looked like a layout mistake.
            ZStack {
                Circle().fill(Theme.accent.opacity(0.08)).frame(width: 104, height: 104)
                Circle().stroke(Theme.accent.opacity(0.18), lineWidth: 1).frame(width: 78, height: 78)
                Image(systemName: "arrow.triangle.merge")
                    .font(Theme.fixed(30, weight: .light))
                    .foregroundStyle(Theme.accent)
            }
            .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(L10n.text("apple.pullsview.bring_the_review_into_tokenstat.124ca7d8"))
                    .font(Theme.title3.weight(.semibold))
                Text(L10n.text("apple.pullsview.read_the_conversation_inspect_the_same_dif.a163d47d"))
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
                    Label(L10n.text("apple.pullsview.connect_github.4027e5b2"), systemImage: "link")
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(model.isConnecting)
            } else {
                Label(
                    L10n.text("apple.pullsview.connect_pull_requests_on_0_then_return_her.c7a8b3e4", "\(connectionHostName ?? L10n.text("apple.pullsview.the_project_s_computer.7e755d17"))"),
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
                    Label(L10n.text("apple.pullsview.choose_repositories.df6de593"), systemImage: "arrow.up.right")
                }
                .buttonStyle(AccentButtonStyle())
            }
            Text(L10n.text("apple.pullsview.tokenstat_only_sees_repositories_selected.e2bbcc73"))
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
                Text("@\(availability.login ?? L10n.text("apple.pullsview.connected.12a7bd86"))")
                    .font(Theme.caption.weight(.medium))
                    .foregroundStyle(.primary)
                Text("· \(sourceLabel(availability.source))")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if !model.rows.isEmpty {
                    Text(L10n.text("apple.pullsview.0_shown.c67ec9a7", "\(model.rows.count)"))
                        .font(Theme.caption)
                        .foregroundStyle(.tertiary)
                }
                // Choosing repositories existed only while the connection was
                // incomplete, and the card offering it disappeared the moment
                // this repository worked. Adding a second one then meant
                // finding a card on the Account screen, which is not where
                // anybody looks for it.
                if canConnectHere, let url = installationURL {
                    Button(L10n.text("apple.pullsview.repositories.1e32af87"), .external) { openURL(url) }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                        .help(L10n.text("apple.pullsview.choose_which_repositories_tokenstat_may_op.7bbe0dd9"))
                }
            }

            PullFilters(scope: $model.scope, state: $model.state)

            HStack(spacing: Theme.Space.s) {
                Text("\(model.state.label) · \(model.scope.label)")
                Spacer()
                if model.isLoadingList {
                    ProgressView().controlSize(.mini)
                    Text(model.rows.isEmpty ? L10n.text("apple.pullsview.loading.ba3bbbe1") : L10n.text("apple.pullsview.updating.dfe40efe"))
                } else {
                    Text(L10n.text("apple.pullsview.0_results.84cbe8d0", "\(model.rows.count)"))
                }
            }
            .font(Theme.caption)
            .foregroundStyle(.secondary)
            .frame(height: 20)

            if let error = model.listError {
                errorCard(error)
            }
            if model.isLoadingList && model.rows.isEmpty {
                PullListSkeleton()
                    .transition(.smoothIn(reduceMotion: reduceMotion))
            } else if model.rows.isEmpty {
                if model.listError == nil {
                    filteredEmpty
                        .transition(.smoothIn(reduceMotion: reduceMotion))
                }
            } else {
                LazyVStack(spacing: Theme.Space.s) {
                    ForEach(model.rows) { pull in
                        Button { selectedPull = pull } label: {
                            PullRow(pull: pull)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(L10n.text("apple.pullsview.opens_pull_request_details.02632c19"))
                    }
                }
                .transition(.smoothIn(reduceMotion: reduceMotion))
            }
        }
    }

    private var filteredEmpty: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            EmptyState(
                symbol: model.state == .draft ? "pencil.line" : "arrow.triangle.merge",
                title: L10n.text("apple.pullsview.no_0_pull_requests.980f0d9c", "\(model.state.label.lowercased())"),
                message: emptyMessage
            )
            if model.scope != .all || model.state != .open {
                Button {
                    withAnimation(.snappy(duration: 0.22)) {
                        model.scope = .all
                        model.state = .open
                    }
                } label: {
                    Label(L10n.text("apple.pullsview.show_open_pull_requests.b5b4db36"), systemImage: "arrow.counterclockwise")
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
        case .all: return L10n.text("apple.pullsview.nothing_in_this_repository_matches_the_sel.402738e9")
        case .mine: return L10n.text("apple.pullsview.you_have_no_pull_requests_matching_the_sel.bdbd95bf")
        case .assigned: return L10n.text("apple.pullsview.no_matching_pull_requests_are_assigned_to.592a8c1b")
        case .reviewRequested: return L10n.text("apple.pullsview.no_matching_pull_requests_are_waiting_for.49ddb44a")
        }
    }

    private func sourceLabel(_ source: String?) -> String {
        switch source {
        case "gitCredential": return L10n.text("apple.pullsview.using_git_s_saved_credential.0e9c75dd")
        case "environment": return L10n.text("apple.pullsview.using_the_shell_credential.f587050a")
        case "pasted": return L10n.text("apple.pullsview.using_a_token_you_supplied.40e06d38")
        default: return L10n.text("apple.pullsview.tokenstat_github_app.4545f151")
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
                Button(L10n.text("apple.pullsview.try_again.d8b8392e")) {
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
            ThemedSheet(
                title: L10n.text("apple.pullsview.connect_github.4027e5b2"),
                subtitle: L10n.text("apple.pullsview.enter_this_one_time_code_in_the_github_pag.2babe0df"),
                icon: .connect,
                onClose: { Task { await model.cancelLogin() } }
            ) {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    Text(login.userCode)
                        .font(Theme.monoText(30, weight: .semibold, relativeTo: .title))
                        .tracking(2)
                        .foregroundStyle(Theme.accent)
                        .textSelection(.enabled)
                        .padding(.horizontal, Theme.Space.l)
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
                        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.cardRadius)
                                .strokeBorder(Theme.accent.opacity(0.3))
                        )
                    HStack(spacing: Theme.Space.s) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Theme.accent)
                        Text(L10n.text("apple.pullsview.waiting_for_github.d3f403f4"))
                            .font(Theme.callout)
                            .foregroundStyle(Theme.controlGlyph)
                    }
                    if let error = model.loginError {
                        Text(FriendlyError.from(error).message)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } actions: {
                Button(L10n.text("common.cancel"), .dismiss) { Task { await model.cancelLogin() } }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
            }
            .modalFrame(width: 540, height: 440)
            .task(id: login.userCode) {
                await model.pollLogin(workspaceID: workspaceID, peer: peer)
            }
            #if !os(macOS)
            .presentationDetents([.medium, .large])
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

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.l) { states; Spacer(minLength: 0); scopePicker }
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                scopePicker
                ScrollView(.horizontal, showsIndicators: false) { states }
            }
        }
        .padding(Theme.Space.m)
        .background(Theme.accent.opacity(0.035), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
    }

    private var states: some View {
        HStack(spacing: Theme.Space.xs) {
            ForEach(PullStateFilter.allCases) { stateButton($0) }
        }
        .fixedSize()
        .accessibilityLabel(L10n.text("apple.pullsview.pull_request_state.45faa7b6"))
    }

    private var scopePicker: some View {
        HStack(spacing: Theme.Space.s) {
            Text(L10n.text("apple.pullsview.show.0df6f1ca")).font(Theme.caption).foregroundStyle(.secondary)
            AppMenuPicker(options: PullScope.allCases.map { (value: $0, label: $0.label) }, selection: $scope)
        }
        .fixedSize()
        .accessibilityLabel(L10n.text("apple.pullsview.pull_request_scope.663baf42"))
    }

    private func stateButton(_ option: PullStateFilter) -> some View {
        let selected = state == option
        let tint = tint(for: option)
        return Button {
            guard !selected else { return }
            state = option
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
            Text(L10n.text("apple.pullsview.0_files.fb42ce4d", "\(pull.changedFiles)")).foregroundStyle(.tertiary)
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
        case "approved": return (L10n.text("apple.pullsview.approved.87b42e40"), "checkmark", Theme.success)
        case "changes_requested": return (L10n.text("apple.pullsview.changes_requested.10a92a8a"), "exclamationmark", Theme.danger)
        case "review_required": return (L10n.text("apple.pullsview.review_needed.eb0807c2"), "eye", Theme.warning)
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
        case .passing: return L10n.text("apple.pullsview.passing.83e6fbae")
        case .failing: return L10n.text("apple.pullsview.failing.3903780c")
        case .pending: return L10n.text("common.running")
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
                        Skeleton.Bar(width: nil, phase: Double(index) * 0.08 + 0.03)
                            .frame(
                                maxWidth: index.isMultiple(of: 2) ? 220 : 170,
                                alignment: .leading
                            )
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
        .accessibilityLabel(L10n.text("apple.pullsview.loading_pull_requests.83ec6f00"))
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
    private var availabilityGeneration = 0
    private struct Query: Hashable {
        let workspace: String
        let peer: String?
        let scope: PullScope
        let state: PullStateFilter
    }
    private var cachedLists: [Query: (rows: [PullSummary], date: Date)] = [:]
    private var owner: String?
    private var ownerPeer: String?

    func load(workspaceID: String, peer: String?, refresh: Bool = false) async {
        availabilityGeneration += 1
        let generation = availabilityGeneration
        if owner != workspaceID || ownerPeer != peer {
            listGeneration += 1
            rows = []
            availability = nil
            cachedLists = [:]
            owner = workspaceID
            ownerPeer = peer
        }
        isLoading = true
        errorMessage = nil
        defer { if generation == availabilityGeneration { isLoading = false } }
        do {
            let loaded = try await Bridge.pullAvailability(workspaceID: workspaceID, peer: peer)
            guard generation == availabilityGeneration, !Task.isCancelled else { return }
            if availability?.login != loaded.login || availability?.repositoryName != loaded.repositoryName {
                listGeneration += 1
                cachedLists = [:]
                rows = []
            }
            availability = loaded
            if availability?.state == "ready" {
                await loadList(workspaceID: workspaceID, peer: peer, refresh: refresh)
            } else {
                listGeneration += 1
                cachedLists = [:]
                rows = []
                isLoadingList = false
            }
        } catch {
            guard generation == availabilityGeneration, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    func loadList(workspaceID: String, peer: String?, refresh: Bool = false) async {
        guard availability?.state == "ready" else { return }
        listGeneration += 1
        let generation = listGeneration
        let requestedScope = scope
        let requestedState = state
        let query = Query(workspace: workspaceID, peer: peer, scope: requestedScope, state: requestedState)
        // Never show one filter's results under another filter's heading.
        rows = cachedLists[query]?.rows ?? []
        if !refresh, let cached = cachedLists[query], Date().timeIntervalSince(cached.date) < 30 {
            isLoadingList = false
            listError = nil
            return
        }
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
            cachedLists[query] = (loaded, Date())
            if cachedLists.count > 8, let oldest = cachedLists.min(by: { $0.value.date < $1.value.date })?.key {
                cachedLists.removeValue(forKey: oldest)
            }
            if requestedScope == .all, requestedState == .open {
                PullCountStore.shared.set(loaded.count, workspaceID: workspaceID, peer: peer)
            }
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
