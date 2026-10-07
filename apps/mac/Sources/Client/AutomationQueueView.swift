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
                ProgressView(L10n.text("apple.automationqueueview.opening_scheduler.b7f091c6"))
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
            title: L10n.text("apple.automationqueueview.scheduler.d3a27d96"),
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
            ProgressView(L10n.text("apple.automationqueueview.saving_scheduler.82aa4bfc"))
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
                Button(L10n.text("apple.automationqueueview.try_again.d8b8392e"), .refresh) { Task { await session.load() } }
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
            return L10n.text("apple.automationqueueview.how_queued_jobs_run_on_the_connected_compu.0d28db88")
        }
        if folder.isEmpty {
            return L10n.text("apple.automationqueueview.how_queued_jobs_run_on_0_this_applies_to_e.09927d15", "\(host)")
        }
        if host.isEmpty {
            return L10n.text("apple.automationqueueview.how_queued_jobs_run_on_the_connected_compu.993795e3", "\(folder)")
        }
        return L10n.text("apple.automationqueueview.how_queued_jobs_run_on_0_not_just_1.a7cb9842", "\(host)", "\(folder)")
    }

    private var timeLimit: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(L10n.text("apple.automationqueueview.time_limit.e592a9ca"))
                .font(ClientType.label.weight(.medium))
            TimeLimitChips(minutesText: $session.draft.budgetMinutes, noLimit: $session.draft.noLimit)
            if !session.draft.noLimit, !session.draft.isBudgetPreset {
                TextField(L10n.text("apple.automationqueueview.minutes.4f846a84"), text: $session.draft.budgetMinutes)
                    .textFieldStyle(.themed)
                    .keyboardType(.numberPad)
                    .accessibilityLabel(L10n.text("apple.automationqueueview.time_limit_in_minutes.e841e686"))
            }
            Text(
                session.draft.noLimit
                    ? L10n.text("apple.automationqueueview.new_jobs_are_not_stopped_by_a_timer_a_job.a97a5725")
                    : L10n.text("apple.automationqueueview.new_jobs_inherit_this_a_job_can_still_set.9e62e04e")
            )
            .font(ClientType.caption)
            .foregroundStyle(Theme.controlGlyph)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var concurrent: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .center, spacing: Theme.Space.s) {
                Text(L10n.text("apple.automationqueueview.jobs_at_once.66276ffd"))
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
                TextField(L10n.text("apple.automationqueueview.jobs_at_once.66276ffd"), text: $session.draft.maxConcurrent)
                    .textFieldStyle(.themed)
                    .keyboardType(.numberPad)
                    .accessibilityLabel(L10n.text("apple.automationqueueview.jobs_at_once.66276ffd"))
            }
            Text(
                (session.draft.concurrent ?? 1) == 0
                    ? L10n.text("apple.automationqueueview.no_limit_on_how_many_jobs_run_together.483e4a96")
                    : L10n.text("apple.automationqueueview.extra_jobs_wait_until_a_place_is_free.862f1074")
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
                return L10n.text("apple.automationqueueview.the_clock_on_the_connected_computer_is_0.12b427b3", "\(place)")
            }
            return L10n.text("apple.automationqueueview.the_clock_on_0_is_1.021f9b37", "\(host)", "\(place)")
        }
        if host.isEmpty {
            return L10n.text("apple.automationqueueview.the_clock_is_on_the_connected_computer_not.eb1dfcf7")
        }
        return L10n.text("apple.automationqueueview.the_clock_is_on_0_not_this_device.730d6f0a", "\(host)")
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.s) {
            if session.dirty {
                Text(L10n.text("apple.automationqueueview.unsaved.6250d572"))
                    .font(ClientType.caption.weight(.medium))
                    .foregroundStyle(Theme.warning)
            } else if justSaved {
                Label(L10n.text("apple.automationqueueview.saved.b5c120b3"), systemImage: "checkmark")
                    .font(ClientType.caption.weight(.medium))
                    .foregroundStyle(Theme.success)
            }
            Spacer(minLength: 0)
            Button(session.working ? L10n.text("apple.automationqueueview.saving.096b7362") : L10n.text("apple.automationqueueview.save_scheduler.24ffd545"), .save) {
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
                    Text(L10n.text("apple.automationqueueview.scheduler.d3a27d96"))
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
        .accessibilityLabel(L10n.text("apple.automationqueueview.scheduler_0_1.64fb806b", "\(summary)", "\(scope)"))
        .accessibilityHint(L10n.text("apple.automationqueueview.opens_how_queued_jobs_run_on_this_computer.7be792c7"))
    }

    private var summary: String {
        guard let queue else {
            return L10n.text("apple.automationqueueview.how_queued_jobs_run_on_this_computer.8038f73a")
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
            if host.isEmpty { return L10n.text("apple.automationqueueview.every_folder.9836340c") }
            return L10n.text("apple.automationqueueview.every_folder_on_0.158c4469", "\(host)")
        }
        if host.isEmpty, folder.isEmpty {
            return L10n.text("apple.automationqueueview.every_folder_on_the_connected_computer.14a3d916")
        }
        if folder.isEmpty {
            return L10n.text("apple.automationqueueview.every_folder_on_0.158c4469", "\(host)")
        }
        if host.isEmpty {
            return L10n.text("apple.automationqueueview.every_folder_not_just_0.0c11b65f", "\(folder)")
        }
        return L10n.text("apple.automationqueueview.on_0_not_just_1.dd74bb64", "\(host)", "\(folder)")
    }
}

struct QueueSheetPresentation: ViewModifier {
    /// From the presenter: inside the sheet the size classes describe the sheet.
    let hasRoom: Bool

    func body(content: Content) -> some View {
        if hasRoom {
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
