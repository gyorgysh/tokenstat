// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Tokenstat.Design;
using Tokenstat.Pages;

namespace Tokenstat.Navigation;

/// <summary>
/// Live sidebar content under each folder row: session rows, recent chats,
/// section count badges, and the signed-in footer. Mirrors the Mac sidebar:
/// session rows show context percent, cost, tokens, and Idle/Working state,
/// chats show relative ages with Show more and See all entries, and a zero
/// count draws no badge anywhere. Feeds are the same host methods the Mac
/// uses: pty.list, chat.recent, workspace.summary, and account.status.
/// </summary>
internal static class SidebarLive
{
    private static readonly Dictionary<string, JsonArray> RemoteChats = new(StringComparer.Ordinal);

    public const string SessionPrefix = "wsterm:";
    public const string ChatPrefix = "wschat:";
    public const string ChatMorePrefix = "wschatmore:";
    public const string ChatAllPrefix = "wschatall:";

    /// <summary>Chat rows drawn without asking, like the Mac collapsed limit.</summary>
    public const int CollapsedChats = 5;
    /// <summary>Chat rows drawn when expanded, like the Mac inline limit.</summary>
    public const int InlineChats = 10;

    public static bool IsLiveTag(string? tag) =>
        tag is not null
        && (tag.StartsWith(SessionPrefix, StringComparison.Ordinal)
            || tag.StartsWith(ChatPrefix, StringComparison.Ordinal)
            || tag.StartsWith(ChatMorePrefix, StringComparison.Ordinal)
            || tag.StartsWith(ChatAllPrefix, StringComparison.Ordinal));

    /// <summary>
    /// Split a live row tag into its folder id and leaf id. Both ids may
    /// carry a remote namespace, so each component is escaped separately.
    /// </summary>
    public static bool TrySplit(string tag, string prefix, out string folderId, out string leaf) =>
        LiveRoute.TrySplit(tag, prefix, out folderId, out leaf);

    /// <summary>
    /// The fast poll: live sessions and recent chats. Null on a failed call,
    /// so a transient failure keeps the current rows instead of clearing them.
    /// </summary>
    public static async Task<(JsonArray? Sessions, JsonArray? Chats)> FetchFastAsync()
    {
        JsonArray? sessions = null;
        JsonArray? chats = null;
        try
        {
            sessions = Format.Items(await AppServices.Host.CallAsync("pty.list"));
        }
        catch
        {
            // Quiet poll: a missed tick keeps the last rows.
        }
        try
        {
            chats = Format.Items(await AppServices.Host.CallAsync(
                "chat.recent", new JsonObject { ["limit"] = 50 }));
        }
        catch
        {
            // Same: nothing new is not the same as nothing there.
        }
        var peers = RemoteWorkspaces.CachedFolders().Select(folder => folder.PeerKey).Distinct().ToArray();
        foreach (var gone in RemoteChats.Keys.Except(peers).ToArray()) RemoteChats.Remove(gone);
        foreach (var peer in peers)
        {
            try
            {
                var recent = Format.Items(await RemoteWorkspaces.CallOnPeerAsync(peer,
                    "chat.recent", new JsonObject { ["limit"] = 100 }, TimeSpan.FromSeconds(5)));
                if (recent is null) continue;
                var mapped = new JsonArray();
                foreach (var item in recent)
                {
                    if (item?.DeepClone() is not JsonObject chat) continue;
                    var folder = Format.Text(chat, "workspaceId");
                    if (string.IsNullOrEmpty(folder)) continue;
                    chat["workspaceId"] = RemoteWorkspaces.Join(peer, folder);
                    mapped.Add(chat);
                }
                RemoteChats[peer] = mapped;
            }
            catch { /* Keep that peer's last known chats on a missed poll. */ }
        }
        if (chats is not null)
        {
            chats = (JsonArray)chats.DeepClone();
            foreach (var remote in RemoteChats.Values)
                foreach (var chat in remote) chats.Add(chat?.DeepClone());
        }
        return (sessions, chats);
    }

    /// <summary>
    /// The slow poll: per-folder counts and the signed-in account. One call
    /// each, like the Mac summary read, so badges never cost a call per folder.
    /// </summary>
    public static async Task<(Dictionary<string, JsonNode>? Summaries, JsonNode? Account)> FetchSlowAsync()
    {
        Dictionary<string, JsonNode>? summaries = null;
        JsonNode? account = null;
        try
        {
            var listed = Format.Items(await AppServices.Host.CallAsync("workspace.summary"));
            if (listed is not null)
            {
                summaries = new Dictionary<string, JsonNode>(StringComparer.Ordinal);
                foreach (var row in listed)
                {
                    var id = Format.Text(row, "id");
                    if (!string.IsNullOrEmpty(id) && row is not null)
                    {
                        summaries[id] = row;
                    }
                }
            }
        }
        catch
        {
            // Badges keep their last counts until the next slow tick.
        }
        try
        {
            account = await AppServices.Host.CallAsync("account.status");
        }
        catch
        {
            // The footer keeps whoever it was showing.
        }
        return (summaries, account);
    }

