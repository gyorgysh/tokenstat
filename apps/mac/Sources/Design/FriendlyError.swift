// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation
import SwiftUI

/// A failure, said in a way somebody can act on.
///
/// Errors arrive here as sentences written for a log: "connection refused (os
/// error 61)", "the relay rejected this machine's tunnel credential". Those are
/// the right words in `hostd.err.log` and the wrong words on a screen, and the
/// screen is where people meet them.
///
/// One table, shared by the Mac and the client, so the same failure cannot be
/// explained two ways in one product. The raw text is kept: a person who wants
/// the original can still see it, and a support conversation is impossible
/// without it. What changes is what leads.
struct FriendlyError {
    /// Four words at most. What went wrong, not what the code was doing.
    var title: String
    /// One or two sentences: what this means, and what fixes it.
    var message: String
    /// SF Symbol for the state. Chosen per cause, because a wall of identical
    /// warning triangles teaches people to stop reading them.
    var symbol: String
    /// What the button says, when pressing something can help.
    var actionTitle: String?
    /// The original text, for the detail line.
    var raw: String
    /// The button should open plans, not retry. iOS uses the in-app paywall.
    var opensPlans: Bool = false
    var requiresSignIn: Bool = false

    /// The glyph on that button, from the shared action vocabulary: a crown
    /// when it leads to plans, the retry arrow when it retries.
    var actionIcon: ActionIcon { opensPlans ? .plans : requiresSignIn ? .signIn : .refresh }

    /// Whether this is something the user can fix now, as opposed to something
    /// that has to be waited out.
    var isActionable: Bool { actionTitle != nil }

