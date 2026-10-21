// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// The standalone fixture exercises directory and sharing controls without
/// linking the app's chat runtime. Production injects TeamTranscriptContent.
enum TeamFixtureTranscript {
    @MainActor static func render(_ history: TeamChatHistory) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: Theme.Space.m) {
            ForEach(Array(history.events.enumerated()), id: \.offset) { _, value in
                if case let .object(row) = value {
                    if case let .string(text)? = row["text"] {
                        if case let .object(author)? = row["author"], author["kind"] == .string("person"), case let .string(name)? = author["name"] {
                            Label(name, systemImage: "person.crop.circle").font(Theme.caption).foregroundStyle(.secondary)
                        } else {
                            Label(L10n.text("common.teams.local_before_teams"), systemImage: "person.crop.circle").font(Theme.caption).foregroundStyle(.secondary)
                        }
                        Text(text).font(Theme.body).textSelection(.enabled)
                    } else if case let .object(event)? = row["event"], case let .string(text)? = event["delta"] {
                        Text(text).font(Theme.body).textSelection(.enabled).padding(Theme.Space.m).frame(maxWidth: .infinity, alignment: .leading).background(Theme.panel)
                    }
                }
            }
        }.preference(key: TeamTranscriptRenderedKey.self, value: history.renderId))
    }
}
