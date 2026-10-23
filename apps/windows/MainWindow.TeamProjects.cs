// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
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
            var account = await AppServices.Host.CallAsync("account.status");
            if (read != _teamFolderRead || generation != AppServices.AccountGeneration) return;
            var scope = SshVaultScope.From(account);
            if (scope is null) { _teamFolderLinks.Clear(); RebuildFolderItems(); return; }
            var client = new TeamDirectoryClient(scope, Format.Text(account, "accountSession"), Format.Text(account, "accountId"), (method, fields) => AppServices.Host.CallAsync(method, fields));
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