    /// <summary>What a section badge says. Zero draws nothing, like the Mac.</summary>
    public static int SectionCount(WorkspaceSection section, JsonNode? summary)
    {
        if (summary is null)
        {
            return 0;
        }
        return section switch
        {
            WorkspaceSection.Sessions => (int)Format.Long(summary, "sessions"),
            WorkspaceSection.Chat => (int)Format.Long(summary, "chats"),
            WorkspaceSection.Changes => (int)Format.Long(summary, "changed"),
            WorkspaceSection.History => 0,
            WorkspaceSection.Pulls => (int)Format.Long(summary, "pulls"),
            WorkspaceSection.Todo => (int)Format.Long(summary, "tasks"),
            WorkspaceSection.Notes => (int)Format.Long(summary, "notes"),
            WorkspaceSection.Workflows => WorkflowsCount(summary),
            WorkspaceSection.Automations => (int)Format.Long(summary, "automations"),
            WorkspaceSection.Files => 0,
            // The Mac counts its own open tabs here, which have no host feed.
            WorkspaceSection.Browser => 0,
            _ => 0,
        };
    }

    private static int WorkflowsCount(JsonNode summary)
    {
        var running = (int)Format.Long(summary, "workflowsRunning");
        return running > 0 ? running : (int)Format.Long(summary, "workflows");
    }

    public static void ApplyCount(NavigationViewItem row, int count)
    {
        row.InfoBadge = count > 0 ? new InfoBadge { Value = count } : null;
    }

    /// <summary>
    /// One live session row: title, meter line, and state. Tag routes to the
    /// session's terminal through the sidebar selection handler.
    /// </summary>
    public static NavigationViewItem SessionItem(string folderId, JsonNode item)
    {
        var id = Format.Text(item, "id");
        var command = Format.Text(item, "command", "shell");
        var title = SessionTitle(command);
        var (state, tint) = SessionState(item);
        var stats = SessionStats(item) ?? command;
        if (state == "Idle")
        {
            var since = Format.Long(item, "lastActivityAtMs");
            if (item["lastActivityAtMs"] is not null && since > 0)
            {
                state += " · " + RelativeShort(since);
            }
        }

        var panel = new StackPanel { Spacing = 3, Margin = new Thickness(0, 4, 0, 4) };
        panel.Children.Add(new TextBlock
        {
            Text = title,
            FontSize = 13,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxLines = 1,
        });
        if (Format.Number(item, "contextWindow") > 0)
            panel.Children.Add(new ProgressBar
            {
                Minimum = 0, Maximum = 100,
                Value = Math.Clamp(100 * Format.Number(item, "contextUsed") / Format.Number(item, "contextWindow"), 0, 100),
                Height = 3, Foreground = Theme.AccentBrush, Background = Theme.BorderBrush,
            });
        panel.Children.Add(new TextBlock
        {
            Text = stats,
            FontSize = 11,
            FontFamily = Fonts.Mono,
            Opacity = 0.7,
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxLines = 1,
        });
        var stateRow = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 5,
        };
        stateRow.Children.Add(new Ellipse
        {
            Width = 7,
            Height = 7,
            Fill = Theme.Brush(tint),
            VerticalAlignment = VerticalAlignment.Center,
        });
        stateRow.Children.Add(new TextBlock
        {
            Text = state,
            FontSize = 11,
            Foreground = Theme.Brush(tint),
            MaxLines = 1,
        });
        panel.Children.Add(stateRow);

