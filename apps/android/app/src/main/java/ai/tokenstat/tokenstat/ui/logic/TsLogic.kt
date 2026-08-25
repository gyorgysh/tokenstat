// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import java.text.NumberFormat
import java.util.Calendar

/// Pure text/format logic ported 1:1 from the Apple client so both platforms
/// answer identically. Each object cites its Swift source.

/// Port of `Sources/Design/Greeting.swift`.
object HomeGreeting {
    fun line(name: String, hasHistory: Boolean, hour: Int, dayOfYear: Int): String =
        "${phrase(hour, hasHistory, dayOfYear)}, ${firstName(name)}"

    fun firstName(name: String): String {
        val trimmed = name.trim()
        return trimmed.split(Regex("\\s+")).firstOrNull() ?: trimmed
    }

    fun phrase(hour: Int, hasHistory: Boolean, dayOfYear: Int): String {
        val timed = when (hour) {
            in 5..<12 -> "Good morning"
            in 12..<17 -> "Good afternoon"
            in 17..<22 -> "Good evening"
            else -> "Hello"
        }
        // Fixed length so a later hasHistory flip only changes the returning
        // slots, not which index the day lands on.
        val pool = listOf(
            timed,
            "Hello",
            "What's up",
            if (hasHistory) "Welcome back" else "Welcome",
            if (hasHistory) "Back at it" else timed,
        )
        return pool[Math.floorMod(dayOfYear, pool.size)]
    }

    fun line(name: String, hasHistory: Boolean, calendar: Calendar = Calendar.getInstance()): String =
        line(
            name,
            hasHistory,
            calendar.get(Calendar.HOUR_OF_DAY),
            calendar.get(Calendar.DAY_OF_YEAR),
        )
}

/// Compact token counts, the way the Apple client renders them beside a model
/// name: "1.6M" is a size, the full ten digits is a wall.
fun compactTokens(count: Long?): String = when {
    count == null || count <= 0 -> "0"
    count >= 1_000_000_000 -> "%.1fB".format(count / 1_000_000_000.0)
    count >= 1_000_000 -> "%.1fM".format(count / 1_000_000.0)
    count >= 1_000 -> "%.1fK".format(count / 1_000.0)
    else -> count.toString()
}

private val currencyFormat: NumberFormat by lazy { NumberFormat.getCurrencyInstance() }

/// Micros to a localised currency string.
fun money(micros: Long): String = currencyFormat.format(micros / 1_000_000.0)

/// Copy for a tunnel that is mid-reconnect, not gone
/// (`ClientTunnelCopy` in ClientRemote.swift).
object TunnelCopy {
    fun isAbsent(message: String): Boolean {
        val lower = message.lowercase()
        return lower.contains("no_such_peer") ||
            lower.contains("not on the tunnel") ||
            lower.contains("did not pair the channel") ||
            lower.contains("tunnel is not connected") ||
            lower.contains("tunnel disconnected")
    }

    fun waiting(hostName: String?): String {
        val host = hostName?.trim().orEmpty()
        return if (host.isEmpty()) {
            "Waiting for the computer to come back on the tunnel."
        } else {
            "Waiting for $host to come back on the tunnel."
        }
    }

    fun display(message: String, host: String?): String =
        if (isAbsent(message)) waiting(host) else message
}

/// Substring translation of raw core errors into friendly copy, mirroring the
/// shape of `FriendlyError.swift` (title + message + retry suggestion). The
/// Apple table is longer; these are the rows the phone's screens hit.
data class FriendlyError(val title: String, val message: String, val canRetry: Boolean)

fun friendlyError(raw: String?): FriendlyError = when {
    raw == null -> FriendlyError("Something went wrong", "The request could not be completed.", true)
    raw.contains("offline", ignoreCase = true) || raw.contains("no_such_peer", ignoreCase = true) ->
        FriendlyError("The computer is unreachable", TunnelCopy.waiting(null), true)
    raw.contains("timeout", ignoreCase = true) ->
        FriendlyError("That took too long", "The machine did not answer in time. Try again.", true)
    raw.contains("unauthorized", ignoreCase = true) || raw.contains("forbidden", ignoreCase = true) ->
        FriendlyError("Not allowed", "This account or device does not have access to that.", false)
    raw.contains("unknown method", ignoreCase = true) || raw.contains("unknown_method", ignoreCase = true) ->
        FriendlyError(
            "Helper is out of date",
            "The background helper on this machine is older than the app and does not know this yet. Restart the app to replace it, then try again.",
            true,
        )
    else -> FriendlyError("Something went wrong", raw, true)
}

/// The same vault password rule the host enforces in `tokenstat_core::passphrase`.
///
/// Measured in Unicode scalars, with an ASCII-only digit test, so Eastern
/// Arabic digits do not enable a button the host then refuses.
fun vaultPasswordProblems(password: String): List<String> {
    val scalars = password.codePoints().toArray()
    val out = mutableListOf<String>()
    if (scalars.size < 12) out += "At least 12 characters"
    if (password.none { it.isUpperCase() }) out += "An uppercase letter"
    if (scalars.none { it in '0'.code..'9'.code }) out += "A number"
    if (password.none { !it.isLetterOrDigit() && !it.isWhitespace() }) out += "A special character"
    return out
}

/// The same recovery-code normalisation the host uses.
fun normalizedRecovery(value: String): String = buildString {
    for (ch in value.uppercase()) {
        if (!ch.isLetterOrDigit() || ch.code > 127) continue
        append(
            when (ch) {
                'O' -> '0'
                'I', 'L' -> '1'
                else -> ch
            },
        )
    }
}
