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
    Pulls,
    Todo,
    Notes,
    Workflows,
    Automations,
    Files,
    Browser,
}

internal static class Sections
{
    public static readonly GlobalSection[] Standalone =
        [GlobalSection.Home, GlobalSection.Insights, GlobalSection.Machines, GlobalSection.Ssh];

    public static readonly GlobalSection[] Everywhere =
        [GlobalSection.Todo, GlobalSection.Notes, GlobalSection.Workflows, GlobalSection.Automations];

    public static string Label(this GlobalSection section) => section switch
    {
        GlobalSection.Home => "Home",
        GlobalSection.Insights => "Insights",
        GlobalSection.Machines => "Devices",
        GlobalSection.Ssh => "SSH",
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
        WorkspaceSection.Pulls => "Pull requests",
        WorkspaceSection.Todo => "Tasks",
        WorkspaceSection.Notes => "Notes",
        WorkspaceSection.Workflows => "Workflows",
        WorkspaceSection.Automations => "Automations",
        WorkspaceSection.Files => "Files",
        WorkspaceSection.Browser => "Browser",
        _ => section.ToString(),
    };
}
