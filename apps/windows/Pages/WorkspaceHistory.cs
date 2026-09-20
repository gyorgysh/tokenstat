// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;

namespace Tokenstat.Pages;

/// <summary>
/// Commit history for one workspace: a scrolling list, then one commit in
/// full, message first. Matches the Mac history surface: the message is
/// the part people came for and it goes at the top, in full.
/// </summary>
internal static class WorkspaceHistory
{
    /// <summary>
    /// The history card, or null when this folder has no git history to
    /// show. File details come from the selected commit.
    /// </summary>
    public static async Task<UIElement?> LoadCardAsync(
        UIElement owner, string workspaceId)
    {
        JsonNode listed;
        try
        {
            listed = await AppServices.Host.CallAsync(
                "workspace.log",
                new JsonObject { ["id"] = workspaceId, ["limit"] = 100 });
        }
        catch (Exception ex)
        {
            return Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important);
        }
        var array = Format.Items(listed, "commits", "history", "log");
        if (array is null || array.Count == 0)
        {
            return EmptyState.View(
                "No commits yet",
                "Make your first commit and it will appear here.",
                EmptyArtKind.Changes);
        }
        var hasUpstream = false;
        try
        {
            var status = await Tokenstat.Navigation.RemoteWorkspaces.CallWorkspaceAsync(
                workspaceId, "workspace.status", new JsonObject { ["id"] = workspaceId });
            hasUpstream = !string.IsNullOrEmpty(Format.Text(status["git"], "upstream", Format.Text(status, "upstream")));
        }
        catch { /* Do not claim that a commit was pushed without an upstream. */ }
        JsonNode? ownAccount = null;
        string? ownAvatar = null;
        string ownHandle = "", ownName = "";
        try { var status = await AppServices.Host.CallAsync("account.status"); var account = status["account"] ?? status; ownAccount = account; ownAvatar = Format.Text(account, "avatar"); ownHandle = Format.Text(account, "handle"); ownName = Format.Text(account, "displayName"); }
        catch { /* History remains usable while account status is unavailable. */ }
        var ownEmails = await HistoryAvatars.OwnEmailsAsync(ownAccount, array);
        var list = new StackPanel { Spacing = 4 };
        foreach (var commit in array)
        {
            var id = Format.Text(commit, "id");
            if (string.IsNullOrEmpty(id))
            {
                continue;
            }
            var captured = id;
            var subject = Format.Text(commit, "subject", "(no message)");
            var author = Format.Text(commit, "author");
            var moment = RelativeTime(Format.Long(commit, "timestamp"));
            var second = string.Join(" · ", new[]
            {
                author,
                moment,
                WorkspaceGit.ShortId(captured),
            }.Where(part => !string.IsNullOrEmpty(part)));
            if (commit?["tags"] is JsonArray tags && tags.Count > 0)
            {
                // A non-string tag must not take down the whole list. The
                // parse materializes inside the try, so a bad entry lands
                // here instead of at the join below.
                List<string> names;
                try
                {
                    names = tags
                        .Select(tag => tag?.GetValue<string>() ?? "")
                        .Where(tag => !string.IsNullOrEmpty(tag))
                        .ToList();
                }
                catch
                {
                    names = new List<string>();
                }
                var joined = string.Join(", ", names);
                if (!string.IsNullOrEmpty(joined))
                {
                    second += $" · {joined}";
                }
            }
            var unpushed = Format.Flag(commit, "unpushed");
            var body = new StackPanel { Spacing = 4 };
            body.Children.Add(new TextBlock
            {
                Text = subject, FontSize = 13,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap,
            });
            body.Children.Add(new TextBlock { Text = second, FontSize = 11, Opacity = 0.65, TextWrapping = TextWrapping.Wrap });
            body.Children.Add(new TextBlock
            {
                Text = unpushed ? "↑ Not pushed" : hasUpstream ? "✓ On upstream" : "Local history",
                FontSize = 11,
                Foreground = unpushed ? Theme.AccentBrush : Theme.Brush(static () => Theme.DefaultText),
                Opacity = unpushed ? 1 : 0.65,
            });
            var content = new Grid { ColumnSpacing = Theme.SpaceS };
            content.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var avatar = Marks.Avatar(url: ownEmails.Contains(Format.Text(commit, "email")) || Format.Flag(commit, "mine") || (ownHandle.Length > 0 && author.Equals(ownHandle, StringComparison.OrdinalIgnoreCase)) || (ownName.Length > 0 && author.Equals(ownName, StringComparison.OrdinalIgnoreCase)) ? ownAvatar : null, name: author, size: 30);
            avatar.VerticalAlignment = VerticalAlignment.Top;
            content.Children.Add(avatar);
            Grid.SetColumn(body, 1);
            content.Children.Add(body);
            var row = new Button
            {
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Stretch,
                Background = Theme.PanelBrush,
                BorderBrush = Theme.BorderBrush,
                BorderThickness = new Thickness(0, 0, 0, 1),
                Padding = new Thickness(Theme.SpaceS),
                Content = content,
            };
            row.Click += async (_, _) =>
                await ShowDetailAsync(owner, workspaceId, captured);
            list.Children.Add(row);
        }
        return list;
    }

    private static async Task ShowDetailAsync(
        UIElement owner, string workspaceId, string commitId)
    {
        JsonNode detail;
        try
        {
            detail = await AppServices.Host.CallAsync(
                "workspace.show",
                new JsonObject { ["id"] = workspaceId, ["path"] = commitId });
        }
        catch (Exception ex)
        {
            var failed = new ContentDialog
            {
                Title = WorkspaceGit.ShortId(commitId),
                Content = Chrome.Banner(
                    FriendlyError.Display(ex.Message), Theme.Danger, Symbol.Important),
                CloseButtonText = "Close",
            };
            await Chrome.ShowDialog(owner, failed);
            return;
        }
        await WorkspaceDiff.ShowCommitAsync(owner, detail);
    }

    private static string RelativeTime(long unixSeconds)
    {
        if (unixSeconds <= 0)
        {
            return "";
        }
        try
        {
            return Format.Relative(
                DateTimeOffset.FromUnixTimeSeconds(unixSeconds).ToString("o"));
        }
        catch
        {
            return "";
        }
    }

}

