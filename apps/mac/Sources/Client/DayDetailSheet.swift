// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

// The client is iOS and iPadOS only.
#if !os(macOS)

/// One day, tapped out of the heatmap.
///
/// A sheet where the Mac has a hover popover. A finger has no hover, and a
/// popover anchored to a 15 point square would cover the square it describes.
///
/// Sized to its content with detents, so a day with two models does not open a
/// full screen panel with nothing in the bottom two thirds of it.
struct DayDetailSheet: View {
    let day: HeatCell

    @State private var detail: DayDetail?
    @State private var isLoading = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    header
                    if isLoading {
                        ClientWireframe.Rows(count: 2)
                    } else if let detail, !detail.rows.isEmpty {
                        ForEach(detail.rows) { row in
                            partRow(row)
                        }
                    } else {
                        // A quiet day is an answer. It must not read as a
                        // failure to look.
                        Text("Nothing recorded on this day.")
                            .font(ClientType.label)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(Theme.Space.m)
            }
            .background(Theme.background)
            .navigationTitle(Self.title(for: day.date))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            // Account scope, because the grid this was tapped out of is the
            // account's. A local answer here would describe a machine whose
            // squares are not the ones on screen.
            detail = try? await Bridge.dayDetail(date: day.date, scope: "account")
            isLoading = false
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(formatSpend(day.value))
                .font(ClientType.figure)
                .foregroundStyle(Theme.accent)
            Text("at list rates")
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
            if let detail {
                Text("\(detail.events) events, \(detail.tokens.formatted()) tokens")
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func partRow(_ row: DayPart) -> some View {
        HStack(spacing: Theme.Space.s) {
            HarnessMark(id: row.src, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.model)
                    .font(ClientType.label.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(harnessName(row.src))
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Theme.Space.s)
            Text(row.tokens.formatted())
                .font(ClientType.rowFigure)
                .foregroundStyle(.secondary)
        }
        .padding(Theme.Space.s)
        .cardSurface()
        .accessibilityElement(children: .combine)
    }

    /// "11 August 2026" from `2026-08-11`, in the reader's own locale.
    ///
    /// Falls back to the raw string rather than to today's date: a sheet
    /// confidently titled with the wrong day is worse than one titled with an
    /// ISO string.
    private static func title(for date: String) -> String {
        guard let parsed = isoDayFormatter.date(from: date) else { return date }
        return parsed.formatted(.dateTime.day().month(.wide).year())
    }
}

private let isoDayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

#endif
