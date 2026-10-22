// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// How work from this computer's agent reaches the project. The settings
/// stay on this computer, next to the checkout they describe.
struct TeamLaneSettings: View {
    @Bindable var store: TeamStore
    let context: TeamMutationContext
    let checkoutId: String
    private enum Mode: Hashable { case manual, review, automatic }
    @State private var mode: Mode = .manual
    private var automatic: Bool { mode != .manual }
    @State private var target = "main"
    @State private var remote = "origin"
    @State private var check = ""
    @State private var checkAcknowledged = false
    @State private var pullRequest = false
    @State private var loaded = false
    @State private var saving = false
    @State private var saved = false
    @State private var error: String?
    @State private var catchUp: String?
    @State private var retrying = false

    private var checkArguments: [String] {
        check.split(whereSeparator: \.isWhitespace).map(String.init)
    }
    private var valid: Bool {
        !target.trimmingCharacters(in: .whitespaces).isEmpty && (checkArguments.isEmpty || checkAcknowledged)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(L10n.text("common.teams.workflow")).font(Theme.headline)
            if let error { TeamNotice(message: error, warning: true) }
            if let catchUp {
                TeamNotice(message: catchUp, warning: true)
                Button(L10n.text("common.teams.catch_up_again"), .refresh) { Task { await retry() } }
                    .buttonStyle(TeamButtonStyle()).disabled(retrying)
            }
            Picker(L10n.text("common.teams.workflow"), selection: $mode) {
                Text(L10n.text("common.teams.workflow_manual")).tag(Mode.manual)
                Text(L10n.text("common.teams.workflow_review")).tag(Mode.review)
                Text(L10n.text("common.teams.workflow_lanes")).tag(Mode.automatic)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!loaded || saving)
            Text(mode == .automatic ? L10n.text("common.teams.workflow_lanes_detail")
                : mode == .review ? L10n.text("common.teams.workflow_review_detail")
                : L10n.text("common.teams.workflow_manual_detail"))
                .font(Theme.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if automatic {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(L10n.text("common.teams.target_branch")).font(Theme.callout.weight(.semibold))
                    TextField("main", text: $target).textFieldStyle(ThemedFieldStyle())
                        .accessibilityLabel(L10n.text("common.teams.target_branch"))
                }
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(L10n.text("common.teams.remote")).font(Theme.callout.weight(.semibold))
                    TextField("origin", text: $remote).textFieldStyle(ThemedFieldStyle())
                        .accessibilityLabel(L10n.text("common.teams.remote"))
                }
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(L10n.text("common.teams.check_command")).font(Theme.callout.weight(.semibold))
                    TextField(L10n.text("common.teams.check_command_placeholder"), text: $check).textFieldStyle(ThemedFieldStyle())
                        .accessibilityLabel(L10n.text("common.teams.check_command"))
                }
                if mode == .review {
                    Toggle(L10n.text("common.teams.open_pull_request"), isOn: $pullRequest).toggleStyle(.checkboxForTeam)
                    if pullRequest {
                        Text(L10n.text("common.teams.open_pull_request_detail")).font(Theme.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !checkArguments.isEmpty {
                    TeamNotice(message: L10n.text("common.teams.check_warning"), warning: true)
                    Toggle(L10n.text("common.teams.check_confirm"), isOn: $checkAcknowledged).toggleStyle(.checkboxForTeam)
                }
            }
            HStack(spacing: Theme.Space.s) {
                Button(L10n.text("common.save"), .save) { Task { await save() } }
                    .buttonStyle(TeamButtonStyle(primary: true))
                    .disabled(!loaded || saving || !valid)
                if saving { ProgressView().controlSize(.small).accessibilityLabel(L10n.text("common.loading")) }
                if saved { Text(L10n.text("common.teams.workflow_saved")).font(Theme.callout).foregroundStyle(.secondary) }
            }
        }
        .task { await load() }
        .onChange(of: mode) { saved = false }
        .onChange(of: pullRequest) { saved = false }
        .onChange(of: check) { saved = false; checkAcknowledged = false }
    }

    private func load() async {
        do {
            let result: TeamLaneSettingsResult = try await store.read(.lanesGet, fields: ["checkout": .string(checkoutId)], context: context)
            catchUp = result.catchUp
            if let settings = result.settings {
                mode = !settings.enabled ? .manual : settings.review == true ? .review : .automatic
                target = settings.target; remote = settings.remote ?? ""; pullRequest = settings.pullRequest ?? false
                check = settings.check.joined(separator: " "); checkAcknowledged = settings.checkRunsChangedCode ?? false
            }
            loaded = true
        } catch is CancellationError {} catch { self.error = error.localizedDescription; loaded = true }
    }

    private func retry() async {
        guard !retrying else { return }
        retrying = true; defer { retrying = false }
        do {
            let result: TeamLaneSettingsResult = try await store.perform(.lanesCatchUp, fields: ["checkout": .string(checkoutId)], context: context)
            catchUp = result.catchUp
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    private func save() async {
        guard valid, !saving else { return }
        saving = true; error = nil; saved = false
        defer { saving = false }
        let trimmedRemote = remote.trimmingCharacters(in: .whitespaces)
        var settings: [String: JSONValue] = [
            "enabled": .bool(automatic),
            "target": .string(target.trimmingCharacters(in: .whitespaces)),
            "check": .array(checkArguments.map(JSONValue.string)),
            "checkRunsChangedCode": .bool(checkAcknowledged && !checkArguments.isEmpty),
            "review": .bool(mode == .review),
            "pullRequest": .bool(mode == .review && pullRequest),
        ]
        if !trimmedRemote.isEmpty { settings["remote"] = .string(trimmedRemote) }
        do {
            let _: TeamLaneSettingsResult = try await store.perform(.lanesSet, fields: ["checkout": .string(checkoutId), "settings": .object(settings)], context: context)
            saved = true
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}

struct TeamLaneSettingsValue: Codable, Sendable {
    let enabled: Bool; let target: String; let remote: String?; let check: [String]; let checkRunsChangedCode: Bool?; let review: Bool?; let pullRequest: Bool?
}
struct TeamLaneSettingsResult: Codable, Sendable { let settings: TeamLaneSettingsValue?; var catchUp: String? = nil }
