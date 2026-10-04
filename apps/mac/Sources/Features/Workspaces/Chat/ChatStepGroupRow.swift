// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// A header standing in for folded transcript steps, with a few recent
/// actions visible while Compact work runs. Tapping anywhere shows the
/// steps below it as rows of their own, and tapping again folds them away.
///
/// Shared by the Mac and the phone. The whole line is the control: it is
/// one short row, and a separate Show button on it would be a smaller
/// target saying the same thing.
struct ChatStepGroupRow: View {
    let group: ChatStepGroup
    /// Whether this row carries the transcript's spinner. See
    /// `TranscriptFollow.spinningRow`.
    var animatesRunning = true
    let toggle: () -> Void

    #if os(macOS)
    private static let titleFont = Theme.font(13, weight: .medium)
    private static let metaFont = Theme.mono(11)
    #else
    private static let titleFont = ClientType.label.weight(.medium)
    private static let metaFont = ClientType.caption
    #endif

    var body: some View {
        if group.minimal {
            minimalLine
        } else {
            standardRow
        }
    }

    /// Minimal: the verb, what it acted on and the lines it changed, in one
    /// quiet line. The spinner stands in front while the step runs.
    private var minimalLine: some View {
        Button(action: toggle) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if group.running, animatesRunning {
                    ProgressView()
                        .controlSize(.mini)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                }
                Text(title)
                    .font(Self.titleFont)
                    .foregroundStyle(group.running ? Theme.accent : .secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let meta = minimalSubject, !meta.isEmpty {
                    Text(meta)
                        .font(Self.titleFont.weight(.regular))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if group.added + group.removed > 0 {
                    DiffStat(added: Int(group.added), removed: Int(group.removed), font: Self.titleFont.weight(.regular))
                        .fixedSize()
                }
                Spacer(minLength: 0)
                if group.open {
                    Image(systemName: "chevron.down")
                        .font(Theme.font(9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 3)
            .padding(.horizontal, Theme.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            #if !os(macOS)
            .frame(minHeight: 36)
            #endif
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility)
        .accessibilityHint(group.open ? L10n.text("apple.chatdetail.hide_steps") : L10n.text("apple.chatdetail.show_steps"))
        .accessibilityAddTraits(.isButton)
    }

    /// The file or command after the verb, or the counts for a run of
    /// several reads and searches.
    private var minimalSubject: String? {
        switch group.style {
        case .step, .explored:
            if group.memberIDs.count == 1, let subject = group.subject {
                return Self.shortSubject(verb: group.verb, subject)
            }
            return summary
        case .thought:
            return group.preview
        case .work:
            return summary
        }
    }

    /// A path becomes its file name. A command keeps its first line.
    static func shortSubject(verb: String?, _ subject: String) -> String {
        let line = String(subject.prefix(while: { !$0.isNewline }))
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        switch verb {
        case "Read", "Edit", "NotebookEdit", "Write", "Diff":
            let name = (trimmed as NSString).lastPathComponent
            return name.isEmpty ? trimmed : name
        default:
            return String(trimmed.prefix(160))
        }
    }

    private var standardRow: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                header
                ForEach(group.activityPreview) { activity in
                    HStack(spacing: Theme.Space.s) {
                        Image(systemName: activity.running ? "arrow.right" : "checkmark")
                            .font(Theme.font(10, weight: .medium))
                            .frame(width: 16)
                        Text(SeatStep.word(verb: activity.verb, running: activity.running))
                            .font(Self.titleFont)
                            .lineLimit(1)
                            .layoutPriority(1)
                        if !activity.target.isEmpty {
                            Text(activity.target)
                                .font(Self.metaFont)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(activity.running ? Theme.accent : .secondary)
                    .padding(.leading, 12 + Theme.Space.s)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, Theme.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            #if !os(macOS)
            .frame(minHeight: 44)
            #endif
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility)
        .accessibilityHint(group.open ? L10n.text("apple.chatdetail.hide_steps") : L10n.text("apple.chatdetail.show_steps"))
        .accessibilityAddTraits(.isButton)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Space.s) {
            Image(systemName: "chevron.right")
                .font(Theme.font(10, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(group.open ? 90 : 0))
                .frame(width: 12)
            Group {
                if group.running, animatesRunning {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: symbol)
                        .font(Theme.font(12, weight: .medium))
                }
            }
            .foregroundStyle(group.running ? Theme.accent : .secondary)
            .frame(width: 16)
            Text(title)
                .font(Self.titleFont)
                .foregroundStyle(group.running ? Theme.accent : .primary)
                .lineLimit(1)
                .layoutPriority(1)
            if let meta = summary, !meta.isEmpty {
                Text(meta)
                    .font(Self.metaFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if group.added + group.removed > 0 {
                DiffStat(added: Int(group.added), removed: Int(group.removed), font: Self.metaFont)
                    .fixedSize()
            }
            if let cost = group.cost, cost > 0 {
                Text(cost, format: .currency(code: "USD").precision(.fractionLength(2...4)))
                    .font(Self.metaFont)
                    .foregroundStyle(Theme.accent)
                    .fixedSize()
            }
        }
    }

    private var symbol: String {
        switch group.style {
        case .work: "list.bullet"
        case .explored: "magnifyingglass"
        case .thought: "brain"
        case .step: "chevron.right.2"
        }
    }

    /// What the line is, in a few words. A running line names the step.
    private var title: String {
        switch group.style {
        case .work:
            if group.running {
                if let verb = group.liveVerb { return SeatStep.phrase(verb: verb, target: group.liveTarget) }
                return L10n.text("common.working")
            }
            if let duration { return L10n.text("apple.chatdetail.worked_for", duration) }
            return L10n.text("apple.chatdetail.worked")
        case .explored:
            return group.running ? L10n.text("apple.chatdetail.exploring") : L10n.text("apple.chatdetail.explored")
        case .thought:
            return L10n.text("apple.chatdetail.thought")
        case .step:
            return SeatStep.word(verb: group.verb, running: group.running)
        }
    }

    /// The counts after the title: steps and files for work, what was looked
    /// at for a run of reads, the first line for a thought.
    private var summary: String? {
        switch group.style {
        case .work:
            var parts = [group.steps == 1 ? L10n.text("apple.chatdetail.steps.one", "1") : L10n.text("apple.chatdetail.steps.other", "\(group.steps)")]
            if group.files > 0 { parts.append(group.files == 1 ? L10n.text("apple.chatdetail.files_edited.one", "1") : L10n.text("apple.chatdetail.files_edited.other", "\(group.files)")) }
            return parts.joined(separator: " · ")
        case .explored:
            var parts: [String] = []
            if group.reads > 0 { parts.append(group.reads == 1 ? L10n.text("apple.chatdetail.files.one", "1") : L10n.text("apple.chatdetail.files.other", "\(group.reads)")) }
            if group.searches > 0 { parts.append(group.searches == 1 ? L10n.text("apple.chatdetail.searches.one", "1") : L10n.text("apple.chatdetail.searches.other", "\(group.searches)")) }
            if group.pages > 0 { parts.append(group.pages == 1 ? L10n.text("apple.chatdetail.pages.one", "1") : L10n.text("apple.chatdetail.pages.other", "\(group.pages)")) }
            return parts.joined(separator: ", ")
        case .thought:
            return group.preview
        case .step:
            return group.subject.map { Self.shortSubject(verb: group.verb, $0) }
        }
    }

    private var duration: String? {
        guard !group.running, let start = group.startedAtMs, let end = group.endedAtMs, end > start else { return nil }
        return TurnElapsed.phrase(
            since: Date(timeIntervalSince1970: Double(start) / 1000),
            now: Date(timeIntervalSince1970: Double(end) / 1000)
        )
    }

    private var accessibility: String {
        let actions = group.activityPreview.map {
            [SeatStep.word(verb: $0.verb, running: $0.running), $0.target]
                .filter { !$0.isEmpty }.joined(separator: " ")
        }
        return ([title, summary].compactMap { $0 } + actions)
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// A group's step, shown below its open header: inset, with a rule down the
/// left so the steps read as belonging to the line above them.
struct ChatGroupStepInset: ViewModifier {
    let nested: Bool

    func body(content: Content) -> some View {
        if nested {
            // An overlay, not a sibling in a stack: it takes the row's own
            // height, where a greedy shape beside it would ask a lazy stack
            // for all of it.
            content
                .padding(.leading, 20)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Theme.border)
                        .frame(width: 1)
                        .padding(.leading, 13)
                }
        } else {
            content
        }
    }
}
