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
            Text(L10n.text("apple.clientautocommitcard.auto_commit.2559934f"))
                .font(ClientType.label.weight(.semibold))
            Text(L10n.text("apple.clientautocommitcard.the_chosen_agent_inspects_this_folder_and.05747a66"))
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.text("apple.clientautocommitcard.runs_on_0.6b563ff8", "\(session.hostName)"))
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
            if session.backends.isEmpty {
                Text(L10n.text("apple.clientautocommitcard.no_agent_on_this_computer_can_write_a_comm.9b85195e"))
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
                Text(L10n.text("apple.clientautocommitcard.this_start_is_not_confirmed_yet_check_it_b.086397b5"))
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
            title: L10n.text("apple.clientautocommitcard.agent.11b39c93"),
            options: session.backends.map { (value: $0.id, label: $0.label) },
            selection: Binding(
                get: { session.selectedBackend?.id ?? "" },
                set: { session.setBackend($0) }
            )
        )
        if let backend = session.selectedBackend, !backend.models.isEmpty {
            AppMenuPicker(
                title: L10n.text("apple.clientautocommitcard.model.5e2c614c"),
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
            Button(L10n.text("apple.clientautocommitcard.check_run.cece2401"), .refresh) {
                Task { await session.checkLaunch() }
            }
            .buttonStyle(SecondaryButtonStyle(comfortable: true))
            .disabled(session.working)
            if session.canRetryLaunch {
                Button(L10n.text("apple.clientautocommitcard.retry_run.2f9c439b"), .run) {
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
            Button(L10n.text("apple.clientautocommitcard.view_run.aaf7fccc"), .preview) { onOpen(route) }
                .buttonStyle(AccentButtonStyle(comfortable: true))
        } else {
            Button(session.working ? L10n.text("apple.clientautocommitcard.starting.bbe5fc3b") : L10n.text("apple.clientautocommitcard.auto_commit.2559934f"), .run) {
                Task {
                    await session.start()
                    if let route = session.route, !session.hasPendingLaunch, session.errorMessage == nil {
                        onOpen(route)
                    }
                }
            }
            .buttonStyle(SecondaryButtonStyle(comfortable: true))
            .disabled(!session.canStart)
            .accessibilityHint(L10n.text("apple.clientautocommitcard.starts_a_one_time_agent_in_this_folder_to.db051163"))
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
