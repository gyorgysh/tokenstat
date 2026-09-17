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

/// Full grouped counts, the reading of Swift's `.formatted()` on an integer.
/// The Insights row subtitle keeps every event ("34,346 events"), unlike the
/// stat chips above it which compact. Device locale, like the Apple client:
/// money is pinned to US dollars but a count groups the way the user reads.
fun groupedCount(count: Long?): String =
    NumberFormat.getIntegerInstance().format(count ?: 0L)

/// Compact token counts, port of `formatTokens` in `Bridge/Models.swift`.
/// Lowercase k, and whole thousands above ten thousand ("126k"), exactly
/// like the Apple client.
fun compactTokens(count: Long?): String = when {
    count == null || count <= 0 -> "0"
    count >= 1_000_000_000 -> "%.1fB".format(count / 1_000_000_000.0)
    count >= 1_000_000 -> "%.1fM".format(count / 1_000_000.0)
    count >= 10_000 -> "%.0fk".format(count / 1_000.0)
    count >= 1_000 -> "%.1fk".format(count / 1_000.0)
    else -> count.toString()
}

/// Rates are published in US dollars, so the figure is formatted as one
/// regardless of where the user is, like `Money` in `Bridge/Models.swift`.
/// A Hungarian locale rendering a local amount would not match the `$6,786.57`
/// the CLI prints for the very same archive.
private val currencyFormat: NumberFormat by lazy {
    NumberFormat.getCurrencyInstance(java.util.Locale.US).apply {
        currency = java.util.Currency.getInstance("USD")
        minimumFractionDigits = 2
        maximumFractionDigits = 2
    }
}

/// Micros to a US dollar string. Never money billed: subscription usage is
/// valued the same way.
fun money(micros: Long): String = currencyFormat.format(micros / 1_000_000.0)

/// A bucket value with its qualifier, port of `Money.formatted`: a floor
/// reads "at least this much" (+), an estimate "about this much" (~).
fun moneyValue(micros: Long, estimated: Boolean, complete: Boolean): String {
    val amount = money(micros)
    if (!complete) return "${amount}+"
    if (estimated) return "~$amount"
    return amount
}

/// Display name for a harness id, port of `harnessName` in
/// `Bridge/Models.swift`. Same spelling tokenstat.ai uses.
fun harnessName(id: String): String {
    if (id == "opencode2") return "OpenCode 2"
    return when (harnessCanonicalID(id)) {
        "claude_code" -> "Claude Code"
        "claude_code_rollup", "claude_code_estimate" -> "Claude Code (recovered)"
        "codex" -> "Codex"
        "grok" -> "Grok Build"
        "opencode" -> "OpenCode"
        "cline" -> "Cline"
        "openclaw" -> "OpenClaw"
        "muse" -> "Muse"
        "devin" -> "Devin CLI"
        "pi" -> "Pi"
        "dsh" -> "DeepSeek Harness"
        "zed" -> "Zed"
        "copilot" -> "Copilot CLI"
        "antigravity" -> "Antigravity"
        "cursor" -> "Cursor"
        "gemini" -> "Gemini"
        "hermes" -> "Hermes Agent"
        "kilo" -> "Kilo Code"
        "kimi" -> "Kimi Code"
        "qwen" -> "Qwen Code"
        "" -> "unknown"
        else -> harnessCanonicalID(id).ifEmpty { "unknown" }
    }
}

/// Stored source id to brand id, port of `harnessCanonicalID`.
fun harnessCanonicalID(id: String): String {
    if (id == "agy") return "antigravity"
    if (id.startsWith("antigravity")) return "antigravity"
    if (id == "claude") return "claude_code"
    if (id == "opencode2") return "opencode"
    return id
}

/// Marks a sign-in URL as the Android client flow, the way
/// `ClientWebAuth.start` tags `app=ios`: the site renders the phone variant
/// of the approval page and redirects back to the app when it is approved.
/// Harmless on a server that does not know the parameter yet.
fun tagSignInUrl(url: String): String {
    val separator = if (url.contains("?")) "&" else "?"
    return "$url${separator}app=android&mobile=1"
}

/// "11 August", with the year only when it is not this one, port of
/// `shortDate` in `ClientDates.swift`. Unparseable input passes through.
fun shortDate(iso: String): String {
    val date = try {
        java.time.LocalDate.parse(iso, java.time.format.DateTimeFormatter.ISO_LOCAL_DATE)
    } catch (e: Exception) {
        return iso
    }
    val now = java.time.LocalDate.now()
    val pattern = if (date.year == now.year) "d MMMM" else "d MMMM yyyy"
    return date.format(java.time.format.DateTimeFormatter.ofPattern(pattern))
}

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

/// Substring translation of raw core errors into friendly copy, ported row for
/// row from `FriendlyError.swift` (title + message + retry suggestion).
/// Matching is on substrings on purpose: these strings cross a JSON boundary
/// from Rust, where they are deliberately human sentences and not a code
/// enum. A new phrasing that falls through lands in the default, which is
/// honest, rather than being mapped to the wrong advice. Order matters: rows
/// are checked in the same order as the Apple client, so both platforms
/// answer identically.
data class FriendlyError(val title: String, val message: String, val canRetry: Boolean)

