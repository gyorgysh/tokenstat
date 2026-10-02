// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using Microsoft.UI.Xaml.Controls;

namespace Tokenstat.Design;

/// <summary>
/// A failure, said in a way somebody can act on. One table, shared by every
/// client, so the same failure cannot be explained two ways in one product.
/// Titles, messages and match order are transcribed from the Apple
/// FriendlyError, which is the source of truth. The raw text is kept: what
/// changes is what leads.
/// Two deliberate differences: glyphs are WinUI Symbols approximating the SF
/// Symbols (there is no moon, key or wifi slash in the enum), and the asleep
/// row names the remote Mac rather than this one, because on Windows the
/// sleeper is always the other computer.
/// </summary>
internal sealed record FriendlyErrorInfo(
    string Title,
    string Message,
    string Raw,
    string? ActionTitle = null,
    bool OpensPlans = false,
    bool RequiresSignIn = false,
    Symbol Symbol = Symbol.Important)
{
    /// <summary>
    /// The glyph on the action button, from the shared action vocabulary: a
    /// crown when it leads to plans, the retry arrow when it retries.
    /// </summary>
    public ActionIcon ActionIcon => OpensPlans ? ActionIcon.Plans : RequiresSignIn ? ActionIcon.SignIn : ActionIcon.Refresh;

    /// <summary>Whether this is something the user can fix now.</summary>
    public bool IsActionable => ActionTitle is not null;
}

internal static class FriendlyError
{
    public static string Display(string? raw) => From(raw).Message;