/// Git identities are device-local. A commit recognised as ours on another
/// linked computer can identify the same author here without changing Git config.
internal static class HistoryAvatars
{
    private static readonly Dictionary<string, (DateTime At, Task<Dictionary<string, string>> Task)> Cache = new();
    internal static async Task<HashSet<string>> OwnEmailsAsync(JsonNode? account, JsonArray commits)
    {
        var own = commits.Where(c => Format.Flag(c, "mine"))
            .Select(c => Format.Text(c, "email")).Where(e => e.Length > 0).ToHashSet(StringComparer.OrdinalIgnoreCase);
        if (account is null || string.IsNullOrEmpty(Format.Text(account, "avatar"))) return own;
        var accountId = Format.Text(account, "host") + ":" + Format.Text(account, "accountId", Format.Text(account, "handle"));
        var peers = (Format.Items(account, "machines") ?? new JsonArray())
            .Select(m => Format.Text(m, "publicIdentity")).Where(p => p.Length > 0).ToHashSet();
        var ids = commits.Select(c => Format.Text(c, "id")).ToHashSet();
        var folders = Tokenstat.Navigation.RemoteWorkspaces.CachedFolders()
            .Where(f => peers.Contains(f.PeerKey)).Take(8).ToList();
        var loads = folders.Select(async folder =>
        {
            var key = accountId + ":" + folder.Id + ":" + Format.Text(commits.FirstOrDefault(), "id");
            if (!Cache.TryGetValue(key, out var cached) || DateTime.UtcNow - cached.At > TimeSpan.FromMinutes(5))
            {
                async Task<Dictionary<string, string>> Fetch()
                {
                    var emails = new Dictionary<string, string>(StringComparer.Ordinal);
                    try
                    {
                        var log = await Tokenstat.Navigation.RemoteWorkspaces.CallOnPeerAsync(folder.PeerKey,
                            "workspace.log", new JsonObject { ["id"] = folder.InnerId, ["limit"] = 100 }, TimeSpan.FromSeconds(3));
                        foreach (var c in Format.Items(log, "commits", "history", "log") ?? new JsonArray())
                            if (Format.Flag(c, "mine") && Format.Text(c, "id").Length > 0 && Format.Text(c, "email") is { Length: > 0 } email)
                                emails[Format.Text(c, "id")] = email;
                    }
                    catch { /* Offline computers do not delay or erase local history. */ }
                    return emails;
                }
                cached = (DateTime.UtcNow, Fetch());
                Cache[key] = cached;
                foreach (var old in Cache.OrderByDescending(pair => pair.Value.At).Skip(64).Select(pair => pair.Key).ToArray()) Cache.Remove(old);
            }
            return await cached.Task;
        });
        foreach (var emails in await Task.WhenAll(loads))
            own.UnionWith(emails.Where(pair => ids.Contains(pair.Key)).Select(pair => pair.Value));
        return own;
    }
}
