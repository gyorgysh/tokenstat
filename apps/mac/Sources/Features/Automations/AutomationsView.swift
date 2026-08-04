// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

import SwiftUI

struct AutomationsView: View {
    @Bindable var model: AutomationsModel
    @State private var name = ""
    @State private var command = ""
    @State private var interval = "3600"
    @State private var budget = "900"
    @State private var workspaceID = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if let error = model.errorMessage { Banner(text: error, severity: .warning) }
                if let notice = model.noticeMessage { Banner(text: notice, severity: .success) }
                if model.jobs.isEmpty {
                    Text("No automations yet. Create one below.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.jobs) { job in
                        jobRow(job)
                    }
                }
                createCard
                Text("Automations run on this machine. Each run owns a host PTY and is killed when its budget expires.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(Theme.Space.m)
        }
        .navigationTitle("Automations")
        .task { await model.load() }
    }

    private func jobRow(_ job: Automation) -> some View {
        Card(title: job.name, subtitle: "Every \(job.intervalSeconds)s, budget \(job.budgetSeconds)s") {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Label(job.command, systemImage: "terminal")
                    .font(Theme.mono(12)).lineLimit(1)
                Text(model.folders.first { $0.id == job.workspaceID }?.name ?? job.workspaceID)
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Toggle("Enabled", isOn: Binding(get: { job.enabled }, set: { _ in Task { await model.toggle(job) } }))
                        .toggleStyle(.switch)
                    Spacer()
                    Button("Run now") { Task { await model.run(job) } }
                        .buttonStyle(.borderedProminent)
                    Button(role: .destructive) { Task { await model.remove(job) } } label: {
                        Image(systemName: "trash")
                    }
                }
                if let last = job.lastRun { Text("Last run \(last.formatted())").font(.caption).foregroundStyle(.tertiary) }
            }
        }
    }

    private var createCard: some View {
        Card(title: "New automation", subtitle: "The daemon stores this definition and runs it while the app is closed.") {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                TextField("Name", text: $name)
                TextField("Command", text: $command)
                Picker("Workspace", selection: $workspaceID) {
                    Text("Choose a workspace").tag("")
                    ForEach(model.folders) { folder in Text(folder.name).tag(folder.id) }
                }
                HStack {
                    TextField("Interval (seconds)", text: $interval)
                    TextField("Budget (seconds)", text: $budget)
                }
                HStack {
                    Spacer()
                    Button("Create") {
                        Task {
                            await model.create(name: name, workspaceID: workspaceID, command: command,
                                               interval: UInt64(interval) ?? 0, budget: UInt64(budget) ?? 0)
                            name = ""; command = ""
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || command.isEmpty || workspaceID.isEmpty)
                }
            }
            .textFieldStyle(.roundedBorder)
        }
    }
}
