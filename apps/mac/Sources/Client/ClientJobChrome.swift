// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI

/// A labelled fact on a job or graph. Same shape on phone and iPad.
struct ClientFactRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(ClientType.caption)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(ClientType.label)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Prompt field plus Run / Stop / Continue, with confirms that name the machine.
struct ClientWorkflowActions: View {
    @Bindable var session: ClientWorkflowSession
    var showsPrompt: Bool = true

    @State private var pending: Pending?

    private enum Pending: Identifiable {
        case run
        case stop
        case continueGate

        var id: String {
            switch self {
            case .run: return "run"
            case .stop: return "stop"
            case .continueGate: return "continue"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if showsPrompt, session.liveRun == nil {
                TextField("Starting prompt", text: $session.input, axis: .vertical)
                    .font(ClientType.body)
                    .lineLimit(3...8)
                    .padding(Theme.Space.s)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.cardRadius)
                            .strokeBorder(Theme.border, lineWidth: 1)
                    )
            }
            HStack(spacing: Theme.Space.s) {
                if let run = session.liveRun {
                    if run.isWaiting {
                        Button(session.working ? "Working" : "Continue", .next) {
                            pending = .continueGate
                        }
                        .clientProminentStyle()
                        .disabled(session.working)
                    }
                    Button("Stop", .stop) { pending = .stop }
                        .clientGlassStyle()
                        .disabled(session.working)
                } else {
                    Button(session.working ? "Starting" : "Run", .run) { pending = .run }
                        .clientProminentStyle()
                        .disabled(session.working || session.selectedGraph == nil)
                }
                if let graph = session.selectedGraph, graph.schedule.repeats {
                    BrandToggleChip(
                        title: graph.enabled ? "On" : "Off",
                        isOn: Binding(
                            get: { graph.enabled },
                            set: { _ in Task { await session.toggleSchedule() } }
                        )
                    )
                    .accessibilityLabel("Enabled")
                }
            }
        }
        .confirmationDialog(confirmTitle, isPresented: confirmPresented, titleVisibility: .visible) {
            switch pending {
            case .run:
                Button("Run") { Task { await session.run() } }
                Button("Cancel", role: .cancel) { pending = nil }
            case .stop:
                Button("Stop", role: .destructive) { Task { await session.stop() } }
                Button("Keep it", role: .cancel) { pending = nil }
            case .continueGate:
                Button("Continue") { Task { await session.continueGate() } }
                Button("Cancel", role: .cancel) { pending = nil }
            case nil:
                Button("Cancel", role: .cancel) { pending = nil }
            }
        } message: {
            Text(confirmMessage)
        }
        .onChange(of: session.working) { _, working in
            if !working { pending = nil }
        }
    }

    private var confirmPresented: Binding<Bool> {
        Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })
    }

    private var confirmTitle: String {
        let name = session.selectedGraph?.name ?? "this workflow"
        switch pending {
        case .run: return "Run \(name)?"
        case .stop: return "Stop \(name)?"
        case .continueGate: return "Continue \(name)?"
        case nil: return "Confirm"
        }
    }

    private var confirmMessage: String {
        let name = session.selectedGraph?.name ?? "this workflow"
        switch pending {
        case .run:
            return ClientJobCopy.run(name, folder: session.folderName, host: session.hostName)
        case .stop:
            return ClientJobCopy.stop(name, host: session.hostName)
        case .continueGate:
            return ClientJobCopy.continueGate(name, host: session.hostName)
        case nil:
            return ""
        }
    }
}

/// Run now / Stop / pause, with the same confirms as workflows.
struct ClientAutomationActions: View {
    @Bindable var session: ClientAutomationSession

    @State private var pending: Pending?

    private enum Pending: Identifiable {
        case run
        case stop

        var id: String {
            switch self {
            case .run: return "run"
            case .stop: return "stop"
            }
        }
    }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            if session.liveRun != nil {
                Button("Stop", .stop) { pending = .stop }
                    .clientGlassStyle()
                    .disabled(session.working)
            } else {
                Button(session.working ? "Starting" : "Run now", .run) { pending = .run }
                    .clientProminentStyle()
                    .disabled(session.working || session.selectedJob == nil)
            }
            if let job = session.selectedJob {
                BrandToggleChip(
                    title: job.enabled ? "On" : "Off",
                    isOn: Binding(
                        get: { job.enabled },
                        set: { _ in Task { await session.toggleSchedule() } }
                    )
                )
                .accessibilityLabel("Enabled")
            }
        }
        .confirmationDialog(confirmTitle, isPresented: confirmPresented, titleVisibility: .visible) {
            switch pending {
            case .run:
                Button("Run") { Task { await session.run() } }
                Button("Cancel", role: .cancel) { pending = nil }
            case .stop:
                Button("Stop", role: .destructive) { Task { await session.stop() } }
                Button("Keep it", role: .cancel) { pending = nil }
            case nil:
                Button("Cancel", role: .cancel) { pending = nil }
            }
        } message: {
            Text(confirmMessage)
        }
        .onChange(of: session.working) { _, working in
            if !working { pending = nil }
        }
    }

    private var confirmPresented: Binding<Bool> {
        Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })
    }

    private var confirmTitle: String {
        let name = session.selectedJob?.name ?? "this job"
        switch pending {
        case .run: return "Run \(name)?"
        case .stop: return "Stop \(name)?"
        case nil: return "Confirm"
        }
    }

    private var confirmMessage: String {
        let name = session.selectedJob?.name ?? "this job"
        switch pending {
        case .run:
            return ClientJobCopy.run(name, folder: session.folderName, host: session.hostName)
        case .stop:
            return ClientJobCopy.stop(name, host: session.hostName)
        case nil:
            return ""
        }
    }
}

/// One past run as a row. Used on the phone list and the iPad column.
struct ClientPastRunRow: View {
    let title: String
    let status: String
    let label: String
    let started: Date

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Circle()
                .fill(RunOutcome.tint(status))
                .frame(width: 8, height: 8)
            Text(title)
                .font(ClientType.label.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 0)
            StatusPill(status: status, text: label)
            Text(started.formatted(date: .omitted, time: .shortened))
                .font(ClientType.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, minHeight: 44)
        .cardSurface()
        .contentShape(.rect)
    }
}

#endif
