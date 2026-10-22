// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// How work from this computer's agent reaches the project. The settings
/// stay on this computer, next to the checkout they describe.
struct TeamLaneSettings: View {
    @Bindable var store: TeamStore
    let context: TeamMutationContext
    let checkoutId: String
    @State private var automatic = false
    @State private var target = "main"
    @State private var remote = "origin"
    @State private var check = ""
    @State private var checkAcknowledged = false
    @State private var loaded = false
    @State private var saving = false
    @State private var saved = false
    @State private var error: String?

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
            Picker(L10n.text("common.teams.workflow"), selection: $automatic) {
                Text(L10n.text("common.teams.workflow_manual")).tag(false)
                Text(L10n.text("common.teams.workflow_lanes")).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!loaded || saving)
            Text(automatic ? L10n.text("common.teams.workflow_lanes_detail") : L10n.text("common.teams.workflow_manual_detail"))
                .font(Theme.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if automatic {
                LabeledContent(L10n.text("common.teams.target_branch")) {
                    TextField("main", text: $target).textFieldStyle(ThemedFieldStyle())
                }
                LabeledContent(L10n.text("common.teams.remote")) {
                    TextField("origin", text: $remote).textFieldStyle(ThemedFieldStyle())
                }
                LabeledContent(L10n.text("common.teams.check_command")) {
                    TextField(L10n.text("common.teams.check_command_placeholder"), text: $check).textFieldStyle(ThemedFieldStyle())
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
                if saving { ProgressView().controlSize(.small) }
                if saved { Text(L10n.text("common.teams.workflow_saved")).font(Theme.callout).foregroundStyle(.secondary) }
            }
        }
        .task { await load() }
        .onChange(of: automatic) { saved = false }
        .onChange(of: check) { saved = false; checkAcknowledged = false }
    }

    private func load() async {
        do {
            let result: TeamLaneSettingsResult = try await store.read(.lanesGet, fields: ["checkout": .string(checkoutId)], context: context)
            if let settings = result.settings {
                automatic = settings.enabled; target = settings.target; remote = settings.remote ?? ""
                check = settings.check.joined(separator: " "); checkAcknowledged = settings.checkRunsChangedCode ?? false
            }
            loaded = true
        } catch is CancellationError {} catch { self.error = error.localizedDescription; loaded = true }
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
        ]
        if !trimmedRemote.isEmpty { settings["remote"] = .string(trimmedRemote) }
        do {
            let _: TeamLaneSettingsResult = try await store.perform(.lanesSet, fields: ["checkout": .string(checkoutId), "settings": .object(settings)], context: context)
            saved = true
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}

struct TeamLaneSettingsValue: Codable, Sendable {
    let enabled: Bool; let target: String; let remote: String?; let check: [String]; let checkRunsChangedCode: Bool?
}
struct TeamLaneSettingsResult: Codable, Sendable { let settings: TeamLaneSettingsValue? }
