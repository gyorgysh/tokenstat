// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Text.Json.Nodes;
using Tokenstat.Host;
using Tokenstat.Install;
using Tokenstat.Navigation;

namespace Tokenstat;

internal static class AppServices
{
    private static readonly SemaphoreSlim HostPolicyGate = new(1, 1);

    public static HostClient Host { get; } = new(HostProcess.RecoverIfMissing);
    public static event Action? AccountChanged;
    private static long _accountGeneration;
    public static long AccountGeneration => Interlocked.Read(ref _accountGeneration);
    public static void NotifyAccountChanged()
    {
        Interlocked.Increment(ref _accountGeneration);
        AccountChanged?.Invoke();
    }
    public static event Action? ConversationsChanged;
    public static void NotifyConversationsChanged() => ConversationsChanged?.Invoke();
    public static event Action? TeamProjectsChanged;
    public static void NotifyTeamProjectsChanged() => TeamProjectsChanged?.Invoke();

    public static AppUpdateModel Update { get; } = new();

    public static Action<string, string?>? OpenTerminal { get; set; }
    public static Action<string, string>? OpenTerminalSplit { get; set; }
    public static Action<DesktopOpenRequest>? OpenDesktopAction { get; set; }

    public static Action<string>? OpenMachine { get; set; }

    public static Action? OpenServers { get; set; }

    public static Action<string, string, int, bool, string?>? OpenBrowser { get; set; }

    public static Action<string, string>? OpenScreen { get; set; }

    public static Action? OpenOnboarding { get; set; }

    public static Action<string, WorkspaceSection>? OpenWorkspace { get; set; }

    public static Action<string, long>? OpenPull { get; set; }

    public static Action<string, string>? OpenConversation { get; set; }
    public static Action<string?>? OpenNewChat { get; set; }

    public static Action<string>? OpenInsightsDay { get; set; }

    public static async Task ApplyHostPolicyAsync(bool alwaysOn)
    {
        await HostPolicyGate.WaitAsync();
        try
        {
            await Host.CallAsync(
                "host.setPolicy",
                new JsonObject { ["alwaysOn"] = alwaysOn });
            await Task.Run(() => SelfInstall.ApplyAlwaysOn(alwaysOn));
        }
        finally
        {
            HostPolicyGate.Release();
        }
    }
}