    // Matching is on substrings of the message rather than typed errors on
    // purpose: these strings cross a JSON boundary from Rust, where they are
    // deliberately human sentences and not a code enum. A new phrasing that
    // falls through lands in the default, which is honest, rather than being
    // mapped to the wrong advice.
    static func from(_ text: String) -> FriendlyError {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = raw.lowercased()

        // What the relay says when a screen session is refused or ended. These
        // arrive as the relay's own short codes, which are the right words in
        // its log and no words at all on a screen.
        // No numbers here. The limits get tuned, and a message naming one is
        // wrong the week it changes.
        if lower.contains("session_time_limit") {
            return FriendlyError(
                title: L10n.text("apple.friendlyerror.session_ended.4a50e4c0"),
                message: L10n.text("apple.friendlyerror.screen_sessions_end_after_a_while_connect.1255ca00"),
                symbol: "clock.badge.exclamationmark",
                actionTitle: L10n.text("apple.friendlyerror.connect_again.7da41f19"),
                raw: raw
            )
        }
        if lower.contains("session_idle") {
            return FriendlyError(
                title: L10n.text("apple.friendlyerror.session_ended_while_it_was_idle.24ad53cc"),
                message: L10n.text("apple.friendlyerror.this_device_went_quiet_so_the_stream_stopp.6bd273ae"),
                symbol: "moon.zzz",
                actionTitle: L10n.text("apple.friendlyerror.connect_again.7da41f19"),
                raw: raw
            )
        }
        if lower.contains("screen_already_open") {
            return FriendlyError(
                title: L10n.text("apple.friendlyerror.a_screen_is_already_open.fbd0ef4f"),
                message: L10n.text("apple.friendlyerror.one_screen_at_a_time_on_an_account_close_t.d76ae776"),
                symbol: "display.2",
                raw: raw
            )
        }
        if lower.contains("quota_exceeded") {
            return FriendlyError(
                title: L10n.text("apple.friendlyerror.relay_allowance_used_up.d052225f"),
                message: L10n.text("apple.friendlyerror.check_relay_usage_in_account_to_see_when_o.14353728"),
                symbol: "gauge.with.dots.needle.100percent",
                raw: raw
            )
        }

        // A keychain refusal, which arrives as a bare OSStatus and a sentence
        // that says nothing. -34018 is errSecMissingEntitlement: the build is
        // not allowed to write to the keychain at all, which is a signing
        // problem rather than anything somebody did.
        if lower.contains("-34018") || lower.contains("errsecmissingentitlement") {
            return FriendlyError(
                title: L10n.text("apple.friendlyerror.this_build_cannot_use_the_keychain.d1a5c315"),
                message: L10n.text("apple.friendlyerror.this_copy_of_the_app_is_missing_the_signin.98aa5af7"),
                symbol: "key.slash",
                raw: raw
            )
        }
        // -25300 is errSecItemNotFound: a key record survived the secret it
        // points at, which happens after a restore from a backup.
        if lower.contains("-25300") {
            return FriendlyError(
                title: L10n.text("apple.friendlyerror.the_private_key_is_not_on_this_device.3db8a142"),
                message: L10n.text("apple.friendlyerror.the_record_is_here_but_the_secret_it_point.d27bd117"),
                symbol: "key.slash",
                raw: raw
            )
        }

        // The vault lives on the account, so its failures arrive as server
        // sentences written for a log. Two different causes share the
        // `machine_required` code: a login that was never tied to this
        // computer, and a computer the account has not heard of. They need
        // different advice. Registering the machine cannot fix an unbound
        // token; signing in again from this app can.
        if lower.contains("register this device before using the vault") {
            return FriendlyError(
                title: L10n.text("apple.friendlyerror.this_login_is_not_tied_to_this_computer.b304b378"),
                message: L10n.text("apple.friendlyerror.the_vault_lives_on_your_account_and_this_s.e52d4845"),
                symbol: "person.badge.key",
                actionTitle: L10n.text("apple.friendlyerror.try_again.d8b8392e"),
                raw: raw
            )
        }
        if lower.contains("machine_unlinked") {
            return FriendlyError(
                title: L10n.text("apple.friendlyerror.this_computer_is_not_on_your_account.6ce371f7"),
                message: L10n.text("apple.friendlyerror.machine_unlinked"),
                symbol: "person.crop.circle.badge.exclamationmark",
                actionTitle: L10n.text("common.sign_in"),
                raw: raw,
                requiresSignIn: true
            )
        }
        if lower.contains("machine_required") || lower.contains("machine_not_registered")
            || lower.contains("not registered on the account")
            || lower.contains("not bound to an account device")
        {
            return FriendlyError(
                title: L10n.text("apple.friendlyerror.this_computer_is_not_on_your_account.6ce371f7"),
                message: L10n.text("apple.friendlyerror.sync_needs_this_computer_linked_to_your_ac.5ece6b14"),
                symbol: "person.badge.key",
                actionTitle: L10n.text("apple.friendlyerror.try_again.d8b8392e"),
                raw: raw
            )
        }
        if lower.contains("vault already exists") {
            return FriendlyError(
                title: L10n.text("apple.friendlyerror.there_is_already_a_vault.b9e57f99"),
                message: L10n.text("apple.friendlyerror.an_account_has_one_vault_unlock_the_one_yo.b269036b"),
                symbol: "lock.shield",
                raw: raw
            )
        }
        if lower.contains("not enrolled") || lower.contains("did not enroll") {
            return FriendlyError(
                title: L10n.text("apple.friendlyerror.this_device_cannot_read_the_vault.f4b4e811"),
                message: L10n.text("apple.friendlyerror.it_has_not_been_let_in_yet_unlock_the_vaul.0e352acf"),
                symbol: "lock.shield",
                actionTitle: L10n.text("apple.friendlyerror.try_again.d8b8392e"),
                raw: raw
            )
        }

        // A method the host has never heard of is not a bad call, it is an old
        // helper: the daemon outlives the app that installed it. The method
        // name belongs in a log, not on a screen.
        if lower.contains("unknown method") || lower.contains("unknown_method") {
            return FriendlyError(
                title: L10n.text("apple.friendlyerror.helper_is_out_of_date.ff2cd175"),
                message: L10n.text("apple.friendlyerror.the_background_helper_on_this_machine_is_o.2156c337"),
                symbol: "arrow.triangle.2.circlepath",
                actionTitle: L10n.text("apple.friendlyerror.try_again.d8b8392e"),
                raw: raw
            )
        }
        if lower.contains("not approved") || lower.contains("waiting for someone to allow") {
            return FriendlyError(
                title: L10n.text("apple.friendlyerror.waiting_for_approval.10c5739b"),
                message: L10n.text("apple.friendlyerror.the_other_device_has_to_say_yes_to_this_on.d2653756"),
                symbol: "hand.raised",
                actionTitle: L10n.text("apple.friendlyerror.try_again.d8b8392e"),
                raw: raw
            )
        }
        if lower.contains("paid-plan") || lower.contains("not_on_this_plan")
            || lower.contains("no longer includes remote")
        {
            return FriendlyError(
                title: L10n.text("apple.friendlyerror.not_on_this_plan.92dff92e"),
                message: L10n.text("apple.friendlyerror.reaching_your_devices_from_anywhere_is_par.bfe9ca82"),
                symbol: "star.circle",
                actionTitle: L10n.text("apple.friendlyerror.see_plans.d9898933"),
                raw: raw,
                opensPlans: true
            )
        }
        // Before the sign-in case, and deliberately: a refused tunnel
        // credential repairs itself, and its sentence used to contain the
        // words "sign in again", which sent people to fix something that was
        // already being fixed.
        let wantsSignIn = lower.contains("sign in") || lower.contains("signed out")
            || lower.contains("not logged in")
            || (lower.contains("token") && lower.contains("revoked"))
        if wantsSignIn
            && (lower.contains("could not be minted")
                || lower.contains("paid-plan")
                || lower.contains("device limit"))
        {
            return FriendlyError(
                title: L10n.text("apple.friendlyerror.sign_in_again.51fbe1dc"),
                message: L10n.text("apple.friendlyerror.this_device_s_login_is_no_longer_valid_sig.e2c0cd69"),
                symbol: "person.crop.circle.badge.exclamationmark",
                actionTitle: L10n.text("common.sign_in"),
                raw: raw,
                requiresSignIn: true
            )
        }
        if lower.contains("credential") || lower.contains("tunnel token")
            || lower.contains("key does not match")
        {
            return FriendlyError(
                title: L10n.text("apple.friendlyerror.reconnecting.afb118fc"),
                message: L10n.text("apple.friendlyerror.the_connection_credential_was_refused_so_t.8e2696c5"),
                symbol: "arrow.triangle.2.circlepath",
                actionTitle: L10n.text("apple.friendlyerror.retry_now.5148c3e2"),
                raw: raw
            )
        }
        if lower.contains("sign in") || lower.contains("signed out")
            || lower.contains("not logged in") || lower.contains("token") && lower.contains("revoked")
        {
            return FriendlyError(
                title: L10n.text("apple.friendlyerror.sign_in_again.51fbe1dc"),
                message: L10n.text("apple.friendlyerror.this_device_s_login_is_no_longer_valid_sig.e2c0cd69"),
                symbol: "person.crop.circle.badge.exclamationmark",
                actionTitle: L10n.text("common.sign_in"),
                raw: raw,
                requiresSignIn: true
            )
        }
        if lower.contains("already on the tunnel") || lower.contains("key_already_live") {
            return FriendlyError(
                title: L10n.text("apple.friendlyerror.connected_somewhere_else.2da62c31"),
                message: L10n.text("apple.friendlyerror.another_copy_of_tokenstat_is_on_the_tunnel.0e092a52"),
                symbol: "person.2.slash",
                raw: raw
            )
        }
        if lower.contains("offline") || lower.contains("no internet")
            || lower.contains("network is unreachable") || lower.contains("dns")
            || lower.contains("could not resolve")
        {
            return FriendlyError(
                title: L10n.text("apple.friendlyerror.no_connection.c9e1a200"),
                message: L10n.text("apple.friendlyerror.this_device_cannot_reach_the_network_right.663f753c"),
                symbol: "wifi.slash",
                actionTitle: L10n.text("apple.friendlyerror.try_again.d8b8392e"),
                raw: raw
            )
        }
        if lower.contains("timed out") || lower.contains("timeout") {
            return FriendlyError(
                title: L10n.text("apple.friendlyerror.it_did_not_answer.4f030967"),
                message: L10n.text("apple.friendlyerror.the_other_side_took_too_long_it_is_usually.94ae09da"),
                symbol: "clock.badge.exclamationmark",
                actionTitle: L10n.text("apple.friendlyerror.try_again.d8b8392e"),
                raw: raw
            )
        }
        if lower.contains("this mac is asleep") || lower.contains("host_asleep") {
            return FriendlyError(
                title: L10n.text("apple.friendlyerror.this_mac_is_asleep.ceee64e8"),
                message: L10n.text("apple.friendlyerror.that_mac_has_its_lid_closed_or_tokenstat_i.19412d9d"),
                symbol: "moon.zzz",
                actionTitle: L10n.text("apple.friendlyerror.try_again.d8b8392e"),
                raw: raw
            )
        }
        if lower.contains("connection refused") || lower.contains("os error 61")
            || lower.contains("no such file or directory") && lower.contains("sock")
            || lower.contains("host daemon") || lower.contains("hostd")
        {
            return FriendlyError(
                title: L10n.text("apple.friendlyerror.the_helper_is_not_running.f7afe244"),
                message: L10n.text("apple.friendlyerror.tokenstat_s_background_helper_handles_your.82c596f6"),
                symbol: "gearshape.arrow.trianglehead.2.clockwise.rotate.90",
                actionTitle: L10n.text("apple.friendlyerror.start_it.4238a078"),
                raw: raw
            )
        }
        if lower.contains("broken pipe") || lower.contains("connection reset")
            || lower.contains("disconnected")
        {
            return FriendlyError(
                title: L10n.text("apple.friendlyerror.connection_dropped.9049f3d8"),
                message: L10n.text("apple.friendlyerror.the_link_to_the_other_device_closed_it_rec.fdda8bd3"),
                symbol: "bolt.horizontal.circle",
                actionTitle: L10n.text("apple.friendlyerror.try_again.d8b8392e"),
                raw: raw
            )
        }
        if lower.contains("too many requests") || lower.contains("rate limit")
            || lower.contains("429")
        {
            return FriendlyError(
                title: L10n.text("apple.friendlyerror.asked_too_often.52a8ddb1"),
                message: L10n.text("apple.friendlyerror.the_account_is_answering_fewer_requests_fo.ecb66749"),
                symbol: "hourglass",
                raw: raw
            )
        }
        // Gateway failures establish unreachability, not its cause or duration.
        // Keep the raw response available without guessing which server failed.
        if lower.contains("error code: 1033")
            || lower.contains("1033") && lower.contains("tunnel")
        {
            return FriendlyError(
                title: L10n.text("apple.friendlyerror.the_server_is_unreachable.6862e581"),
                message: L10n.text("apple.friendlyerror.the_connection_could_not_reach_the_server.b54b3470"),
                symbol: "arrow.triangle.2.circlepath",
                actionTitle: L10n.text("apple.friendlyerror.try_again.d8b8392e"),
                raw: raw
            )
        }
        // Bare codes only count inside a failure sentence ("status request
        // failed (503)"), never on their own: a number alone could be a port
        // or a count in some other sentence.
        let readsAsFailure = lower.contains("status") || lower.contains("gateway")
            || lower.contains("error") || lower.contains("failed")
        if lower.contains("bad gateway") || lower.contains("service unavailable")
            || lower.contains("gateway timeout") || lower.contains("gateway error")
            || lower.contains("unknown status code")
            || readsAsFailure
            && (lower.contains("502") || lower.contains("503") || lower.contains("504")
                || lower.contains("530"))
        {
            return FriendlyError(
                title: L10n.text("apple.friendlyerror.the_server_could_not_answer.ffe49c76"),
                message: L10n.text("apple.friendlyerror.the_request_could_not_be_completed_try_aga.54350986"),
                symbol: "arrow.triangle.2.circlepath",
                actionTitle: L10n.text("apple.friendlyerror.try_again.d8b8392e"),
                raw: raw
            )
        }
        if lower.contains("device limit") || lower.contains("machine_limit") {
            return FriendlyError(
                title: L10n.text("apple.friendlyerror.device_limit_reached.9993b12e"),
                message: L10n.text("apple.friendlyerror.this_account_is_using_all_the_devices_its.b51162b6"),
                symbol: "laptopcomputer.slash",
                actionTitle: L10n.text("apple.friendlyerror.manage_devices.3511575c"),
                raw: raw
            )
        }

        // The relay has no record of that computer. Every word of this arrives
        // from the transport ("no direct address", "tunnel: no_such_peer") and
        // every word of it is the wrong thing to read on a phone: it names the
        // mechanism and not one thing a person can do.
        //
        // Most often the same cause, and it is a switch nobody has found:
        // the computer has never been turned on for remote reach, so it has
        // never registered with the relay. A relay-evicted or temporarily
        // offline Mac produces the same strings, so do not assert it.
        if lower.contains("no_such_peer") || lower.contains("no direct address")
            || lower.contains("peer_not_found") || lower.contains("no such peer")
            || lower.contains("could not reach") && (lower.contains("tunnel")
                || lower.contains("direct candidates") || lower.contains("relay"))
        {
            return FriendlyError(
                title: L10n.text("apple.friendlyerror.that_computer_is_not_reachable.162e2c34"),
                message: L10n.text("apple.friendlyerror.it_has_to_be_awake_with_tokenstat_running.73405e61"),
                symbol: "antenna.radiowaves.left.and.right.slash",
                actionTitle: L10n.text("apple.friendlyerror.try_again.d8b8392e"),
                raw: raw
            )
        }

        // Nothing matched. Say that something failed and show the words the
        // machine used, rather than inventing a cause.
        return FriendlyError(
            title: L10n.text("apple.friendlyerror.that_did_not_work.93a20328"),
            message: raw.isEmpty ? L10n.text("apple.friendlyerror.something_went_wrong_and_nothing_said_what.8776f982") : raw,
            symbol: "exclamationmark.triangle",
            actionTitle: L10n.text("apple.friendlyerror.try_again.d8b8392e"),
            raw: raw
        )
    }
}

