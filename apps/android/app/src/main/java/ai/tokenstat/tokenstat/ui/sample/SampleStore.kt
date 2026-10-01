// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.sample

import ai.tokenstat.tokenstat.ui.localization.L10n

/// The sample, as data and nothing else. Port of `ClientSampleStore`.
///
/// Deliberately a fixture, not a workspace, a peer or a chat. A sample that
/// borrowed the real machinery would need a machine to borrow it from, and the
/// whole point is somebody with no machine, no account standing and nothing
/// bought.
///
/// Nothing in this file may reach the bridge, the network, the account or any
/// registry. It has no functions that take input, so there is nothing to write
/// with. The numbers are invented and are labelled as invented everywhere they
/// are shown. They are not a claim about what anything costs.
object SampleStore {
    enum class Speaker { PERSON, AGENT }

    data class Turn(val id: Int, val speaker: Speaker, val text: String)

    enum class ChangeKind { CONTEXT, REMOVED, ADDED }

    data class Change(val id: Int, val kind: ChangeKind, val text: String)

    /// A short exchange that ends in one edit somebody can read in full.
    ///
    /// One line changed, in a file whose purpose is obvious without the rest
    /// of the project around it. A sample that showed a refactor would be a
    /// sample nobody could check.
    val conversation: List<Turn> = listOf(
        Turn(
            0,
            Speaker.PERSON,
            L10n.text("android.samplestore.the_landing_page_heading_says_welcome_to_o.c45b7a1f"),
        ),
        Turn(
            1,
            Speaker.AGENT,
            L10n.text("android.samplestore.index_html_has_one_h1_the_page_is_a_bakery.c8074961"),
        ),
        Turn(
            2,
            Speaker.AGENT,
            L10n.text("android.samplestore.changed_the_heading_in_index_html_nothing.6635c27e"),
        ),
    )

    const val file: String = "index.html"

    val diff: List<Change> = listOf(
        Change(0, ChangeKind.CONTEXT, "<body>"),
        Change(1, ChangeKind.CONTEXT, "  <header>"),
        Change(2, ChangeKind.REMOVED, L10n.text("android.samplestore.h1_welcome_to_our_site_h1.5a4dd29d")),
        Change(3, ChangeKind.ADDED, L10n.text("android.samplestore.h1_fresh_bread_daily_on_mill_street_h1.e343866d")),
        Change(4, ChangeKind.CONTEXT, "  </header>"),
    )

    /// What a reading looks like, with made-up numbers.
    ///
    /// Shown so somebody knows the shape of what they get, never presented as
    /// anyone's spend. Every screen that draws these says they are invented.
    data class Reading(val id: String, val label: String, val value: String)

    val readings: List<Reading> = listOf(
        Reading("input", L10n.text("android.samplestore.sent.c16bc82b"), "8,420 tokens"),
        Reading("output", L10n.text("android.samplestore.received.49f19bee"), "1,190 tokens"),
        Reading("cost", L10n.text("android.samplestore.cost_of_this_task.716802d2"), "$0.04"),
    )

    /// Said in full wherever the numbers appear.
    val disclaimer: String = L10n.text("android.samplestore.this_whole_page_is_an_example_made_up_to_s.1389de3d")
}
