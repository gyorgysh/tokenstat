// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation

enum ClientSampleStore {
    struct Turn: Identifiable {
        enum Speaker { case person, agent }
        var id: Int
        var speaker: Speaker
        var text: String
    }

    struct Change: Identifiable {
        enum Kind { case context, removed, added }
        var id: Int
        var kind: Kind
        var text: String
    }

    static let conversation: [Turn] = [
        Turn(
            id: 0,
            speaker: .person,
            text: L10n.text("apple.clientsamplestore.the_landing_page_heading_says_welcome_to_o.c45b7a1f")
        ),
        Turn(
            id: 1,
            speaker: .agent,
            text: L10n.text("apple.clientsamplestore.index_html_has_one_h1_the_page_is_a_bakery.c8074961")
        ),
        Turn(
            id: 2,
            speaker: .agent,
            text: L10n.text("apple.clientsamplestore.changed_the_heading_in_index_html_nothing.6635c27e")
        ),
    ]

    static let file = "index.html"

    static let diff: [Change] = [
        Change(id: 0, kind: .context, text: L10n.text("apple.clientsamplestore.body.9aabfd16")),
        Change(id: 1, kind: .context, text: L10n.text("apple.clientsamplestore.header.4c4638da")),
        Change(id: 2, kind: .removed, text: L10n.text("apple.clientsamplestore.h1_welcome_to_our_site_h1.5a4dd29d")),
        Change(id: 3, kind: .added, text: L10n.text("apple.clientsamplestore.h1_fresh_bread_daily_on_mill_street_h1.e343866d")),
        Change(id: 4, kind: .context, text: L10n.text("apple.clientsamplestore.header.566c3118")),
    ]

    struct Reading: Identifiable {
        var id: String
        var label: String
        var value: String
    }

    static let readings: [Reading] = [
        Reading(id: "input", label: L10n.text("apple.clientsamplestore.sent.c16bc82b"), value: "8,420 tokens"),
        Reading(id: "output", label: L10n.text("apple.clientsamplestore.received.49f19bee"), value: "1,190 tokens"),
        Reading(id: "cost", label: L10n.text("apple.clientsamplestore.cost_of_this_task.716802d2"), value: "$0.04"),
    ]

    static let disclaimer =
        L10n.text("apple.clientsamplestore.this_whole_page_is_an_example_made_up_to_s.1389de3d")
}