    // Matching is on substrings of the message rather than typed errors on
    // purpose: these strings cross a JSON boundary from Rust, where they are
    // deliberately human sentences and not a code enum. A new phrasing that
    // falls through lands in the default, which is honest, rather than being
    // mapped to the wrong advice. Arm order mirrors the Apple table, where
    // order is load bearing.
    public static FriendlyErrorInfo From(string? text)
    {
        var raw = (text ?? "").Trim();
        var lower = raw.ToLowerInvariant();

        if (lower.Contains("session_time_limit"))
        {
            return new FriendlyErrorInfo(
                L10n.Text("windows.friendlyerror.session_ended.4a50e4c0"),
                L10n.Text("windows.friendlyerror.screen_sessions_end_after_a_while_connect.1255ca00"),
                raw,
                ActionTitle: L10n.Text("windows.friendlyerror.connect_again.7da41f19"),
                Symbol: Symbol.Clock);
        }
        if (lower.Contains("session_idle"))
        {
            return new FriendlyErrorInfo(
                L10n.Text("windows.friendlyerror.session_ended_while_it_was_idle.24ad53cc"),
                L10n.Text("windows.friendlyerror.this_device_went_quiet_so_the_stream_stopp.6bd273ae"),
                raw,
                ActionTitle: L10n.Text("windows.friendlyerror.connect_again.7da41f19"),
                Symbol: Symbol.Clock);
        }
        if (lower.Contains("screen_already_open"))
        {
            return new FriendlyErrorInfo(
                L10n.Text("windows.friendlyerror.a_screen_is_already_open.fbd0ef4f"),
                L10n.Text("windows.friendlyerror.one_screen_at_a_time_on_an_account_close_t.d76ae776"),
                raw,
                Symbol: Symbol.View);
        }
        if (lower.Contains("quota_exceeded"))
        {
            return new FriendlyErrorInfo(
                L10n.Text("windows.friendlyerror.relay_allowance_used_up.d052225f"),
                L10n.Text("windows.friendlyerror.check_relay_usage_in_account_to_see_when_o.14353728"),
                raw,
                Symbol: Symbol.Download);
        }
        if (lower.Contains("-34018") || lower.Contains("errsecmissingentitlement"))
        {
            return new FriendlyErrorInfo(
                L10n.Text("windows.friendlyerror.this_build_cannot_use_the_keychain.d1a5c315"),
                L10n.Text("windows.friendlyerror.this_copy_of_the_app_is_missing_the_signin.98aa5af7"),
                raw,
                Symbol: Symbol.Permissions);
        }
        if (lower.Contains("-25300"))
        {
            return new FriendlyErrorInfo(
                L10n.Text("windows.friendlyerror.the_private_key_is_not_on_this_device.3db8a142"),
                L10n.Text("windows.friendlyerror.the_record_is_here_but_the_secret_it_point.d27bd117"),
                raw,
                Symbol: Symbol.Permissions);
        }
        if (lower.Contains("register this device before using the vault"))
        {
            return new FriendlyErrorInfo(
                L10n.Text("windows.friendlyerror.this_login_is_not_tied_to_this_computer.b304b378"),
                L10n.Text("windows.friendlyerror.the_vault_lives_on_your_account_and_this_s.e52d4845"),
                raw,
                ActionTitle: L10n.Text("windows.friendlyerror.try_again.d8b8392e"),
                Symbol: Symbol.People);
        }
        if (lower.Contains("machine_unlinked"))
        {
            return new FriendlyErrorInfo(
                L10n.Text("windows.friendlyerror.this_computer_is_not_on_your_account.6ce371f7"),
                L10n.Text("windows.friendlyerror.machine_unlinked"),
                raw,
                ActionTitle: L10n.Text("common.sign_in"),
                RequiresSignIn: true,
                Symbol: Symbol.Contact);
        }
        if (lower.Contains("machine_required") || lower.Contains("machine_not_registered")
            || lower.Contains("not registered on the account")
            || lower.Contains("not bound to an account device"))
        {
            return new FriendlyErrorInfo(
                L10n.Text("windows.friendlyerror.this_computer_is_not_on_your_account.6ce371f7"),
                L10n.Text("windows.friendlyerror.sync_needs_this_computer_linked_to_your_ac.5ece6b14"),
                raw,
                ActionTitle: L10n.Text("windows.friendlyerror.try_again.d8b8392e"),
                Symbol: Symbol.People);
        }
        if (lower.Contains("vault already exists"))
        {
            return new FriendlyErrorInfo(
                L10n.Text("windows.friendlyerror.there_is_already_a_vault.b9e57f99"),
                L10n.Text("windows.friendlyerror.an_account_has_one_vault_unlock_the_one_yo.b269036b"),
                raw,
                Symbol: Symbol.Permissions);
        }
        if (lower.Contains("not enrolled") || lower.Contains("did not enroll"))
        {
            return new FriendlyErrorInfo(
                L10n.Text("windows.friendlyerror.this_device_cannot_read_the_vault.f4b4e811"),
                L10n.Text("windows.friendlyerror.it_has_not_been_let_in_yet_unlock_the_vaul.0e352acf"),
                raw,
                ActionTitle: L10n.Text("windows.friendlyerror.try_again.d8b8392e"),
                Symbol: Symbol.Permissions);
        }
        if (lower.Contains("unknown method") || lower.Contains("unknown_method"))
        {
            return new FriendlyErrorInfo(
                L10n.Text("windows.friendlyerror.helper_is_out_of_date.ff2cd175"),
                L10n.Text("windows.friendlyerror.the_background_helper_on_this_machine_is_o.2156c337"),
                raw,
                ActionTitle: L10n.Text("windows.friendlyerror.try_again.d8b8392e"),
                Symbol: Symbol.Refresh);
        }
        if (lower.Contains("not approved") || lower.Contains("waiting for someone to allow"))
        {
            return new FriendlyErrorInfo(
                L10n.Text("windows.friendlyerror.waiting_for_approval.10c5739b"),
                L10n.Text("windows.friendlyerror.the_other_device_has_to_say_yes_to_this_on.d2653756"),
                raw,
                ActionTitle: L10n.Text("windows.friendlyerror.try_again.d8b8392e"),
                Symbol: Symbol.People);
        }
        if (lower.Contains("paid-plan") || lower.Contains("not_on_this_plan")
            || lower.Contains("no longer includes remote"))
        {
            return new FriendlyErrorInfo(
                L10n.Text("windows.friendlyerror.not_on_this_plan.92dff92e"),
                L10n.Text("windows.friendlyerror.reaching_your_devices_from_anywhere_is_par.bfe9ca82"),
                raw,
                ActionTitle: L10n.Text("windows.friendlyerror.see_plans.d9898933"),
                OpensPlans: true,
                Symbol: Symbol.Favorite);
        }
        // Before the sign-in case, and deliberately: a refused tunnel
        // credential repairs itself, and its sentence used to contain the
        // words "sign in again", which sent people to fix something that was
        // already being fixed.
        var wantsSignIn = lower.Contains("sign in") || lower.Contains("signed out")
            || lower.Contains("not logged in")
            || (lower.Contains("token") && lower.Contains("revoked"));
        if (wantsSignIn
            && (lower.Contains("could not be minted")
                || lower.Contains("paid-plan")
                || lower.Contains("device limit")))
        {
            return new FriendlyErrorInfo(
                L10n.Text("windows.friendlyerror.sign_in_again.51fbe1dc"),
                L10n.Text("windows.friendlyerror.this_device_s_login_is_no_longer_valid_sig.e2c0cd69"),
                raw,
                ActionTitle: L10n.Text("common.sign_in"),
                RequiresSignIn: true,
                Symbol: Symbol.Contact);
        }
        if (lower.Contains("credential") || lower.Contains("tunnel token")
            || lower.Contains("key does not match"))
        {
            return new FriendlyErrorInfo(
                L10n.Text("windows.friendlyerror.reconnecting.afb118fc"),
                L10n.Text("windows.friendlyerror.the_connection_credential_was_refused_so_t.8e2696c5"),
                raw,
                ActionTitle: L10n.Text("windows.friendlyerror.retry_now.5148c3e2"),
                Symbol: Symbol.Refresh);
        }
        if (wantsSignIn)
        {
            return new FriendlyErrorInfo(
                L10n.Text("windows.friendlyerror.sign_in_again.51fbe1dc"),
                L10n.Text("windows.friendlyerror.this_device_s_login_is_no_longer_valid_sig.e2c0cd69"),
                raw,
                ActionTitle: L10n.Text("common.sign_in"),
                RequiresSignIn: true,
                Symbol: Symbol.Contact);
        }
        // No Apple row for this one. A refused account or device is not a
        // dead login, so it must not send people to sign in again.
        if (lower.Contains("unauthorized") || lower.Contains("forbidden"))
        {
            return new FriendlyErrorInfo(
                L10n.Text("windows.friendlyerror.this_account_or_device_does_not_have_acces.4f3e4cdf"),
                L10n.Text("windows.friendlyerror.this_account_or_device_does_not_have_acces.4f3e4cdf"),
                raw,
                Symbol: Symbol.Permissions);
        }
        if (lower.Contains("already on the tunnel") || lower.Contains("key_already_live"))
        {
            return new FriendlyErrorInfo(
                L10n.Text("windows.friendlyerror.connected_somewhere_else.2da62c31"),
                L10n.Text("windows.friendlyerror.another_copy_of_tokenstat_is_on_the_tunnel.0e092a52"),
                raw,
                Symbol: Symbol.People);
        }
        if (lower.Contains("offline") || lower.Contains("no internet")
            || lower.Contains("network is unreachable") || lower.Contains("dns")
            || lower.Contains("could not resolve"))
        {
            return new FriendlyErrorInfo(
                L10n.Text("windows.friendlyerror.no_connection.c9e1a200"),
                L10n.Text("windows.friendlyerror.this_device_cannot_reach_the_network_right.663f753c"),
                raw,
                ActionTitle: L10n.Text("windows.friendlyerror.try_again.d8b8392e"),
                Symbol: Symbol.Globe);
        }
        if (lower.Contains("timed out") || lower.Contains("timeout"))
        {
            return new FriendlyErrorInfo(
                L10n.Text("windows.friendlyerror.it_did_not_answer.4f030967"),
                L10n.Text("windows.friendlyerror.the_other_side_took_too_long_it_is_usually.94ae09da"),
                raw,
                ActionTitle: L10n.Text("windows.friendlyerror.try_again.d8b8392e"),
                Symbol: Symbol.Clock);
        }
        if (lower.Contains("this mac is asleep") || lower.Contains("host_asleep"))
        {
            return new FriendlyErrorInfo(
                L10n.Text("windows.friendlyerror.that_mac_is_asleep.fce2923b"),
                L10n.Text("windows.friendlyerror.that_mac_has_its_lid_closed_or_tokenstat_i.3ed1ce89"),
                raw,
                ActionTitle: L10n.Text("windows.friendlyerror.try_again.d8b8392e"),
                Symbol: Symbol.Clock);
        }
        if (lower.Contains("connection refused") || lower.Contains("os error 61")
            || (lower.Contains("no such file or directory") && lower.Contains("sock"))
            || lower.Contains("host daemon") || lower.Contains("hostd"))
        {
            return new FriendlyErrorInfo(
                L10n.Text("windows.friendlyerror.the_helper_is_not_running.f7afe244"),
                L10n.Text("windows.friendlyerror.tokenstat_s_background_helper_handles_your.82c596f6"),
                raw,
                ActionTitle: L10n.Text("windows.friendlyerror.start_it.4238a078"),
                Symbol: Symbol.Setting);
        }
        if (lower.Contains("broken pipe") || lower.Contains("connection reset")
            || lower.Contains("disconnected"))
        {
            return new FriendlyErrorInfo(
                L10n.Text("windows.friendlyerror.connection_dropped.9049f3d8"),
                L10n.Text("windows.friendlyerror.the_link_to_the_other_device_closed_it_rec.fdda8bd3"),
                raw,
                ActionTitle: L10n.Text("windows.friendlyerror.try_again.d8b8392e"),
                Symbol: Symbol.Link);
        }
        if (lower.Contains("too many requests") || lower.Contains("rate limit")
            || lower.Contains("429"))
        {
            return new FriendlyErrorInfo(
                L10n.Text("windows.friendlyerror.asked_too_often.52a8ddb1"),
                L10n.Text("windows.friendlyerror.the_account_is_answering_fewer_requests_fo.ecb66749"),
                raw,
                Symbol: Symbol.Clock);
        }
        if (lower.Contains("error code: 1033")
            || (lower.Contains("1033") && lower.Contains("tunnel")))
        {
            return new FriendlyErrorInfo(
                L10n.Text("windows.friendlyerror.the_server_is_unreachable.6862e581"),
                L10n.Text("windows.friendlyerror.the_connection_could_not_reach_the_server.b54b3470"),
                raw,
                ActionTitle: L10n.Text("windows.friendlyerror.try_again.d8b8392e"),
                Symbol: Symbol.Refresh);
        }
        // Bare codes only count inside a failure sentence, never on their own:
        // a number alone could be a port or a count in some other sentence.
        var readsAsFailure = lower.Contains("status") || lower.Contains("gateway")
            || lower.Contains("error") || lower.Contains("failed");
        if (lower.Contains("bad gateway") || lower.Contains("service unavailable")
            || lower.Contains("gateway timeout") || lower.Contains("gateway error")
            || lower.Contains("unknown status code")
            || (readsAsFailure
                && (lower.Contains("502") || lower.Contains("503") || lower.Contains("504")
                    || lower.Contains("530"))))
        {
            return new FriendlyErrorInfo(
                L10n.Text("windows.friendlyerror.the_server_could_not_answer.ffe49c76"),
                L10n.Text("windows.friendlyerror.the_request_could_not_be_completed_try_aga.54350986"),
                raw,
                ActionTitle: L10n.Text("windows.friendlyerror.try_again.d8b8392e"),
                Symbol: Symbol.Refresh);
        }
        if (lower.Contains("device limit") || lower.Contains("machine_limit"))
        {
            return new FriendlyErrorInfo(
                L10n.Text("windows.friendlyerror.device_limit_reached.9993b12e"),
                L10n.Text("windows.friendlyerror.this_account_is_using_all_the_devices_its.b51162b6"),
                raw,
                ActionTitle: L10n.Text("windows.friendlyerror.manage_devices.3511575c"),
                Symbol: Symbol.CellPhone);
        }
        if (lower.Contains("no_such_peer") || lower.Contains("no direct address")
            || lower.Contains("peer_not_found") || lower.Contains("no such peer")
            || (lower.Contains("could not reach") && (lower.Contains("tunnel")
                || lower.Contains("direct candidates") || lower.Contains("relay"))))
        {
            return new FriendlyErrorInfo(
                L10n.Text("windows.friendlyerror.that_computer_is_not_reachable.162e2c34"),
                L10n.Text("windows.friendlyerror.it_has_to_be_awake_with_tokenstat_running.73405e61"),
                raw,
                ActionTitle: L10n.Text("windows.friendlyerror.try_again.d8b8392e"),
                Symbol: Symbol.Globe);
        }

        // Nothing matched. Say that something failed and show the words the
        // machine used, rather than inventing a cause.
        return new FriendlyErrorInfo(
            L10n.Text("windows.friendlyerror.that_did_not_work.93a20328"),
            string.IsNullOrEmpty(raw) ? L10n.Text("windows.friendlyerror.something_went_wrong_and_nothing_said_what.8776f982") : raw,
            raw,
            ActionTitle: L10n.Text("windows.friendlyerror.try_again.d8b8392e"),
            Symbol: Symbol.Important);
    }
}
