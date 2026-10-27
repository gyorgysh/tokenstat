// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Tokenstat.Pages;

namespace Tokenstat;

public sealed partial class MainWindow
{
    private Dictionary<string, List<JsonObject>> _teamFolderLinks = new(StringComparer.Ordinal);
    private long _teamFolderRead;
    private async Task RefreshTeamFolderLinksAsync(bool clear = false)
    {
        var read = ++_teamFolderRead; var generation = AppServices.AccountGeneration;
        if (clear && _teamFolderLinks.Count > 0) { _teamFolderLinks.Clear(); RebuildFolderItems(); }
        try
        {
            var client = await TeamFolderClientAsync();
            if (read != _teamFolderRead || generation != AppServices.AccountGeneration) return;
            if (client is null) { _teamFolderLinks.Clear(); RebuildFolderItems(); return; }
            var rows = new List<JsonObject>(); var offset = 0;
            while (true)
            {
                var page = TeamDirectoryPage.Read(await client.Call("teams.checkout.list", new() { ["page"] = new JsonObject { ["limit"] = 100, ["offset"] = offset } }), "publications", offset);
                if (read != _teamFolderRead || generation != AppServices.AccountGeneration) return;
                rows = TeamCatalogPage.Append(rows, page.Rows); if (page.Next is not { } next) break; offset = next;
            }
            var links = rows.Where(row => Format.Text(row, "phase") == "active" && !Format.Flag(row, "accountCleanupPending") && Format.Text(row, "workspaceId").Length > 0)
                .GroupBy(row => Format.Text(row, "workspaceId"), StringComparer.Ordinal).ToDictionary(group => group.Key, group => group.ToList(), StringComparer.Ordinal);
            var same = _teamFolderLinks.Count == links.Count && links.All(pair => _teamFolderLinks.TryGetValue(pair.Key, out var prior) && prior.Count == pair.Value.Count
                && prior.Zip(pair.Value).All(pair => JsonNode.DeepEquals(pair.First, pair.Second)));
            if (!same) { _teamFolderLinks = links; RebuildFolderItems(); }
        }
        catch { /* An offline read keeps the current account's local markers. */ }
    }
    private static async Task<TeamDirectoryClient?> TeamFolderClientAsync()
    {
        var account = await AppServices.Host.CallAsync("account.status");
        var scope = SshVaultScope.From(account);
        return scope is null ? null
            : new TeamDirectoryClient(scope, Format.Text(account, "accountSession"), Format.Text(account, "accountId"), (method, fields) => AppServices.Host.CallAsync(method, fields));
    }
    /// Ends every team publication of one folder on this computer. Only the
    /// sharing ends: the folder, its chats and its history stay as they are.
    private async Task StopSharingTeamFolderAsync(string id, string name, UIElement owner)
    {
        if (_teamFolderLinks.GetValueOrDefault(id) is not { Count: > 0 } publications) return;
        var confirm = new ContentDialog { Title = L10n.Text("common.teams.stop_sharing_project", name), Content = L10n.Text("common.teams.stop_sharing_project_detail", name),
            PrimaryButtonText = L10n.Text("common.teams.stop_sharing"), CloseButtonText = L10n.Text("common.cancel"), DefaultButton = ContentDialogButton.Close };
        if (await Chrome.ShowDialog(owner, confirm) != ContentDialogResult.Primary) return;
        var cleanupPending = false;
        try
        {
            var client = await TeamFolderClientAsync() ?? throw new InvalidOperationException(L10n.Text("common.teams.load_failed"));
            foreach (var row in publications)
            {
                var answer = await client.Call("teams.checkout.withdraw", new() { ["checkout"] = Format.Text(row, "id"), ["expectedRevision"] = TeamManagementModel.Revision(row) });
                TeamManagementModel.Require(Format.Flag(answer, "withdrawn"));
                cleanupPending |= Format.Flag(answer, "accountCleanupPending");
            }
            if (cleanupPending)
                await Chrome.ShowDialog(owner, new ContentDialog { Title = L10n.Text("common.teams.sharing_stopped"), Content = L10n.Text("common.teams.cleanup_pending"), CloseButtonText = L10n.Text("common.done") });
        }
        catch (Exception ex)
        {
            await Chrome.ShowDialog(owner, new ContentDialog { Title = L10n.Text("common.teams.stop_sharing_failed"), Content = ex.Message, CloseButtonText = L10n.Text("common.close") });
        }
        // Some may have stopped before a failure. Show what is true now.
        AppServices.NotifyTeamProjectsChanged();
        await TryLoadFoldersAsync(refresh: true);
    }
    private void OpenTeamFolder(string id, string name, string path, bool shareNew = false)
    {
        _lastNavTag = "teams:projects"; UpdateRail(_lastNavTag);
        var shared = shareNew ? null : _teamFolderLinks.GetValueOrDefault(id);
        if (shared is { Count: 1 }) SetContent(new TeamsPage(null, initialProject: new JsonObject {
            ["id"] = Format.Text(shared[0], "repositoryId"), ["organizationId"] = Format.Text(shared[0], "organizationId"),
        }), preserveSelection: true);
        else if (shared is { Count: > 1 }) SetContent(new TeamsPage(null, sharedProjects: true), preserveSelection: true);
        else SetContent(new TeamsPage(null, folder: new JsonObject { ["id"] = id, ["name"] = name, ["path"] = path }), preserveSelection: true);
    }
}
