// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import ai.tokenstat.tokenstat.ui.localization.L10n

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
            in 5..<12 -> L10n.text("android.tslogic.good_morning.90a90a48")
            in 12..<17 -> L10n.text("android.tslogic.good_afternoon.d325e1bb")
            in 17..<22 -> L10n.text("android.tslogic.good_evening.15a421e4")
            else -> L10n.text("android.tslogic.hello.185f8db3")
        }
        // Fixed length so a later hasHistory flip only changes the returning
        // slots, not which index the day lands on.
        val pool = listOf(
            timed,
            L10n.text("android.tslogic.hello.185f8db3"),
            L10n.text("android.tslogic.what_s_up.11ec53bc"),
            if (hasHistory) L10n.text("android.tslogic.welcome_back.66212495") else L10n.text("android.tslogic.welcome.0e2226b5"),
            if (hasHistory) L10n.text("android.tslogic.back_at_it.9ce858b7") else timed,
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
        "claude_code" -> L10n.text("android.tslogic.claude_code.246ef8c1")
        "claude_code_rollup", "claude_code_estimate" -> L10n.text("android.tslogic.claude_code_recovered.93f5e6b2")
        "codex" -> "Codex"
        "grok" -> L10n.text("android.tslogic.grok_build.fd3bf01a")
        "opencode" -> "OpenCode"
        "cline" -> "Cline"
        "openclaw" -> "OpenClaw"
        "muse" -> "Muse"
        "devin" -> L10n.text("android.tslogic.devin_cli.29247d05")
        "pi" -> "Pi"
        "dsh" -> L10n.text("android.tslogic.deepseek_harness.e562a9c5")
        "zed" -> "Zed"
        "copilot" -> L10n.text("android.tslogic.copilot_cli.c73e38d4")
        "antigravity" -> "Antigravity"
        "cursor" -> "Cursor"
        "gemini" -> "Gemini"
        "hermes" -> L10n.text("android.tslogic.hermes_agent.873e989a")
        "kilo" -> L10n.text("android.tslogic.kilo_code.83abecfd")
        "kimi" -> L10n.text("android.tslogic.kimi_code.0c486180")
        "qwen" -> L10n.text("android.tslogic.qwen_code.47487dbd")
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
            L10n.text("android.tslogic.waiting_for_the_computer_to_come_back_on_t.cab8d5a0")
        } else {
            L10n.text("android.tslogic.waiting_for_0_to_come_back_on_the_tunnel.0f402193", "${host}")
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
    if (raw == null) return FriendlyError(L10n.text("android.tslogic.something_went_wrong.ab827e3f"), L10n.text("android.tslogic.the_request_could_not_be_completed.4c9681ac"), true)
    val text = raw.trim()
    val lower = text.lowercase()
    // What the relay says when a screen session is refused or ended. These
    // arrive as the relay's own short codes. No numbers here: the limits get
    // tuned, and a message naming one is wrong the week it changes.
    if (lower.contains("session_time_limit")) {
        return FriendlyError(
            L10n.text("android.tslogic.session_ended.4a50e4c0"),
            L10n.text("android.tslogic.screen_sessions_end_after_a_while_connect.1255ca00"),
            true,
        )
    }
    if (lower.contains("session_idle")) {
        return FriendlyError(
            L10n.text("android.tslogic.session_ended_while_it_was_idle.24ad53cc"),
            L10n.text("android.tslogic.this_device_went_quiet_so_the_stream_stopp.6bd273ae"),
            true,
        )
    }
    if (lower.contains("screen_already_open")) {
        return FriendlyError(
            L10n.text("android.tslogic.a_screen_is_already_open.fbd0ef4f"),
            L10n.text("android.tslogic.one_screen_at_a_time_on_an_account_close_t.d76ae776"),
            false,
        )
    }
    if (lower.contains("quota_exceeded")) {
        return FriendlyError(
            L10n.text("android.tslogic.relay_allowance_used_up.d052225f"),
            L10n.text("android.tslogic.check_relay_usage_in_account_to_see_when_o.14353728"),
            false,
        )
    }
    // A keychain refusal, which arrives as a bare OSStatus and a sentence
    // that says nothing.
    if (lower.contains("-34018") || lower.contains("errsecmissingentitlement")) {
        return FriendlyError(
            L10n.text("android.tslogic.this_build_cannot_use_the_keychain.d1a5c315"),
            L10n.text("android.tslogic.this_copy_of_the_app_is_missing_the_signin.98aa5af7"),
            false,
        )
    }
    if (lower.contains("-25300")) {
        return FriendlyError(
            L10n.text("android.tslogic.the_private_key_is_not_on_this_device.3db8a142"),
            L10n.text("android.tslogic.the_record_is_here_but_the_secret_it_point.d27bd117"),
            false,
        )
    }
    // Two different causes share the `machine_required` code: a login that
    // was never tied to this computer, and a computer the account has not
    // heard of. They need different advice.
    if (lower.contains("register this device before using the vault")) {
        return FriendlyError(
            L10n.text("android.tslogic.this_login_is_not_tied_to_this_computer.b304b378"),
            L10n.text("android.tslogic.the_vault_lives_on_your_account_and_this_s.e52d4845"),
            true,
        )
    }
    if (lower.contains("machine_required") || lower.contains("machine_not_registered") ||
        lower.contains("not registered on the account") || lower.contains("not bound to an account device")
    ) {
        return FriendlyError(
            L10n.text("android.tslogic.this_computer_is_not_on_your_account.6ce371f7"),
            L10n.text("android.tslogic.sync_needs_this_computer_linked_to_your_ac.5ece6b14"),
            true,
        )
    }
    if (lower.contains("vault already exists")) {
        return FriendlyError(
            L10n.text("android.tslogic.there_is_already_a_vault.b9e57f99"),
            L10n.text("android.tslogic.an_account_has_one_vault_unlock_the_one_yo.b269036b"),
            false,
        )
    }
    if (lower.contains("not enrolled") || lower.contains("did not enroll")) {
        return FriendlyError(
            L10n.text("android.tslogic.this_device_cannot_read_the_vault.f4b4e811"),
            L10n.text("android.tslogic.it_has_not_been_let_in_yet_unlock_the_vaul.0e352acf"),
            true,
        )
    }
    // A method the host has never heard of is not a bad call, it is an old
    // helper: the daemon outlives the app that installed it.
    if (lower.contains("unknown method") || lower.contains("unknown_method")) {
        return FriendlyError(
            L10n.text("android.tslogic.helper_is_out_of_date.ff2cd175"),
            L10n.text("android.tslogic.the_background_helper_on_this_machine_is_o.2156c337"),
            true,
        )
    }
    if (lower.contains("not approved") || lower.contains("waiting for someone to allow")) {
        return FriendlyError(
            L10n.text("android.tslogic.waiting_for_approval.10c5739b"),
            L10n.text("android.tslogic.the_other_device_has_to_say_yes_to_this_on.d2653756"),
            true,
        )
    }
    if (lower.contains("paid-plan") || lower.contains("not_on_this_plan") ||
        lower.contains("no longer includes remote")
    ) {
        // Opens plans rather than retrying, so this is not a retry row.
        return FriendlyError(
            L10n.text("android.tslogic.not_on_this_plan.92dff92e"),
            L10n.text("android.tslogic.reaching_your_devices_from_anywhere_is_par.bfe9ca82"),
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
            L10n.text("android.tslogic.sign_in_again.51fbe1dc"),
            L10n.text("android.tslogic.this_device_s_login_is_no_longer_valid_sig.e2c0cd69"),
            true,
        )
    }
    if (lower.contains("credential") || lower.contains("tunnel token") ||
        lower.contains("key does not match")
    ) {
        return FriendlyError(
            L10n.text("android.tslogic.reconnecting.afb118fc"),
            L10n.text("android.tslogic.the_connection_credential_was_refused_so_t.8e2696c5"),
            true,
        )
    }
    if (wantsSignIn) {
        return FriendlyError(
            L10n.text("android.tslogic.sign_in_again.51fbe1dc"),
            L10n.text("android.tslogic.this_device_s_login_is_no_longer_valid_sig.e2c0cd69"),
            true,
        )
    }
    if (lower.contains("already on the tunnel") || lower.contains("key_already_live")) {
        return FriendlyError(
            L10n.text("android.tslogic.connected_somewhere_else.2da62c31"),
            L10n.text("android.tslogic.another_copy_of_tokenstat_is_on_the_tunnel.0e092a52"),
            false,
        )
    }
    if (lower.contains("offline") || lower.contains("no internet") ||
        lower.contains("network is unreachable") || lower.contains("dns") ||
        lower.contains("could not resolve")
    ) {
        return FriendlyError(
            L10n.text("android.tslogic.no_connection.c9e1a200"),
            L10n.text("android.tslogic.this_device_cannot_reach_the_network_right.663f753c"),
            true,
        )
    }
    if (lower.contains("timed out") || lower.contains("timeout")) {
        return FriendlyError(
            L10n.text("android.tslogic.it_did_not_answer.4f030967"),
            L10n.text("android.tslogic.the_other_side_took_too_long_it_is_usually.94ae09da"),
            true,
        )
    }
    if (lower.contains("this mac is asleep") || lower.contains("host_asleep")) {
        return FriendlyError(
            L10n.text("android.tslogic.this_mac_is_asleep.ceee64e8"),
            L10n.text("android.tslogic.that_mac_has_its_lid_closed_or_tokenstat_i.19412d9d"),
            true,
        )
    }
    if (lower.contains("connection refused") || lower.contains("os error 61") ||
        (lower.contains("no such file or directory") && lower.contains("sock")) ||
        lower.contains("host daemon") || lower.contains("hostd")
    ) {
        return FriendlyError(
            L10n.text("android.tslogic.the_helper_is_not_running.f7afe244"),
            L10n.text("android.tslogic.tokenstat_s_background_helper_handles_your.82c596f6"),
            true,
        )
    }
    if (lower.contains("broken pipe") || lower.contains("connection reset") ||
        lower.contains("disconnected")
    ) {
        return FriendlyError(
            L10n.text("android.tslogic.connection_dropped.9049f3d8"),
            L10n.text("android.tslogic.the_link_to_the_other_device_closed_it_rec.fdda8bd3"),
            true,
        )
    }
    if (lower.contains("too many requests") || lower.contains("rate limit") ||
        lower.contains("429")
    ) {
        return FriendlyError(
            L10n.text("android.tslogic.asked_too_often.52a8ddb1"),
            L10n.text("android.tslogic.the_account_is_answering_fewer_requests_fo.ecb66749"),
            false,
        )
    }
    // Gateway failures establish unreachability, not its cause or duration.
    if (lower.contains("error code: 1033") ||
        (lower.contains("1033") && lower.contains("tunnel"))
    ) {
        return FriendlyError(
            L10n.text("android.tslogic.the_server_is_unreachable.6862e581"),
            L10n.text("android.tslogic.the_connection_could_not_reach_the_server.b54b3470"),
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
            L10n.text("android.tslogic.the_server_could_not_answer.ffe49c76"),
            L10n.text("android.tslogic.the_request_could_not_be_completed_try_aga.54350986"),
            true,
        )
    }
    if (lower.contains("device limit") || lower.contains("machine_limit")) {
        // Offers device management rather than a retry.
        return FriendlyError(
            L10n.text("android.tslogic.device_limit_reached.9993b12e"),
            L10n.text("android.tslogic.this_account_is_using_all_the_devices_its.b51162b6"),
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
            L10n.text("android.tslogic.that_computer_is_not_reachable.162e2c34"),
            L10n.text("android.tslogic.it_has_to_be_awake_with_tokenstat_running.73405e61"),
            true,
        )
    }
    // Nothing matched. Say that something failed and show the words the
    // machine used, rather than inventing a cause.
    return FriendlyError(
        L10n.text("android.tslogic.that_did_not_work.93a20328"),
        text.ifEmpty { L10n.text("android.tslogic.something_went_wrong_and_nothing_said_what.8776f982") },
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
    if (scalars.size < 12) out += L10n.text("android.tslogic.at_least_12_characters.0ced89a6")
    if (password.none { it.isUpperCase() }) out += L10n.text("android.tslogic.an_uppercase_letter.a61f4d4b")
    if (scalars.none { it in '0'.code..'9'.code }) out += L10n.text("android.tslogic.a_number.a3c9dfa2")
    if (password.none { !it.isLetterOrDigit() && !it.isWhitespace() }) out += L10n.text("android.tslogic.a_special_character.9b79cde5")
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
