// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation

/// The sample, as data and nothing else.
///
/// Deliberately a fixture in one file rather than a workspace, a peer or a
/// chat. A sample that borrowed the real machinery would need a machine to
/// borrow it from, and the whole point is somebody with no machine, no account
/// standing and nothing bought.
///
/// **Nothing in this file may reach the bridge, the network, the account or
/// any registry.** It is checked, by `scripts/check-sample-offline.sh`: the one
/// way a preview turns into a lie is by quietly becoming real, and the one way
/// it becomes dangerous is by writing somewhere. It has no functions that take
/// input, so there is nothing to write with.
///
/// The numbers are invented and are labelled as invented everywhere they are
/// shown. They are not a claim about what anything costs.
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

    /// A short exchange that ends in one edit somebody can read in full.
    ///
    /// One line changed, in a file whose purpose is obvious without the rest of
    /// the project around it. A sample that showed a refactor would be a sample
    /// nobody could check.
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

    /// What a reading looks like, with made-up numbers.
    ///
    /// Shown so somebody knows the shape of what they get, never presented as
    /// anyone's spend. Every screen that draws these says they are invented.
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

    /// Said in full wherever the numbers appear.
    static let disclaimer =
        L10n.text("apple.clientsamplestore.this_whole_page_is_an_example_made_up_to_s.1389de3d")
}
