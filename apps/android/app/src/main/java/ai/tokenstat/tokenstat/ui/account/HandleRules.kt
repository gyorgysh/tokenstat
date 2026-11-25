// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.account

import ai.tokenstat.tokenstat.ui.localization.L10n

/// The part of a handle's rules that needs no server. Port of
/// `HandleRules.swift`. The account service decides. This only keeps a form
/// from asking about a name that cannot be one, and words the answers.
object HandleRules {
    const val MINIMUM = 4
    const val MAXIMUM = 32

    /// What somebody types or pastes, as the handle they meant. A pasted
    /// profile address and a leading @ are both the name at the end of them.
    fun normalized(raw: String): String = raw.lowercase().trim()
        .substringAfter("tokenstat.ai/")
        .trimStart('@', '/')
        .takeWhile { it !in "/?#" }
        .split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString("-")
        .take(MAXIMUM)

    /// The server's reason for a name it would refuse on sight, or null when
    /// only the server can answer.
    fun localReason(handle: String): String? = when {
        handle.length < MINIMUM -> "too_short"
        handle.length > MAXIMUM -> "too_long"
        handle.any { it !in 'a'..'z' && it !in '0'..'9' && it != '-' } ||
            handle.startsWith('-') || handle.endsWith('-') -> "invalid_characters"
        "--" in handle -> "double_dash"
        handle.all { it in '0'..'9' } -> "numeric_only"
        else -> null
    }

    /// A reason in words. `fallback` is the server's own sentence, for a
    /// reason newer than this app and for the one that carries a day count.
    fun message(reason: String?, fallback: String = ""): String = when (reason) {
        "too_short", "reserved_premium" -> L10n.text("common.handle.reason.too_short", "$MINIMUM")
        "too_long" -> L10n.text("common.handle.reason.too_long", "$MAXIMUM")
        "invalid_characters", "invalid" -> L10n.text("common.handle.reason.characters")
        "double_dash" -> L10n.text("common.handle.reason.double_dash")
        "numeric_only" -> L10n.text("common.handle.reason.numeric")
        "taken" -> L10n.text("common.handle.reason.taken")
        "reserved", "reserved_lookalike", "inappropriate" -> L10n.text("common.handle.reason.unavailable")
        else -> fallback.ifBlank { L10n.text("common.handle.reason.unavailable") }
    }

    /// `tokenstat.ai/`, the way an address is written for a person.
    fun prefix(host: String): String = host.substringAfter("://").trimEnd('/') + "/"

    fun address(host: String, handle: String): String = prefix(host) + handle
}