        var row = new NavigationViewItem
        {
            Content = AgentMark.Row(command, panel),
            Tag = LiveRoute.Join(SessionPrefix, folderId, id),
        };
        if (row.Content is FrameworkElement view)
            view.Tag = (title, stats, state, command, Format.Number(item, "contextUsed"), Format.Number(item, "contextWindow"));
        AutomationProperties.SetName(row, title + ". " + stats + ". " + state);
        var cwd = Format.Text(item, "cwd");
        if (!string.IsNullOrEmpty(cwd))
        {
            ToolTipService.SetToolTip(row, cwd);
        }
        var menu = ContextMenus.Menu(row);
        ContextMenus.AddAsync(menu, "Stop and close…", async () =>
        {
            var owner = menu.Target ?? row;
            var confirm = new ContentDialog { Title = "Stop this session?", Content = "The running process will stop.", PrimaryButtonText = "Stop and close", CloseButtonText = "Keep running", DefaultButton = ContentDialogButton.Close };
            if (await Chrome.ShowDialog(owner, confirm) != ContentDialogResult.Primary) return;
            try { await AppServices.Host.CallAsync("pty.close", new JsonObject { ["id"] = id }); }
            catch (Exception ex) { await Chrome.ShowDialog(owner, new ContentDialog { Title = "Could not close session", Content = ex.Message, CloseButtonText = "Close" }); }
        });
        return row;
    }

    /// <summary>
    /// One recent conversation row: title, backend and age. Tapping opens the
    /// conversation in its folder chat, like the Mac sidebar row.
    /// </summary>
    public static NavigationViewItem ChatItem(string folderId, JsonNode chat)
    {
        var id = Format.Text(chat, "id");
        var title = Format.Text(chat, "title");
        if (string.IsNullOrEmpty(title))
        {
            title = "Untitled conversation";
        }
        var backend = HarnessName(Format.Text(chat, "backend"));
        var running = Format.Flag(chat, "running");
        var detail = backend;
        if (running)
        {
            detail += " · Working";
        }
        var ms = LastMessageMs(chat);
        if (ms is not null)
        {
            detail += " · " + RelativeShort(ms.Value);
        }

        var panel = new StackPanel { Spacing = 3, Margin = new Thickness(0, 4, 0, 4) };
        var heading = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
        };
        if (running)
        {
            heading.Children.Add(new Ellipse
            {
                Width = 6,
                Height = 6,
                Fill = Theme.AccentBrush,
                VerticalAlignment = VerticalAlignment.Center,
            });
        }
        heading.Children.Add(new TextBlock
        {
            Text = title,
            FontSize = 12,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxLines = 1,
        });
        panel.Children.Add(heading);
        panel.Children.Add(new TextBlock
        {
            Text = detail,
            FontSize = 11,
            Opacity = 0.7,
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxLines = 1,
        });

        var row = new NavigationViewItem
        {
            Content = AgentMark.Row(Format.Text(chat, "backend"), panel),
            Tag = LiveRoute.Join(ChatPrefix, folderId, id),
        };
        if (row.Content is FrameworkElement view) view.Tag = (title, detail, backend);
        AutomationProperties.SetName(row, title + ". " + detail);
        ToolTipService.SetToolTip(row, title + " · " + backend);
        var menu = ContextMenus.Menu(row);
        ContextMenus.AddAsync(menu, "Remove chat…", async () =>
        {
            var owner = menu.Target ?? row;
            var confirm = new ContentDialog { Title = "Remove this chat?", Content = "This permanently deletes the transcript.", PrimaryButtonText = "Remove chat", CloseButtonText = "Keep it", DefaultButton = ContentDialogButton.Close };
            if (await Chrome.ShowDialog(owner, confirm) != ContentDialogResult.Primary) return;
            try
            {
                var parameters = new JsonObject { ["id"] = id };
                if (RemoteWorkspaces.TrySplit(folderId, out var peer, out _)) await RemoteWorkspaces.CallOnPeerAsync(peer, "chat.remove", parameters);
                else await AppServices.Host.CallAsync("chat.remove", parameters);
            }
            catch (Exception ex) { await Chrome.ShowDialog(owner, new ContentDialog { Title = "Could not remove chat", Content = ex.Message, CloseButtonText = "Close" }); }
        });
        return row;
    }

    /// <summary>A quiet expander row: Show N more, Show less, See all chats.</summary>
    public static NavigationViewItem ActionItem(string tag, string label)
    {
        var row = new NavigationViewItem
        {
            Content = new TextBlock
            {
                Text = label,
                FontSize = 11,
                FontWeight = Microsoft.UI.Text.FontWeights.Medium,
                Opacity = 0.7,
                Margin = new Thickness(8, 2, 0, 2),
                MaxLines = 1,
            },
            Tag = tag,
        };
        if (row.Content is FrameworkElement view) view.Tag = label;
        AutomationProperties.SetName(row, label);
        return row;
    }

    /// <summary>
    /// Who is signed in: avatar, name and tier badge, with a menu affordance.
    /// </summary>
    public static UIElement AccountFooter(JsonNode account, Action onOpen)
    {
        var handle = Format.Text(account, "handle");
        var name = Format.Text(account, "displayName", handle);
        if (string.IsNullOrEmpty(name))
        {
            name = "Signed in";
        }
        var tier = Format.Text(account, "tier");
        var avatar = Format.Text(account, "avatar");

        var row = new Grid { VerticalAlignment = VerticalAlignment.Center };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        if (!string.IsNullOrEmpty(tier))
        {
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        }
        var face = Marks.Avatar(url: avatar, name: name, handle: handle, size: 22);
        face.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(face, 0);
        row.Children.Add(face);
        var label = new TextBlock
        {
            Text = name,
            FontSize = 13,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(8, 0, 0, 0),
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxLines = 1,
        };
        Grid.SetColumn(label, 1);
        row.Children.Add(label);
        if (!string.IsNullOrEmpty(tier))
        {
            var badge = Chrome.TierBadge(tier);
            badge.VerticalAlignment = VerticalAlignment.Center;
            badge.Margin = new Thickness(8, 0, 0, 0);
            Grid.SetColumn(badge, 2);
            row.Children.Add(badge);
        }

        var chevronColumn = row.ColumnDefinitions.Count;
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var chevron = new FontIcon { Glyph = "\uE70D", FontSize = 10, Margin = new Thickness(8, 0, 0, 0) };
        Grid.SetColumn(chevron, chevronColumn);
        row.Children.Add(chevron);

        var open = new Button
        {
            Content = row,
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0, 1, 0, 0),
            BorderBrush = Theme.BorderBrush,
            Padding = new Thickness(12, 8, 12, 8),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
        };
        open.Click += (_, _) => onOpen();
        AutomationProperties.SetName(open, "Account: " + name);
        ToolTipService.SetToolTip(
            open, string.IsNullOrEmpty(handle) ? "Account" : "@" + handle);
        return open;
    }

    /// <summary>
    /// The session title: the harness name for an agent command, else the
    /// launched basename. Same mapping the Mac rows use.
    /// </summary>
    public static string SessionTitle(string command)
    {
        var baseName = command;
        var slash = Math.Max(baseName.LastIndexOf('/'), baseName.LastIndexOf('\\'));
        if (slash >= 0 && slash + 1 < baseName.Length)
        {
            baseName = baseName[(slash + 1)..];
        }
        if (string.IsNullOrEmpty(baseName))
        {
            baseName = command;
        }
        var id = HarnessIdForCommand(baseName);
        return id is null ? baseName : HarnessName(id);
    }

    /// <summary>
    /// What the session is doing: the host attention flag first, then its
    /// working/idle verdict. Absent means the sampler has not reached it yet,
    /// which reads as Starting and never as Idle.
    /// </summary>
    public static (string Label, Windows.UI.Color Tint) SessionState(JsonNode item)
    {
        if (!string.IsNullOrEmpty(Format.Text(item, "attention")))
        {
            return ("Needs attention", Theme.Warning);
        }
        return Format.Text(item, "activity") switch
        {
            "working" => ("Working", Theme.StateWorking),
            "idle" => ("Idle", Theme.StateIdle),
            _ => ("Starting", Theme.StateIdle),
        };
    }

    /// <summary>
    /// The meter line: context, cost, tokens in fixed places, like the Mac
    /// row. CPU and RAM stay the fallback before any meter exists.
    /// </summary>
    public static string? SessionStats(JsonNode? item)
    {
        if (item is null)
        {
            return null;
        }
        var tokensNode = item["tokens"];
        if (tokensNode is null || tokensNode.GetValueKind() is JsonValueKind.Null or JsonValueKind.Undefined)
        {
            return ResourceStats(item);
        }
        var tokens = (long)Math.Max(0, Format.Number(item, "tokens"));
        var tokenText = tokens == 0 ? "0k" : Format.Tokens(tokens);
        return ContextText(item) + " · " + Money(item) + " · " + tokenText;
    }

    private static string ContextText(JsonNode item)
    {
        var usedNode = item["contextUsed"];
        if (usedNode is null || usedNode.GetValueKind() is JsonValueKind.Null or JsonValueKind.Undefined)
        {
            return "0% ctx";
        }
        var used = (long)Math.Max(0, Format.Number(item, "contextUsed"));
        var window = (long)Math.Max(0, Format.Number(item, "contextWindow"));
        if (window <= 0)
        {
            return Format.Tokens(used) + " ctx";
        }
        var pct = (int)Math.Round(used / (double)window * 100);
        return (Format.Flag(item, "contextEstimated") ? "~" : "") + pct + "% ctx";
    }

    private static string Money(JsonNode item)
    {
        var amount = Format.ListRate((long)Format.Number(item, "costMicros"));
        var complete = item["costComplete"] is null || Format.Flag(item, "costComplete");
        if (!complete)
        {
            return amount + "+";
        }
        if (Format.Flag(item, "costEstimated"))
        {
            return "~" + amount;
        }
        return amount;
    }

    private static string? ResourceStats(JsonNode item)
    {
        var parts = new List<string>();
        if (item["cpuPercent"] is not null
            && item["cpuPercent"]!.GetValueKind() is not (JsonValueKind.Null or JsonValueKind.Undefined))
        {
            parts.Add("CPU " + (int)Math.Round(Format.Number(item, "cpuPercent")) + "%");
        }
        var memory = Format.Number(item, "memoryMb");
        if (item["memoryMb"] is not null && memory >= 1)
        {
            parts.Add(memory >= 1000
                ? (memory / 1024).ToString("0.0", CultureInfo.InvariantCulture) + " GB"
                : (int)Math.Round(memory) + " MB");
        }
        return parts.Count == 0 ? null : string.Join(" · ", parts);
    }

    private static long? LastMessageMs(JsonNode chat)
    {
        foreach (var key in new[] { "lastMessageAtMs", "updatedAtMs" })
        {
            var node = chat[key];
            if (node is not null && node.GetValueKind() is not (JsonValueKind.Null or JsonValueKind.Undefined))
            {
                var ms = (long)Format.Number(chat, key);
                if (ms > 0)
                {
                    return ms;
                }
            }
        }
        return null;
    }

    /// <summary>A host moment in short relative form, for sidebar rows.</summary>
    public static string RelativeShort(long ms)
    {
        DateTimeOffset moment;
        try
        {
            moment = DateTimeOffset.FromUnixTimeMilliseconds(ms);
        }
        catch
        {
            return "";
        }
        var age = DateTimeOffset.Now - moment;
        if (age < TimeSpan.Zero || age < TimeSpan.FromMinutes(1))
        {
            return "now";
        }
        if (age < TimeSpan.FromHours(1))
        {
            return (int)age.TotalMinutes + "m ago";
        }
        if (age < TimeSpan.FromDays(1))
        {
            return (int)age.TotalHours + "h ago";
        }
        if (age < TimeSpan.FromDays(30))
        {
            return (int)age.TotalDays + "d ago";
        }
        return moment.LocalDateTime.ToString("d", CultureInfo.CurrentCulture);
    }

    /// <summary>Display name for a harness, the same spelling the Mac uses.</summary>
    public static string HarnessName(string id)
    {
        if (id == "opencode2")
        {
            return "OpenCode 2";
        }
        return CanonicalHarnessId(id) switch
        {
            "claude_code" => "Claude Code",
            "claude_code_rollup" or "claude_code_estimate" => "Claude Code (recovered)",
            "codex" => "Codex",
            "grok" => "Grok Build",
            "opencode" => "OpenCode",
            "cline" => "Cline",
            "openclaw" => "OpenClaw",
            "muse" => "Muse",
            "devin" => "Devin CLI",
            "pi" => "Pi",
            "dsh" => "DeepSeek Harness",
            "zed" => "Zed",
            "copilot" => "Copilot CLI",
            "antigravity" => "Antigravity",
            "cursor" => "Cursor",
            "gemini" => "Gemini",
            "hermes" => "Hermes Agent",
            "kilo" => "Kilo Code",
            "kimi" => "Kimi Code",
            "qwen" => "Qwen Code",
            "" => "unknown",
            var other => other,
        };
    }

    private static string CanonicalHarnessId(string id)
    {
        if (id == "agy")
        {
            return "antigravity";
        }
        if (id.StartsWith("antigravity", StringComparison.Ordinal))
        {
            return "antigravity";
        }
        if (id == "claude")
        {
            return "claude_code";
        }
        if (id == "opencode2")
        {
            return "opencode";
        }
        return id;
    }

    private static string? HarnessIdForCommand(string baseName)
    {
        var name = baseName.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)
            ? baseName[..^4]
            : baseName;
        return name switch
        {
            "claude" => "claude_code",
            "codex" => "codex",
            "opencode" or "opencode2" => "opencode",
            "grok" => "grok",
            "copilot" => "copilot",
            "cline" => "cline",
            "openclaw" => "openclaw",
            "muse" => "muse",
            "pi" => "pi",
            "zed" => "zed",
            "agy" => "antigravity",
            "agent" or "cursor" => "cursor",
            "hermes" => "hermes",
            "kilocode" or "kilo" => "kilo",
            _ => null,
        };
    }
}
