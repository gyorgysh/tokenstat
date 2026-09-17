// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.sample

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
            "The landing page heading says \"Welcome to our site\". Make it say what " +
                "the site is for instead.",
        ),
        Turn(
            1,
            Speaker.AGENT,
            "index.html has one h1. The page is a bakery's opening hours and address, " +
                "so the heading should say that. I'll change the one line and leave " +
                "everything else alone.",
        ),
        Turn(
            2,
            Speaker.AGENT,
            "Changed the heading in index.html. Nothing else in the file moved, and " +
                "nothing is committed: the change is sitting in the folder for you.",
        ),
    )

    const val file: String = "index.html"

    val diff: List<Change> = listOf(
        Change(0, ChangeKind.CONTEXT, "<body>"),
        Change(1, ChangeKind.CONTEXT, "  <header>"),
        Change(2, ChangeKind.REMOVED, "    <h1>Welcome to our site</h1>"),
        Change(3, ChangeKind.ADDED, "    <h1>Fresh bread, daily, on Mill Street</h1>"),
        Change(4, ChangeKind.CONTEXT, "  </header>"),
    )

    /// What a reading looks like, with made-up numbers.
    ///
    /// Shown so somebody knows the shape of what they get, never presented as
    /// anyone's spend. Every screen that draws these says they are invented.
    data class Reading(val id: String, val label: String, val value: String)

    val readings: List<Reading> = listOf(
        Reading("input", "Sent", "8,420 tokens"),
        Reading("output", "Received", "1,190 tokens"),
        Reading("cost", "Cost of this task", "$0.04"),
    )

    /// Said in full wherever the numbers appear.
    const val disclaimer: String =
        "This whole page is an example, made up to show the shape of the thing. " +
            "The numbers are invented and are not anybody's usage or spending."
}
