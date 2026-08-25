// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using Tokenstat.Host;
using Tokenstat.Install;

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
}
