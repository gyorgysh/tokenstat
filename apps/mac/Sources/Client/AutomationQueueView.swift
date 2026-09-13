// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI

/// Host-wide scheduler defaults. Opened from the automations library, never
/// from a job editor, so it cannot look like a folder setting.
struct AutomationQueueDestination: View {
    let peer: String
    let hostName: String
    let folderName: String
    var service: any AutomationQueueService
    var onFinished: () async -> Void = {}
    @State private var session: AutomationQueueSession?

    var body: some View {
        Group {
            if let session {
                AutomationQueueView(
                    session: session,
                    hostName: hostName,
                    folderName: folderName,
                    onFinished: onFinished
                )
            } else {
                ProgressView("Opening scheduler")
                    .font(Theme.callout)
            }
        }
        .task {
            let next = AutomationQueueSessions.session(
                peer: peer,
                hostName: hostName,
                service: service
            )
            session = next
            await next.load()
        }
    }
}

struct AutomationQueueView: View {
    @Bindable var session: AutomationQueueSession
    let hostName: String
    let folderName: String
    var onFinished: () async -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var justSaved = false

    var body: some View {
        ThemedSheet(
            title: "Scheduler",
            subtitle: hostName,
            icon: .settings,
            scrolls: true,
            onClose: { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                notices
                if session.queue != nil {
                    scope
                    timeLimit
                    concurrent
                    clock
                }
            }
            .padding(.bottom, Theme.Space.xl)
        } actions: {
            footer
        }
        .interactiveDismissDisabled(session.working)
        .onChange(of: session.draft) { _, _ in
            justSaved = false
        }
    }

    @ViewBuilder private var notices: some View {
        if session.working {
            ProgressView("Saving scheduler")
                .font(Theme.callout)
        }
        if let message = session.noticeMessage, !session.dirty {
            Text(message)
                .font(Theme.callout)
                .foregroundStyle(Theme.controlGlyph)
        }
        if let message = session.errorMessage {
            Text(ClientTunnelCopy.display(message, host: hostName))
                .font(Theme.callout)
                .foregroundStyle(Theme.danger)
                .textSelection(.enabled)
            if session.queue == nil {
                Button("Try again", .refresh) { Task { await session.load() } }
                    .buttonStyle(SecondaryButtonStyle(comfortable: true))
                    .disabled(session.working)
            }
        }
        if let validation = session.draft.validation, session.dirty {
            Text(validation)
                .font(Theme.callout)
                .foregroundStyle(Theme.danger)
        }
    }

