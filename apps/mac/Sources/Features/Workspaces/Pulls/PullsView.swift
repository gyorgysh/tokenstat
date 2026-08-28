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
    @State private var model = PullsModel()

    private var canConnectHere: Bool { connectionHostName == nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                heading
                content
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(Theme.Space.xl)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Theme.background)
        .task(id: workspaceID) { await model.load(workspaceID: workspaceID, peer: peer) }
        .refreshable { await model.load(workspaceID: workspaceID, peer: peer) }
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
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 34, height: 34)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pull requests")
                        .font(.title2.weight(.semibold))
                    Text(model.availability?.repositoryName ?? "Review the work around this branch")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isLoading {
                    ProgressView().controlSize(.small)
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
                readyCard(availability)
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
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Theme.accent)
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Bring the review into tokenstat")
                    .font(.title3.weight(.semibold))
                Text("Read the conversation, inspect the same diff as Changes, follow checks, and review without losing the workspace around it.")
                    .font(.body)
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
                .font(.callout)
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
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.accent)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
            if let raw = availability.installUrl, let url = URL(string: raw) {
                Button { openURL(url) } label: {
                    Label("Choose repositories", systemImage: "arrow.up.right")
                }
                .buttonStyle(AccentButtonStyle())
            }
            Text("tokenstat only sees repositories selected for its GitHub App installation.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.accent.opacity(0.24)))
    }

    private func readyCard(_ availability: PullAvailability) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.panel)
                    .frame(width: 30, height: 30)
                    .background(Theme.success, in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("Connected to \(availability.repositoryName ?? "GitHub")")
                        .font(.headline)
                    Text("@\(availability.login ?? "connected") · \(sourceLabel(availability.source))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Divider().overlay(Theme.border)
            Text("The connection is ready. Pull-request lists and review details use this repository grant and stay between this computer and GitHub.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
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
                    .font(.callout)
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
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(Theme.accent)
                }
                VStack(spacing: Theme.Space.xs) {
                    Text("Connect GitHub")
                        .font(.title2.weight(.semibold))
                    Text("Enter this one-time code in the GitHub page that just opened.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Text(login.userCode)
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
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
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let error = model.loginError {
                    Text(FriendlyError.from(error).message)
                        .font(.caption)
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

@MainActor
@Observable
private final class PullsModel {
    var availability: PullAvailability?
    var login: PullDeviceLogin?
    var isLoading = false
    var isConnecting = false
    var errorMessage: String?
    var loginError: String?

    func load(workspaceID: String, peer: String?) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            availability = try await Bridge.pullAvailability(workspaceID: workspaceID, peer: peer)
        } catch {
            errorMessage = error.localizedDescription
        }
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
