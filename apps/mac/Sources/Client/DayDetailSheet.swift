// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

#if !os(macOS)

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
                        Text(L10n.text("apple.daydetailsheet.nothing_recorded_on_this_day.5ad77ba8"))
                            .font(ClientType.label)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(Theme.Space.m)
            }
            .background(Theme.background)
            .navigationTitle(spokenDate(day.date))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("common.done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            detail = try? await Bridge.dayDetail(date: day.date, scope: "account")
            isLoading = false
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(formatSpend(day.value))
                .font(ClientType.figure)
                .foregroundStyle(Theme.accent)
            Text(L10n.text("apple.daydetailsheet.at_api_list_price.128de85c"))
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
            if let detail {
                Text(L10n.text("apple.daydetailsheet.0_events_1_tokens.e35a47c3", "\(detail.events)", "\(detail.tokens.formatted())"))
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
            HarnessMark(id: harnessToolKey(row.src), size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.model)
                    .font(ClientType.label.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(harnessName(harnessToolKey(row.src)))
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Theme.Space.s)
            Text(formatTokens(row.tokens))
                .font(ClientType.rowFigure)
                .foregroundStyle(.secondary)
        }
        .padding(Theme.Space.s)
        .frame(minHeight: 44)
        .cardSurface()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            L10n.text("apple.daydetailsheet.0_on_1_2_tokens.2b7237a6", "\(row.model)", "\(harnessName(harnessToolKey(row.src)))", "\(formatTokens(row.tokens))")
        )
    }
}

#endif