fun friendlyError(raw: String?): FriendlyError {
    if (raw == null) return FriendlyError("Something went wrong", "The request could not be completed.", true)
    val text = raw.trim()
    val lower = text.lowercase()
    // What the relay says when a screen session is refused or ended. These
    // arrive as the relay's own short codes. No numbers here: the limits get
    // tuned, and a message naming one is wrong the week it changes.
    if (lower.contains("session_time_limit")) {
        return FriendlyError(
            "Session ended",
            "Screen sessions end after a while. Connect again to carry on.",
            true,
        )
    }
    if (lower.contains("session_idle")) {
        return FriendlyError(
            "Session ended while it was idle",
            "This device went quiet, so the stream stopped. Connect again to pick it up.",
            true,
        )
    }
    if (lower.contains("screen_already_open")) {
        return FriendlyError(
            "A screen is already open",
            "One screen at a time on an account. Close the other one and try again.",
            false,
        )
    }
    if (lower.contains("quota_exceeded")) {
        return FriendlyError(
            "Relay allowance used up",
            "Check relay usage in Account to see when older traffic leaves the window. " +
                "Direct connections do not use this allowance.",
            false,
        )
    }
    // A keychain refusal, which arrives as a bare OSStatus and a sentence
    // that says nothing.
    if (lower.contains("-34018") || lower.contains("errsecmissingentitlement")) {
        return FriendlyError(
            "This build cannot use the keychain",
            "This copy of the app is missing the signing configuration needed for protected " +
                "Keychain storage. Use a build signed with its Keychain entitlement and " +
                "matching provisioning profile.",
            false,
        )
    }
    if (lower.contains("-25300")) {
        return FriendlyError(
            "The private key is not on this device",
            "The record is here but the secret it points at is not, which is what a restore " +
                "from a backup leaves behind. Import or generate the key again.",
            false,
        )
    }
    // Two different causes share the `machine_required` code: a login that
    // was never tied to this computer, and a computer the account has not
    // heard of. They need different advice.
    if (lower.contains("register this device before using the vault")) {
        return FriendlyError(
            "This login is not tied to this computer",
            "The vault lives on your account, and this sign-in predates linking the two. " +
                "Press Try again first. If that does not clear it, sign in again from Account. " +
                "Everything saved here still works.",
            true,
        )
    }
    if (lower.contains("machine_required") || lower.contains("machine_not_registered") ||
        lower.contains("not registered on the account") || lower.contains("not bound to an account device")
    ) {
        return FriendlyError(
            "This computer is not on your account",
            "Sync needs this computer linked to your account before it can hold a copy of " +
                "your servers. Everything still works here in the meantime.",
            true,
        )
    }
    if (lower.contains("vault already exists")) {
        return FriendlyError(
            "There is already a vault",
            "An account has one vault. Unlock the one you have, or reset it if you cannot " +
                "get back into it.",
            false,
        )
    }
    if (lower.contains("not enrolled") || lower.contains("did not enroll")) {
        return FriendlyError(
            "This device cannot read the vault",
            "It has not been let in yet. Unlock the vault here to give this device its copy " +
                "of the key.",
            true,
        )
    }
    // A method the host has never heard of is not a bad call, it is an old
    // helper: the daemon outlives the app that installed it.
    if (lower.contains("unknown method") || lower.contains("unknown_method")) {
        return FriendlyError(
            "Helper is out of date",
            "The background helper on this machine is older than the app and does not know " +
                "this yet. Restart the app to replace it, then try again.",
            true,
        )
    }
    if (lower.contains("not approved") || lower.contains("waiting for someone to allow")) {
        return FriendlyError(
            "Waiting for approval",
            "The other device has to say yes to this one. Open Devices there and approve it, " +
                "then try again.",
            true,
        )
    }
    if (lower.contains("paid-plan") || lower.contains("not_on_this_plan") ||
        lower.contains("no longer includes remote")
    ) {
        // Opens plans rather than retrying, so this is not a retry row.
        return FriendlyError(
            "Not on this plan",
            "Reaching your devices from anywhere is part of a paid plan. Everything else " +
                "keeps working exactly as it does now.",
            false,
        )
    }
    // Before the sign-in case, and deliberately: a refused tunnel credential
    // repairs itself, and its sentence used to contain the words "sign in
    // again", which sent people to fix something already being fixed.
    val wantsSignIn = lower.contains("sign in") || lower.contains("signed out") ||
        lower.contains("not logged in") || (lower.contains("token") && lower.contains("revoked"))
    if (wantsSignIn && (lower.contains("could not be minted") || lower.contains("paid-plan") ||
            lower.contains("device limit"))
    ) {
        return FriendlyError(
            "Sign in again",
            "This device's login is no longer valid. Signing in again puts it back, and " +
                "nothing local is lost.",
            true,
        )
    }
    if (lower.contains("credential") || lower.contains("tunnel token") ||
        lower.contains("key does not match")
    ) {
        return FriendlyError(
            "Reconnecting",
            "The connection credential was refused, so this device is getting a new one. It " +
                "usually comes back on its own within a minute.",
            true,
        )
    }
    if (wantsSignIn) {
        return FriendlyError(
            "Sign in again",
            "This device's login is no longer valid. Signing in again puts it back, and " +
                "nothing local is lost.",
            true,
        )
    }
    if (lower.contains("already on the tunnel") || lower.contains("key_already_live")) {
        return FriendlyError(
            "Connected somewhere else",
            "Another copy of tokenstat is on the tunnel with this device's key. Quit it, or " +
                "wait a moment for it to drop.",
            false,
        )
    }
    if (lower.contains("offline") || lower.contains("no internet") ||
        lower.contains("network is unreachable") || lower.contains("dns") ||
        lower.contains("could not resolve")
    ) {
        return FriendlyError(
            "No connection",
            "This device cannot reach the network right now. It retries by itself as soon as " +
                "it can.",
            true,
        )
    }
    if (lower.contains("timed out") || lower.contains("timeout")) {
        return FriendlyError(
            "It did not answer",
            "The other side took too long. It is usually asleep rather than broken.",
            true,
        )
    }
    if (lower.contains("this mac is asleep") || lower.contains("host_asleep")) {
        return FriendlyError(
            "This Mac is asleep",
            "That Mac has its lid closed, or tokenstat is not open. Open the app, open the " +
                "lid, or turn on Always-on host in Account to keep it reachable.",
            true,
        )
    }
    if (lower.contains("connection refused") || lower.contains("os error 61") ||
        (lower.contains("no such file or directory") && lower.contains("sock")) ||
        lower.contains("host daemon") || lower.contains("hostd")
    ) {
        return FriendlyError(
            "The helper is not running",
            "tokenstat's background helper handles your archive and your devices. Open the " +
                "app to start it, or turn on Always-on host to keep it running after you " +
                "quit or close the lid.",
            true,
        )
    }
    if (lower.contains("broken pipe") || lower.contains("connection reset") ||
        lower.contains("disconnected")
    ) {
        return FriendlyError(
            "Connection dropped",
            "The link to the other device closed. It reconnects on its own.",
            true,
        )
    }
    if (lower.contains("too many requests") || lower.contains("rate limit") ||
        lower.contains("429")
    ) {
        return FriendlyError(
            "Asked too often",
            "The account is answering fewer requests for a moment. What is on screen is " +
                "still good, and the next refresh will go through.",
            false,
        )
    }
    // Gateway failures establish unreachability, not its cause or duration.
    if (lower.contains("error code: 1033") ||
        (lower.contains("1033") && lower.contains("tunnel"))
    ) {
        return FriendlyError(
            "The server is unreachable",
            "The connection could not reach the server. Try again shortly.",
            true,
        )
    }
    // Bare codes only count inside a failure sentence ("status request failed
    // (503)"), never on their own: a number alone could be a port or a count
    // in some other sentence.
    val readsAsFailure = lower.contains("status") || lower.contains("gateway") ||
        lower.contains("error") || lower.contains("failed")
    if (lower.contains("bad gateway") || lower.contains("service unavailable") ||
        lower.contains("gateway timeout") || lower.contains("gateway error") ||
        lower.contains("unknown status code") ||
        (readsAsFailure && (lower.contains("502") || lower.contains("503") ||
            lower.contains("504") || lower.contains("530")))
    ) {
        return FriendlyError(
            "The server could not answer",
            "The request could not be completed. Try again shortly.",
            true,
        )
    }
    if (lower.contains("device limit") || lower.contains("machine_limit")) {
        // Offers device management rather than a retry.
        return FriendlyError(
            "Device limit reached",
            "This account is using all the devices its plan allows. Remove one you no longer " +
                "have, or move up a plan.",
            false,
        )
    }
    // The relay has no record of that computer. Most often the same cause: it
    // has never been turned on for remote reach. A relay-evicted or
    // temporarily offline Mac produces the same strings, so do not assert it.
    if (lower.contains("no_such_peer") || lower.contains("no direct address") ||
        lower.contains("peer_not_found") || lower.contains("no such peer") ||
        (lower.contains("could not reach") && (lower.contains("tunnel") ||
            lower.contains("direct candidates") || lower.contains("relay")))
    ) {
        return FriendlyError(
            "That computer is not reachable",
            "It has to be awake with tokenstat running, and set up for remote reach. If this " +
                "worked before, wake it and try again. If it never worked, on that computer " +
                "open Devices and turn on \"Reach devices from anywhere\". Until that is on, " +
                "it never tells the relay where it is.",
            true,
        )
    }
    // Nothing matched. Say that something failed and show the words the
    // machine used, rather than inventing a cause.
    return FriendlyError(
        "That did not work",
        text.ifEmpty { "Something went wrong and nothing said what." },
        true,
    )
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