    private var scope: some View {
        Text(scopeCopy)
            .font(ClientType.body)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var scopeCopy: String {
        let host = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.isEmpty, folder.isEmpty {
            return "How queued jobs run on the connected computer. This applies to every folder."
        }
        if folder.isEmpty {
            return "How queued jobs run on \(host). This applies to every folder."
        }
        if host.isEmpty {
            return "How queued jobs run on the connected computer, not just \(folder)."
        }
        return "How queued jobs run on \(host), not just \(folder)."
    }

    private var timeLimit: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Time limit")
                .font(ClientType.label.weight(.medium))
            TimeLimitChips(minutesText: $session.draft.budgetMinutes, noLimit: $session.draft.noLimit)
            if !session.draft.noLimit, !session.draft.isBudgetPreset {
                TextField("Minutes", text: $session.draft.budgetMinutes)
                    .textFieldStyle(.themed)
                    .keyboardType(.numberPad)
                    .accessibilityLabel("Time limit in minutes")
            }
            Text(
                session.draft.noLimit
                    ? "New jobs are not stopped by a timer. A job can still set its own."
                    : "New jobs inherit this. A job can still set its own."
            )
            .font(ClientType.caption)
            .foregroundStyle(Theme.controlGlyph)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var concurrent: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .center, spacing: Theme.Space.s) {
                Text("Jobs at once")
                    .font(ClientType.label.weight(.medium))
                Spacer(minLength: 0)
                SlotGauge(
                    filled: session.runningCount,
                    total: Int(session.draft.concurrent ?? 0),
                    uncapped: (session.draft.concurrent ?? 1) == 0,
                    tile: 12
                )
            }
            ConcurrentChips(countText: $session.draft.maxConcurrent)
            if !session.draft.isConcurrentPreset {
                TextField("Jobs at once", text: $session.draft.maxConcurrent)
                    .textFieldStyle(.themed)
                    .keyboardType(.numberPad)
                    .accessibilityLabel("Jobs at once")
            }
            Text(
                (session.draft.concurrent ?? 1) == 0
                    ? "No limit on how many jobs run together."
                    : "Extra jobs wait until a place is free."
            )
            .font(ClientType.caption)
            .foregroundStyle(Theme.controlGlyph)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var clock: some View {
        Text(clockCopy)
            .font(ClientType.caption)
            .foregroundStyle(Theme.controlGlyph)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var clockCopy: String {
        let host = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = HostScheduleClock.place(session.timezone)
        if let place {
            if host.isEmpty {
                return "The clock on the connected computer is \(place)."
            }
            return "The clock on \(host) is \(place)."
        }
        if host.isEmpty {
            return "The clock is on the connected computer, not this device."
        }
        return "The clock is on \(host), not this device."
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.s) {
            if session.dirty {
                Text("Unsaved")
                    .font(ClientType.caption.weight(.medium))
                    .foregroundStyle(Theme.warning)
            } else if justSaved {
                Label("Saved", systemImage: "checkmark")
                    .font(ClientType.caption.weight(.medium))
                    .foregroundStyle(Theme.success)
            }
            Spacer(minLength: 0)
            Button(session.working ? "Saving" : "Save scheduler", .save) {
                Task {
                    await session.save()
                    if session.errorMessage == nil, !session.dirty {
                        justSaved = true
                        await onFinished()
                    }
                }
            }
            .buttonStyle(AccentButtonStyle(comfortable: true))
            .disabled(!session.canSave)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Library row for host-wide scheduler defaults. The list may be one folder.
/// The copy must not be.
struct ClientSchedulerCard: View {
    let hostName: String
    let folderName: String
    let queue: AutomationQueue?
    var showsChevron: Bool = true
    /// Narrow list columns cannot hold the phone's "not just this folder" line.
    var compactCopy: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: Theme.Space.s) {
                FeatureMark(name: "mark_scheduler", tint: Theme.accent, size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Scheduler")
                        .font(ClientType.label.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(summary)
                        .font(ClientType.caption)
                        .foregroundStyle(Theme.controlGlyph)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(scope)
                        .font(ClientType.caption)
                        .foregroundStyle(Theme.controlGlyph)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(Theme.caption.weight(.semibold))
                        .foregroundStyle(Theme.controlGlyph)
                }
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(Theme.border, lineWidth: 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Scheduler, \(summary), \(scope)")
        .accessibilityHint("Opens how queued jobs run on this computer")
    }

    private var summary: String {
        guard let queue else {
            return "How queued jobs run on this computer"
        }
        return AutomationQueueDraft.summary(
            budgetSeconds: queue.defaultBudgetSeconds,
            maxConcurrent: queue.maxConcurrent
        )
    }

    private var scope: String {
        let host = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        if compactCopy {
            if host.isEmpty { return "Every folder" }
            return "Every folder on \(host)"
        }
        if host.isEmpty, folder.isEmpty {
            return "Every folder on the connected computer"
        }
        if folder.isEmpty {
            return "Every folder on \(host)"
        }
        if host.isEmpty {
            return "Every folder, not just \(folder)"
        }
        return "On \(host), not just \(folder)"
    }
}

struct QueueSheetPresentation: ViewModifier {
    func body(content: Content) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            // iPad keeps the default form sheet. Detents would turn it into a
            // full-window card, which is how the dedicated fixture looked empty.
            content.presentationDragIndicator(.visible)
        } else {
            // Medium clips the host-clock line above the footer. 540 leaves
            // that caption and Save on screen together; large is still there.
            content
                .presentationDetents([.height(540), .large])
                .presentationDragIndicator(.visible)
        }
    }
}
#endif
