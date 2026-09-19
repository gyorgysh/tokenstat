// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Text.Json.Nodes;
using Tokenstat.Host;
using Tokenstat.Install;
using Tokenstat.Navigation;

namespace Tokenstat;

internal static class AppServices
{
    public static HostClient Host { get; } = new();
    public static AppUpdateModel Update { get; } = new();

    /// <summary>
    /// Open a ConPTY page. Workspace id, then a live session id or null to spawn.
    /// Set from MainWindow so a folder's Sessions list can navigate.
    /// </summary>
    public static Action<string, string?>? OpenTerminal { get; set; }

    /// <summary>
    /// Open WebView2 on a loopback URL. Host and port are what
    /// <c>proxy.unlisten</c> needs when this tab opened the listener.
    /// </summary>
    public static Action<string, string, int, bool>? OpenBrowser { get; set; }

    /// <summary>
    /// Open the Legend screen viewer for another host. Peer is that
    /// machine's public identity, then a label for the chrome.
    /// </summary>
    public static Action<string, string>? OpenScreen { get; set; }

    /// <summary>
    /// Show the first-run tour over the current page. Set from MainWindow,
    /// called from About so the tour can be re-opened after onboarding.
    /// </summary>
    public static Action? OpenOnboarding { get; set; }

    /// <summary>
    /// Open a folder section from a search hit. Workspace id, then section.
    /// Set from MainWindow so results return to the folder they live in.
    /// </summary>
    public static Action<string, WorkspaceSection>? OpenWorkspace { get; set; }

    /// <summary>
    /// Open a conversation from Home's Continue list. Workspace id, then the
    /// conversation id. Set from MainWindow, like the Mac opening the recent
    /// in its folder's chat.
    /// </summary>
    public static Action<string, string>? OpenConversation { get; set; }

    /// <summary>
    /// Open Insights for one calendar day (yyyy-MM-dd) from Home's inspector.
    /// Set from MainWindow, like the Mac focusing the pinned day.
    /// </summary>
    public static Action<string>? OpenInsightsDay { get; set; }

    /// <summary>
    /// Store the always-on policy, then bring the host helper's scheduled
    /// task in line with it: registered with a logon trigger when on, removed
    /// when off. One call so the toggle cannot store the policy and forget
    /// the task. Never a Windows Service.
    /// </summary>
    public static async Task ApplyHostPolicyAsync(bool alwaysOn)
    {
        await Host.CallAsync(
            "host.setPolicy",
            new JsonObject { ["alwaysOn"] = alwaysOn });
        await Task.Run(() => SelfInstall.ApplyAlwaysOn(alwaysOn));
    }
}
