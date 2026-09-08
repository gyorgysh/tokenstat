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
            text: "The landing page heading says \"Welcome to our site\". Make it say what "
                + "the site is for instead."
        ),
        Turn(
            id: 1,
            speaker: .agent,
            text: "index.html has one h1. The page is a bakery's opening hours and address, "
                + "so the heading should say that. I'll change the one line and leave "
                + "everything else alone."
        ),
        Turn(
            id: 2,
            speaker: .agent,
            text: "Changed the heading in index.html. Nothing else in the file moved, and "
                + "nothing is committed: the change is sitting in the folder for you."
        ),
    ]

    static let file = "index.html"

    static let diff: [Change] = [
        Change(id: 0, kind: .context, text: "<body>"),
        Change(id: 1, kind: .context, text: "  <header>"),
        Change(id: 2, kind: .removed, text: "    <h1>Welcome to our site</h1>"),
        Change(id: 3, kind: .added, text: "    <h1>Fresh bread, daily, on Mill Street</h1>"),
        Change(id: 4, kind: .context, text: "  </header>"),
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
        Reading(id: "input", label: "Sent", value: "8,420 tokens"),
        Reading(id: "output", label: "Received", value: "1,190 tokens"),
        Reading(id: "cost", label: "Cost of this task", value: "$0.04"),
    ]

    /// Said in full wherever the numbers appear.
    static let disclaimer =
        "This whole page is an example, made up to show the shape of the thing. "
        + "The numbers are invented and are not anybody's usage or spending."
}
