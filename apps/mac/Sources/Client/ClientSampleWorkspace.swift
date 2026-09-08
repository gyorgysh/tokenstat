// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

#if !os(macOS)

/// What the product is, before anybody rents anything.
///
/// Setting a machine up costs money and half an hour, and until now that had to
/// happen before somebody could see what they were getting. This is the ten
/// seconds in front of it: a task, the answer, the one line that changed, and
/// what the reading looks like.
///
/// It is a picture and says so, twice, in the places somebody would otherwise
/// mistake for their own data. Nothing here is running: there is no machine, no
/// agent and no account involved, and `scripts/check-sample-offline.sh` keeps it
/// that way.
///
/// Leaving lands back where setup was. No step is marked finished by having
/// looked at this, because none of them is.
struct ClientSampleWorkspace: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    header
                    section("The conversation") {
                        ForEach(ClientSampleStore.conversation) { turn in
                            turnRow(turn)
                        }
                    }
                    section("What changed in \(ClientSampleStore.file)") {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(ClientSampleStore.diff) { line in
                                diffRow(line)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text("One line. Nothing was committed and nothing was published: "
                            + "that stays something you do on purpose.")
                            .font(ClientType.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    section("What it counted") {
                        ForEach(ClientSampleStore.readings) { reading in
                            HStack(alignment: .firstTextBaseline) {
                                Text(reading.label)
                                    .font(ClientType.label)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: Theme.Space.m)
                                Text(reading.value).font(Theme.monoText(13))
                            }
                            .accessibilityElement(children: .combine)
                        }
                        Text(ClientSampleStore.disclaimer)
                            .font(ClientType.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(Theme.Space.m)
                .setupColumn()
            }
            .background(Theme.background)
            .navigationTitle("Sample")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("sample.close")
                }
            }
        }
        .tint(Theme.accent)
        .accessibilityIdentifier("sample")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("An example, not your data")
                .font(ClientType.caption.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .textCase(.uppercase)
                .kerning(0.6)
            Text("A small task, start to finish")
                .font(Theme.title.weight(.semibold))
            Text(ClientSampleStore.disclaimer)
                .font(ClientType.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title)
                .font(ClientType.label.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: Theme.Space.s) { content() }
                .padding(Theme.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface()
        }
    }

    private func turnRow(_ turn: ClientSampleStore.Turn) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: turn.speaker == .person ? "person.fill" : "sparkles")
                .font(Theme.fixed(12, weight: .semibold))
                .foregroundStyle(turn.speaker == .person ? Color.secondary : Theme.accent)
                .frame(width: 22, height: 22)
                .background(
                    (turn.speaker == .person ? Color.secondary : Theme.accent).opacity(0.12),
                    in: Circle()
                )
                .accessibilityHidden(true)
            Text(turn.text)
                .font(ClientType.label)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(turn.speaker == .person ? "You" : "The agent"): \(turn.text)")
    }

    /// A diff line, marked by its sign as well as its colour.
    ///
    /// Green and red alone are the oldest way to make a diff unreadable, and a
    /// sample is exactly where somebody is looking at one for the first time.
    private func diffRow(_ line: ClientSampleStore.Change) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Text(sign(line.kind))
                .font(Theme.monoText(12).weight(.semibold))
                .foregroundStyle(tint(line.kind))
                .frame(width: 10, alignment: .leading)
                .accessibilityHidden(true)
            Text(line.text)
                .font(Theme.monoText(12))
                .foregroundStyle(line.kind == .context ? Color.secondary : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.xs)
        .padding(.vertical, 2)
        .background(tint(line.kind).opacity(line.kind == .context ? 0 : 0.10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(spoken(line.kind)) \(line.text)")
    }

    private func sign(_ kind: ClientSampleStore.Change.Kind) -> String {
        switch kind {
        case .context: " "
        case .removed: "−"
        case .added: "+"
        }
    }

    private func spoken(_ kind: ClientSampleStore.Change.Kind) -> String {
        switch kind {
        case .context: "unchanged"
        case .removed: "removed"
        case .added: "added"
        }
    }

    private func tint(_ kind: ClientSampleStore.Change.Kind) -> Color {
        switch kind {
        case .context: Color.secondary
        case .removed: Theme.danger
        case .added: Theme.success
        }
    }
}

#endif