/// A failure at the top of a screen, in the app's own voice.
///
/// `Banner` says one line in one colour, which is right for "your plan
/// changed" and wrong for everything that went wrong: the sentence it was
/// given was usually a transport error. This keeps the banner's shape and
/// gives the cause a name, a symbol of its own, the fix, and the raw text
/// behind a disclosure for whoever needs it.
struct ErrorBanner: View {
    var message: String
    /// Offered as the banner's button when the caller has something to retry.
    var retry: (() -> Void)?
    @State private var showingDetail = false

    var body: some View {
        let error = FriendlyError.from(message)
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Image(systemName: error.symbol)
                    .font(Theme.font(15))
                    .foregroundStyle(Theme.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(error.title)
                        .font(Theme.callout.weight(.semibold))
                    Text(error.message)
                        .font(Theme.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Space.s)
                if let retry, let actionTitle = error.actionTitle {
                    Button(actionTitle, error.actionIcon, action: retry)
                        .buttonStyle(SecondaryButtonStyle(small: true))
                }
            }
            if error.raw != error.message, !error.raw.isEmpty {
                DisclosureGroup(isExpanded: $showingDetail) {
                    Text(error.raw)
                        .font(Theme.mono(11))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text(L10n.text("apple.friendlyerror.details.45989de4"))
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Theme.warning.opacity(0.12),
            in: RoundedRectangle(cornerRadius: Theme.cardRadius)
        )
    }
}
