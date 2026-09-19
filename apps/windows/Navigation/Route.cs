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
        [SSHSection.Hosts, SSHSection.Keys, SSHSection.Snippets, SSHSection.KnownHosts];

    public static string Label(this GlobalSection section) => section switch
    {
        GlobalSection.Home => "Home",
        GlobalSection.Insights => "Insights",
        GlobalSection.Machines => "Devices",
        GlobalSection.Ssh => "SSH",
        GlobalSection.Search => "Search",
        GlobalSection.Todo => "Tasks",
        GlobalSection.Notes => "Notes",
        GlobalSection.Workflows => "Workflows",
        GlobalSection.Automations => "Automations",
        GlobalSection.Account => "Account",
        GlobalSection.About => "About",
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
        WorkspaceSection.Sessions => "Sessions",
        WorkspaceSection.Chat => "Chat",
        WorkspaceSection.Changes => "Changes",
        WorkspaceSection.History => "History",
        WorkspaceSection.Pulls => "Pull requests",
        WorkspaceSection.Todo => "Tasks",
        WorkspaceSection.Notes => "Notes",
        WorkspaceSection.Workflows => "Workflows",
        WorkspaceSection.Automations => "Automations",
        WorkspaceSection.Files => "Files",
        WorkspaceSection.Browser => "Browser",
        _ => section.ToString(),
    };

    public static string Label(this SSHSection section) => section switch
    {
        SSHSection.Hosts => "Hosts",
        SSHSection.Keys => "Keys",
        SSHSection.Snippets => "Snippets",
        SSHSection.KnownHosts => "Trusted servers",
        _ => section.ToString(),
    };
}
