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
    Symbol Symbol = Symbol.Important)
{
    /// <summary>
    /// The glyph on the action button, from the shared action vocabulary: a
    /// crown when it leads to plans, the retry arrow when it retries.
    /// </summary>
    public ActionIcon ActionIcon => OpensPlans ? ActionIcon.Plans : ActionIcon.Refresh;

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
                "Session ended",
                "Screen sessions end after a while. Connect again to carry on.",
                raw,
                ActionTitle: "Connect again",
                Symbol: Symbol.Clock);
        }
        if (lower.Contains("session_idle"))
        {
            return new FriendlyErrorInfo(
                "Session ended while it was idle",
                "This device went quiet, so the stream stopped. Connect again to pick it up.",
                raw,
                ActionTitle: "Connect again",
                Symbol: Symbol.Clock);
        }
        if (lower.Contains("screen_already_open"))
        {
            return new FriendlyErrorInfo(
                "A screen is already open",
                "One screen at a time on an account. Close the other one and try again.",
                raw,
                Symbol: Symbol.View);
        }
        if (lower.Contains("quota_exceeded"))
        {
            return new FriendlyErrorInfo(
                "Relay allowance used up",
                "Check relay usage in Account to see when older traffic leaves the window. "
                + "Direct connections do not use this allowance.",
                raw,
                Symbol: Symbol.Download);
        }
        if (lower.Contains("-34018") || lower.Contains("errsecmissingentitlement"))
        {
            return new FriendlyErrorInfo(
                "This build cannot use the keychain",
                "This copy of the app is missing the signing configuration needed for "
                + "protected Keychain storage. Use a build signed with its Keychain "
                + "entitlement and matching provisioning profile.",
                raw,
                Symbol: Symbol.Permissions);
        }
        if (lower.Contains("-25300"))
        {
            return new FriendlyErrorInfo(
                "The private key is not on this device",
                "The record is here but the secret it points at is not, which is what "
                + "a restore from a backup leaves behind. Import or generate the key again.",
                raw,
                Symbol: Symbol.Permissions);
        }
        if (lower.Contains("register this device before using the vault"))
        {
            return new FriendlyErrorInfo(
                "This login is not tied to this computer",
                "The vault lives on your account, and this sign-in predates "
                + "linking the two. Press Try again first. If that does not clear it, "
                + "sign in again from Account. Everything saved here still works.",
                raw,
                ActionTitle: "Try again",
                Symbol: Symbol.People);
        }
        if (lower.Contains("machine_required") || lower.Contains("machine_not_registered")
            || lower.Contains("not registered on the account")
            || lower.Contains("not bound to an account device"))
        {
            return new FriendlyErrorInfo(
                "This computer is not on your account",
                "Sync needs this computer linked to your account before it can hold a "
                + "copy of your servers. Everything still works here in the meantime.",
                raw,
                ActionTitle: "Try again",
                Symbol: Symbol.People);
        }
        if (lower.Contains("vault already exists"))
        {
            return new FriendlyErrorInfo(
                "There is already a vault",
                "An account has one vault. Unlock the one you have, or reset it if you "
                + "cannot get back into it.",
                raw,
                Symbol: Symbol.Permissions);
        }
        if (lower.Contains("not enrolled") || lower.Contains("did not enroll"))
        {
            return new FriendlyErrorInfo(
                "This device cannot read the vault",
                "It has not been let in yet. Unlock the vault here to give this device "
                + "its copy of the key.",
                raw,
                ActionTitle: "Try again",
                Symbol: Symbol.Permissions);
        }
        if (lower.Contains("unknown method") || lower.Contains("unknown_method"))
        {
            return new FriendlyErrorInfo(
                "Helper is out of date",
                "The background helper on this machine is older than the app and does "
                + "not know this yet. Restart the app to replace it, then try again.",
                raw,
                ActionTitle: "Try again",
                Symbol: Symbol.Refresh);
        }
        if (lower.Contains("not approved") || lower.Contains("waiting for someone to allow"))
        {
            return new FriendlyErrorInfo(
                "Waiting for approval",
                "The other device has to say yes to this one. Open Devices there and "
                + "approve it, then try again.",
                raw,
                ActionTitle: "Try again",
                Symbol: Symbol.People);
        }
        if (lower.Contains("paid-plan") || lower.Contains("not_on_this_plan")
            || lower.Contains("no longer includes remote"))
        {
            return new FriendlyErrorInfo(
                "Not on this plan",
                "Reaching your devices from anywhere is part of a paid plan. Everything "
                + "else keeps working exactly as it does now.",
                raw,
                ActionTitle: "See plans",
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
                "Sign in again",
                "This device's login is no longer valid. Signing in again puts it back, "
                + "and nothing local is lost.",
                raw,
                ActionTitle: "Sign in",
                Symbol: Symbol.Contact);
        }
        if (lower.Contains("credential") || lower.Contains("tunnel token")
            || lower.Contains("key does not match"))
        {
            return new FriendlyErrorInfo(
                "Reconnecting",
                "The connection credential was refused, so this device is getting a new "
                + "one. It usually comes back on its own within a minute.",
                raw,
                ActionTitle: "Retry now",
                Symbol: Symbol.Refresh);
        }
        if (wantsSignIn)
        {
            return new FriendlyErrorInfo(
                "Sign in again",
                "This device's login is no longer valid. Signing in again puts it back, "
                + "and nothing local is lost.",
                raw,
                ActionTitle: "Sign in",
                Symbol: Symbol.Contact);
        }
        // No Apple row for this one. A refused account or device is not a
        // dead login, so it must not send people to sign in again.
        if (lower.Contains("unauthorized") || lower.Contains("forbidden"))
        {
            return new FriendlyErrorInfo(
                "This account or device does not have access to that.",
                "This account or device does not have access to that.",
                raw,
                Symbol: Symbol.Permissions);
        }
        if (lower.Contains("already on the tunnel") || lower.Contains("key_already_live"))
        {
            return new FriendlyErrorInfo(
                "Connected somewhere else",
                "Another copy of tokenstat is on the tunnel with this device's key. "
                + "Quit it, or wait a moment for it to drop.",
                raw,
                Symbol: Symbol.People);
        }
        if (lower.Contains("offline") || lower.Contains("no internet")
            || lower.Contains("network is unreachable") || lower.Contains("dns")
            || lower.Contains("could not resolve"))
        {
            return new FriendlyErrorInfo(
                "No connection",
                "This device cannot reach the network right now. It retries by itself as "
                + "soon as it can.",
                raw,
                ActionTitle: "Try again",
                Symbol: Symbol.Globe);
        }
        if (lower.Contains("timed out") || lower.Contains("timeout"))
        {
            return new FriendlyErrorInfo(
                "It did not answer",
                "The other side took too long. It is usually asleep rather than broken.",
                raw,
                ActionTitle: "Try again",
                Symbol: Symbol.Clock);
        }
        if (lower.Contains("this mac is asleep") || lower.Contains("host_asleep"))
        {
            return new FriendlyErrorInfo(
                "That Mac is asleep",
                "That Mac has its lid closed, or tokenstat is not open there. Open the "
                + "app, open the lid, or turn on Always-on host in Account to keep it reachable.",
                raw,
                ActionTitle: "Try again",
                Symbol: Symbol.Clock);
        }
        if (lower.Contains("connection refused") || lower.Contains("os error 61")
            || (lower.Contains("no such file or directory") && lower.Contains("sock"))
            || lower.Contains("host daemon") || lower.Contains("hostd"))
        {
            return new FriendlyErrorInfo(
                "The helper is not running",
                "tokenstat's background helper handles your archive and your devices. "
                + "Open the app to start it, or turn on Always-on host to keep it running "
                + "after you quit or close the lid.",
                raw,
                ActionTitle: "Start it",
                Symbol: Symbol.Setting);
        }
        if (lower.Contains("broken pipe") || lower.Contains("connection reset")
            || lower.Contains("disconnected"))
        {
            return new FriendlyErrorInfo(
                "Connection dropped",
                "The link to the other device closed. It reconnects on its own.",
                raw,
                ActionTitle: "Try again",
                Symbol: Symbol.Link);
        }
        if (lower.Contains("too many requests") || lower.Contains("rate limit")
            || lower.Contains("429"))
        {
            return new FriendlyErrorInfo(
                "Asked too often",
                "The account is answering fewer requests for a moment. What is on screen "
                + "is still good, and the next refresh will go through.",
                raw,
                Symbol: Symbol.Clock);
        }
        if (lower.Contains("error code: 1033")
            || (lower.Contains("1033") && lower.Contains("tunnel")))
        {
            return new FriendlyErrorInfo(
                "The server is unreachable",
                "The connection could not reach the server. Try again shortly.",
                raw,
                ActionTitle: "Try again",
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
                "The server could not answer",
                "The request could not be completed. Try again shortly.",
                raw,
                ActionTitle: "Try again",
                Symbol: Symbol.Refresh);
        }
        if (lower.Contains("device limit") || lower.Contains("machine_limit"))
        {
            return new FriendlyErrorInfo(
                "Device limit reached",
                "This account is using all the devices its plan allows. Remove one you no "
                + "longer have, or move up a plan.",
                raw,
                ActionTitle: "Manage devices",
                Symbol: Symbol.CellPhone);
        }
        if (lower.Contains("no_such_peer") || lower.Contains("no direct address")
            || lower.Contains("peer_not_found") || lower.Contains("no such peer")
            || (lower.Contains("could not reach") && (lower.Contains("tunnel")
                || lower.Contains("direct candidates") || lower.Contains("relay"))))
        {
            return new FriendlyErrorInfo(
                "That computer is not reachable",
                "It has to be awake with tokenstat running, and set up for remote "
                + "reach. If this worked before, wake it and try again. If it never worked, on that computer open Devices and turn on \"Reach devices from "
                + "anywhere\". Until that is on, it never tells the relay where it is.",
                raw,
                ActionTitle: "Try again",
                Symbol: Symbol.Globe);
        }

        // Nothing matched. Say that something failed and show the words the
        // machine used, rather than inventing a cause.
        return new FriendlyErrorInfo(
            "That did not work",
            string.IsNullOrEmpty(raw) ? "Something went wrong and nothing said what." : raw,
            raw,
            ActionTitle: "Try again",
            Symbol: Symbol.Important);
    }
}
