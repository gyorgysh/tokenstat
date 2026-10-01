// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using Microsoft.UI.Xaml.Controls;

namespace Tokenstat.Navigation;

internal enum GlobalSection
{
    Home,
    Insights,
    Machines,
    Ssh,
    Search,
    Todo,
    Notes,
    Workflows,
    Automations,
    Account,
    About,
}

internal enum WorkspaceSection
{
    Sessions,
    Chat,
    Changes,
    History,
    Pulls,
    Todo,
    Notes,
    Workflows,
    Automations,
    Files,
    Browser,
    Launcher,
}

/// <summary>
/// The sections of the SSH library. Fixed set, fixed order, the same shape a
/// workspace has. Labels match the Mac sidebar exactly.
/// </summary>
internal enum SSHSection
{
    Hosts,
    Keys,
    Snippets,
    KnownHosts,
    Vault,
}

internal static class Sections
{
    // Home, Insights and Devices stand alone at the top, like the Mac. SSH
    // is an expandable group below the Everywhere rows instead, and Search
    // lives in the footer next to Account until it gets a toolbar home. The
    // Ssh and Search enum cases stay so their routes keep resolving.
    public static readonly GlobalSection[] Standalone =
        [GlobalSection.Home, GlobalSection.Insights, GlobalSection.Machines];

    public static readonly GlobalSection[] Everywhere =
        [GlobalSection.Todo, GlobalSection.Notes, GlobalSection.Workflows, GlobalSection.Automations];

    public static readonly SSHSection[] SshRows =
        [SSHSection.Hosts, SSHSection.Keys, SSHSection.Snippets, SSHSection.KnownHosts, SSHSection.Vault];

    public static string Label(this GlobalSection section) => section switch
    {
        GlobalSection.Home => L10n.Text("common.home"),
        GlobalSection.Insights => L10n.Text("common.insights"),
        GlobalSection.Machines => L10n.Text("common.devices"),
        GlobalSection.Ssh => L10n.Text("windows.route.ssh.01c4d3c2"),
        GlobalSection.Search => L10n.Text("common.search"),
        GlobalSection.Todo => L10n.Text("common.tasks"),
        GlobalSection.Notes => L10n.Text("common.notes"),
        GlobalSection.Workflows => L10n.Text("common.workflows"),
        GlobalSection.Automations => L10n.Text("common.automations"),
        GlobalSection.Account => L10n.Text("common.account"),
        GlobalSection.About => L10n.Text("windows.route.about.4efca0d1"),
        _ => section.ToString(),
    };

    public static Symbol Symbol(this GlobalSection section) => section switch
    {
        GlobalSection.Home => Microsoft.UI.Xaml.Controls.Symbol.Home,
        GlobalSection.Insights => Microsoft.UI.Xaml.Controls.Symbol.FourBars,
        GlobalSection.Machines => Microsoft.UI.Xaml.Controls.Symbol.CellPhone,
        GlobalSection.Ssh => Microsoft.UI.Xaml.Controls.Symbol.Link,
        GlobalSection.Search => Microsoft.UI.Xaml.Controls.Symbol.Find,
        GlobalSection.Todo => Microsoft.UI.Xaml.Controls.Symbol.AllApps,
        GlobalSection.Notes => Microsoft.UI.Xaml.Controls.Symbol.OpenFile,
        GlobalSection.Workflows => Microsoft.UI.Xaml.Controls.Symbol.Switch,
        GlobalSection.Automations => Microsoft.UI.Xaml.Controls.Symbol.Flag,
        GlobalSection.Account => Microsoft.UI.Xaml.Controls.Symbol.Contact,
        GlobalSection.About => Microsoft.UI.Xaml.Controls.Symbol.Help,
        _ => Microsoft.UI.Xaml.Controls.Symbol.Placeholder,
    };

    public static string Label(this WorkspaceSection section) => section switch
    {
        WorkspaceSection.Launcher => L10n.Text("windows.route.launcher.22614ace"),
        WorkspaceSection.Sessions => L10n.Text("common.terminals"),
        WorkspaceSection.Chat => L10n.Text("common.chats"),
        WorkspaceSection.Changes => L10n.Text("windows.route.changes.bbd4b6a8"),
        WorkspaceSection.History => L10n.Text("common.history"),
        WorkspaceSection.Pulls => L10n.Text("windows.route.pull_requests.d9e3f260"),
        WorkspaceSection.Todo => L10n.Text("common.tasks"),
        WorkspaceSection.Notes => L10n.Text("common.notes"),
        WorkspaceSection.Workflows => L10n.Text("common.workflows"),
        WorkspaceSection.Automations => L10n.Text("common.automations"),
        WorkspaceSection.Files => L10n.Text("common.files"),
        WorkspaceSection.Browser => L10n.Text("common.browser"),
        _ => section.ToString(),
    };

    public static Tokenstat.Design.ActionIcon Action(this WorkspaceSection section) => section switch
    {
        WorkspaceSection.Sessions => Tokenstat.Design.ActionIcon.Run,
        WorkspaceSection.Chat => Tokenstat.Design.ActionIcon.Comment,
        WorkspaceSection.Changes => Tokenstat.Design.ActionIcon.Compare,
        WorkspaceSection.History => Tokenstat.Design.ActionIcon.History,
        WorkspaceSection.Pulls => Tokenstat.Design.ActionIcon.Merge,
        WorkspaceSection.Todo => Tokenstat.Design.ActionIcon.Plan,
        WorkspaceSection.Notes => Tokenstat.Design.ActionIcon.Docs,
        WorkspaceSection.Workflows => Tokenstat.Design.ActionIcon.Move,
        WorkspaceSection.Automations => Tokenstat.Design.ActionIcon.Scheduled,
        WorkspaceSection.Files => Tokenstat.Design.ActionIcon.Reveal,
        WorkspaceSection.Browser => Tokenstat.Design.ActionIcon.Browser,
        _ => Tokenstat.Design.ActionIcon.Home,
    };

    public static string Label(this SSHSection section) => section switch
    {
        SSHSection.Hosts => L10n.Text("windows.route.hosts.bba9af13"),
        SSHSection.Keys => L10n.Text("windows.route.keys.f0d66a79"),
        SSHSection.Snippets => L10n.Text("windows.route.snippets.ff717209"),
        SSHSection.KnownHosts => L10n.Text("windows.route.trusted_servers.b101ed86"),
        _ => section.ToString(),
    };
}
