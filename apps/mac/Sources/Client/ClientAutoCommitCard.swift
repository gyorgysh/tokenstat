// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if !os(macOS)
import SwiftUI

/// Auto commit on Changes. Distinct from selected-file Commit: the agent
/// inspects the folder and commits. Checkboxes do not choose its files.
struct ClientAutoCommitCard: View {
    @Bindable var session: AutoCommitSession
    var onOpen: (AutoCommitRunRoute) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Auto commit")
                .font(ClientType.label.weight(.semibold))
            Text("The chosen agent inspects this folder and commits. File checkboxes are for Review and commit.")
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Runs on \(session.hostName).")
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
            if session.backends.isEmpty {
                Text("No agent on this computer can write a commit.")
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
            } else {
                pickers
            }
            if let error = session.errorMessage {
                Text(error)
                    .font(ClientType.caption)
                    .foregroundStyle(Theme.danger)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let limitation = session.limitation {
                Text(limitation)
                    .font(ClientType.caption)
                    .foregroundStyle(Theme.controlGlyph)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if session.hasPendingLaunch {
                Text("This start is not confirmed yet. Check it before starting another.")
                    .font(ClientType.caption)
                    .foregroundStyle(Theme.controlGlyph)
            }
            actions
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private var pickers: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: Theme.Space.s) { pickerFields }
            VStack(alignment: .leading, spacing: Theme.Space.s) { pickerFields }
        }
        .disabled(session.working || session.hasPendingLaunch)
    }

    @ViewBuilder
    private var pickerFields: some View {
        AppMenuPicker(
            title: "Agent",
            options: session.backends.map { (value: $0.id, label: $0.label) },
            selection: Binding(
                get: { session.selectedBackend?.id ?? "" },
                set: { session.setBackend($0) }
            )
        )
        if let backend = session.selectedBackend, !backend.models.isEmpty {
            AppMenuPicker(
                title: "Model",
                options: backend.models.map { (value: $0, label: $0) },
                selection: Binding(
                    get: { session.draft.model },
                    set: { session.setModel($0) }
                )
            )
        }
    }

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.s) { actionButtons }
            VStack(alignment: .leading, spacing: Theme.Space.s) { actionButtons }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if session.hasPendingLaunch {
            Button("Check run", .refresh) {
                Task { await session.checkLaunch() }
            }
            .buttonStyle(SecondaryButtonStyle(comfortable: true))
            .disabled(session.working)
            if session.canRetryLaunch {
                Button("Retry run", .run) {
                    Task {
                        await session.retryLaunch()
                        if let route = session.route, session.lastRun != nil || session.job != nil {
                            if !session.hasPendingLaunch { onOpen(route) }
                        }
                    }
                }
                .buttonStyle(AccentButtonStyle(comfortable: true))
                .disabled(session.working)
            }
        } else if session.isRunning, let route = session.route {
            Button("View run", .preview) { onOpen(route) }
                .buttonStyle(AccentButtonStyle(comfortable: true))
        } else {
            Button(session.working ? "Starting…" : "Auto commit", .run) {
                Task {
                    await session.start()
                    if let route = session.route, !session.hasPendingLaunch, session.errorMessage == nil {
                        onOpen(route)
                    }
                }
            }
            .buttonStyle(SecondaryButtonStyle(comfortable: true))
            .disabled(!session.canStart)
            .accessibilityHint("Starts a one-time agent in this folder to commit. File checkboxes are not used.")
        }
    }
}

struct RemoteAutoCommitService: AutoCommitService {
    let peer: String

    func jobs() async throws -> [Automation] {
        try await ClientRemote.automations(peer: peer)
    }
    func runs() async throws -> [RunRecord] {
        try await ClientRemote.automationRuns(peer: peer)
    }
    func backends() async throws -> [AgentBackend] {
        try await ClientRemote.automationBackends(peer: peer)
    }
    func supportsReceipts() async -> Bool {
        await RemoteHostFeature.automationReceipts.isSupported(peer: peer)
    }
    func create(_ job: Automation) async throws -> Automation {
        try await ClientRemote.createAutomation(peer: peer, job: job)
    }
    func update(_ job: Automation) async throws -> Automation {
        try await ClientRemote.updateAutomation(peer: peer, job: job)
    }
    func edit(_ job: Automation, revision: UInt64) async throws -> Automation {
        try await ClientRemote.editAutomation(peer: peer, job: job, revision: revision)
    }
    func run(_ id: String) async throws -> Automation {
        try await ClientRemote.runAutomation(peer: peer, id: id)
    }
    func runOnce(id: String, operationID: String) async throws -> AutomationRunOutcome {
        try await ClientRemote.runAutomationOnce(peer: peer, id: id, operationID: operationID)
    }
    func runReceipt(operationID: String) async throws -> AutomationRunOutcome? {
        try await ClientRemote.automationRunReceipt(peer: peer, operationID: operationID)
    }
}
#endif
