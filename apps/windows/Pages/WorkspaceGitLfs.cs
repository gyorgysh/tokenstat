// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Tokenstat.Navigation;

namespace Tokenstat.Pages;

internal sealed record WorkspaceGitLfs(bool Installed, bool Configured, bool CanInstall)
{
    public bool Ready => Installed && Configured;
    public bool CanSetup => !Ready && (Installed || CanInstall);

    public static WorkspaceGitLfs? Read(JsonNode? review) => review?["lfs"] is JsonObject status
        ? new(Format.Flag(status, "installed"), Format.Flag(status, "configured"), Format.Flag(status, "canInstall"))
        : null;

    public string SetupLabel => Installed ? L10n.Text("windows.gitlfs.enable") : L10n.Text("windows.gitlfs.install");

    public Task SetupAsync(string workspaceId) => RemoteWorkspaces.CallWorkspaceAsync(
        workspaceId, "workspace.lfsSetup", new JsonObject { ["id"] = workspaceId, ["allowInstall"] = !Installed && CanInstall },
        TimeSpan.FromMinutes(3));

    public UIElement Card()
    {
        var message = Ready ? L10n.Text("windows.gitlfs.ready") : Installed ? L10n.Text("windows.gitlfs.enable_help")
            : CanInstall ? L10n.Text("windows.gitlfs.install_help") : L10n.Text("windows.gitlfs.manual_help");
        var body = new StackPanel { Spacing = Theme.SpaceS };
        body.Children.Add(new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap });
        if (!Ready && !CanSetup)
        {
            body.Children.Add(new HyperlinkButton
            {
                Content = L10n.Text("windows.gitlfs.guide"),
                NavigateUri = new Uri("https://git-lfs.com/"),
            });
        }
        return Chrome.Card(L10n.Text("windows.gitlfs.title"), body);
    }
}
