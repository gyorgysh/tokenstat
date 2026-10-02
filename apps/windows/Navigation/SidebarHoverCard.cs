// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Globalization;
using System.Text.Json.Nodes;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Tokenstat.Design;
using Tokenstat.Pages;

namespace Tokenstat.Navigation;

/// <summary>Readable identity and usage; the Git inset alone carries a violet background.</summary>
internal static class SidebarHoverCard
{
    private sealed record Field(string Label, string Value, bool Numeric = false);
    private static string Text(string key) => key switch
    {
        "ready" => L10n.Text("windows.sidebarhovercard.ready"),
        "this_computer" => L10n.Text("windows.sidebarhovercard.this_computer"),
        "other_computer" => L10n.Text("windows.sidebarhovercard.other_computer"),
        "cached_tokens" => L10n.Text("windows.sidebarhovercard.cached_tokens"),
        "last_message" => L10n.Text("windows.sidebarhovercard.last_message"),
        "no_messages" => L10n.Text("windows.sidebarhovercard.no_messages"),
        "usage_unavailable" => L10n.Text("windows.sidebarhovercard.usage_unavailable"),
        "usage_not_reported" => L10n.Text("windows.sidebarhovercard.usage_not_reported"),
        "context" => L10n.Text("windows.sidebarhovercard.context"),
        "last_activity" => L10n.Text("windows.sidebarhovercard.last_activity"),
        "changed_files" => L10n.Text("windows.sidebarhovercard.changed_files"),
        "upstream" => L10n.Text("windows.sidebarhovercard.upstream"),
        "detached_head" => L10n.Text("windows.sidebarhovercard.detached_head"),
        "partial_counts" => L10n.Text("windows.sidebarhovercard.partial_counts"),
        _ => key,
    };
    private static string Number(double value) => value.ToString("N0", CultureInfo.CurrentCulture);
    private static string Date(long milliseconds, string missing)
    {
        try { return milliseconds > 0 ? DateTimeOffset.FromUnixTimeMilliseconds(milliseconds).LocalDateTime.ToString("g") : missing; }
        catch (ArgumentOutOfRangeException) { return missing; }
    }
    private static Task<JsonNode> Call(string workspaceId, string method, JsonObject parameters) =>
        RemoteWorkspaces.TrySplit(workspaceId, out var peer, out _) ? RemoteWorkspaces.CallOnPeerAsync(peer, method, parameters, TimeSpan.FromSeconds(5)) : AppServices.Host.CallAsync(method, parameters);

    public static void AttachChat(FrameworkElement row, string workspaceId, JsonNode chat, string folderName, JsonNode? folder = null)
    {
        SidebarHoverPresenter.Attach(row, async token =>
        {
            JsonNode? usage = null; JsonNode? conversation = chat; var failed = false;
            async Task ReadUsage()
            {
                try { usage = (await Call(workspaceId, "chat.eventPage", new() { ["id"] = Format.Text(chat, "id"), ["limit"] = 1, ["stablePositions"] = true }))["usage"]; }
                catch { failed = true; }
            }
            async Task ReadConversation()
            {
                if (chat["model"] is not null) return;
                try
                {
                    var inner = RemoteWorkspaces.TrySplit(workspaceId, out _, out var project) ? project : workspaceId;
                    conversation = Format.Items(await Call(workspaceId, "chat.list", new() { ["workspaceId"] = inner }))?.FirstOrDefault(item => Format.Text(item, "id") == Format.Text(chat, "id")) ?? chat;
                }
                catch { }
            }
            await Task.WhenAll(ReadUsage(), ReadConversation());
            token.ThrowIfCancellationRequested();
            var remote = RemoteWorkspaces.CachedFolder(workspaceId);
            var fields = Identity(folderName, remote);
            fields.Add(new(L10n.Text("windows.machinespage.status.920e413c"), Format.Flag(conversation, "running") ? L10n.Text("common.working") : Text("ready")));
            var model = Format.Text(conversation, "model");
            if (model.Length > 0) fields.Add(new(L10n.Text("windows.chatpage.model.5e2c614c"), model));
            if (usage is not null)
            {
                var input = Format.Number(usage, "input"); var output = Format.Number(usage, "output");
                var cached = Format.Number(usage, "cacheRead") + Format.Number(usage, "cacheWrite");
                fields.Add(new(L10n.Text("windows.insightspage.tokens.a039dfb9"), Number(input + output + cached), true));
                fields.Add(new(L10n.Text("windows.homepage.fresh_input.a5156480"), Number(input), true));
                fields.Add(new(L10n.Text("windows.homepage.output.b2439bcb"), Number(output), true));
                if (cached > 0) fields.Add(new(Text("cached_tokens"), Number(cached), true));
            }
            else fields.Add(new(L10n.Text("windows.insightspage.tokens.a039dfb9"), Text(failed ? "usage_unavailable" : "usage_not_reported")));
            fields.Add(new(Text("last_message"), Date(Format.Long(chat, "lastMessageAtMs"), Text("no_messages"))));
            return Card(Format.Text(chat, "title", L10n.Text("windows.sidebarlive.untitled_conversation.31d248c4")),
                L10n.Text("windows.chatpage.chat.460b3a7d") + " · " + SidebarLive.HarnessName(Format.Text(chat, "backend")), fields,
                Format.Text(folder, "path", remote?.Path ?? ""), folder?["git"] ?? remote?.Git);
        });
    }

    public static void AttachTerminal(FrameworkElement row, string workspaceId, JsonNode session, JsonNode? folder = null)
    {
        SidebarHoverPresenter.Attach(row, _ =>
        {
            var remote = RemoteWorkspaces.CachedFolder(workspaceId);
            var fields = Identity(Format.Text(folder, "name", remote?.Name ?? L10n.Text("windows.sidebarlive.project.98595978")), remote);
            fields.Add(new(L10n.Text("windows.machinespage.status.920e413c"), SidebarLive.SessionState(session).Label));
            if (SidebarLive.SessionStats(session) is string stats) fields.Add(new(L10n.Text("windows.homepage.activity.38da1505"), stats, true));
            fields.Add(new(L10n.Text("windows.workflowspage.command.71316697"), Format.Text(session, "command", "shell")));
            var window = Format.Number(session, "contextWindow");
            if (window > 0) fields.Add(new(Text("context"), Number(Format.Number(session, "contextUsed")) + " / " + Number(window), true));
            if (session["tokens"] is not null) fields.Add(new(L10n.Text("windows.insightspage.tokens.a039dfb9"), Number(Format.Number(session, "tokens")), true));
            fields.Add(new(Text("last_activity"), Date(Format.Long(session, "lastActivityAtMs"), "—")));
            return Task.FromResult(Card(SidebarLive.SessionTitle(Format.Text(session, "command", "shell")), L10n.Text("windows.terminalpage.terminal.e0926fda"), fields,
                Format.Text(session, "cwd", Format.Text(folder, "path", remote?.Path ?? "")), folder?["git"] ?? remote?.Git));
        });
    }

    public static void AttachSsh(FrameworkElement row, string workspaceId, JsonNode? session, JsonNode? folder = null)
    {
        SidebarHoverPresenter.Attach(row, _ =>
        {
            var remote = RemoteWorkspaces.CachedFolder(workspaceId);
            var fields = Identity(Format.Text(folder, "name", remote?.Name ?? L10n.Text("windows.sidebarlive.project.98595978")), remote);
            fields.Add(new(L10n.Text("windows.machinespage.status.920e413c"), Format.Flag(session, "alive") ? Text("ready") : L10n.Text("windows.terminalpage.closed.c21ead06")));
            // SessionLabel resolves the saved friendly name and suppresses connection addresses.
            return Task.FromResult(Card(SshHostPlatform.SessionLabel(session), L10n.Text("windows.sshhostplatform.ssh_session.25493005"), fields,
                Format.Text(folder, "path", remote?.Path ?? ""), folder?["git"] ?? remote?.Git));
        });
    }

    private static List<Field> Identity(string name, RemoteFolder? remote) =>
    [ new(L10n.Text("windows.sidebarlive.project.98595978"), name), new(L10n.Text("windows.machinespage.computer.76ed42d2"), remote?.MachineLabel is { Length: > 0 } machine ? machine : Text(remote is null ? "this_computer" : "other_computer")) ];

    private static FrameworkElement Card(string title, string subtitle, IEnumerable<Field> fields, string path, JsonNode? git)
    {
        var body = new StackPanel { Spacing = 10 };
        body.Children.Add(new TextBlock { Text = title, FontSize = 14, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap, MaxLines = 3 });
        body.Children.Add(new TextBlock { Text = subtitle, FontSize = 11, Foreground = Theme.Brush(static () => Theme.ControlGlyph), TextWrapping = TextWrapping.Wrap });
        foreach (var field in fields) body.Children.Add(FieldRow(field));
        if (Format.Flag(git, "isRepo")) body.Children.Add(GitCard(git!));
        if (path.Length > 0)
        {
            body.Children.Add(new Border { Height = 1, Background = Theme.BorderBrush });
            body.Children.Add(new TextBlock { Text = path, FontSize = 11, Foreground = Theme.Brush(static () => Theme.ControlGlyph), TextWrapping = TextWrapping.Wrap, MaxLines = 3, IsTextSelectionEnabled = true });
        }
        return new Border
        {
            Width = 340, Background = Theme.PanelBrush, BorderBrush = Theme.BorderBrush, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(14),
            Padding = new Thickness(12), Child = new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled },
        };
    }
    private static Grid FieldRow(Field field)
    {
        var row = new Grid { ColumnSpacing = 12 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.Children.Add(new TextBlock { Text = field.Label, FontSize = 12, Foreground = Theme.Brush(static () => Theme.ControlGlyph) });
        var value = new TextBlock { Text = field.Value, FontSize = 12, FontWeight = FontWeights.Medium, TextAlignment = TextAlignment.Right, TextWrapping = TextWrapping.Wrap, MaxLines = 3 };
        if (field.Numeric) value.FontFamily = Fonts.Mono;
        Grid.SetColumn(value, 1); row.Children.Add(value);
        return row;
    }
    private static Border GitCard(JsonNode git)
    {
        var body = new StackPanel { Spacing = 7 };
        var branch = new TextBlock { Text = "⑂ " + Format.Text(git, "branch", Text("detached_head")), FontFamily = Fonts.Mono, FontSize = 12, FontWeight = FontWeights.Medium, TextTrimming = TextTrimming.CharacterEllipsis, MaxLines = 1 };
        body.Children.Add(branch);
        var counts = new Grid { ColumnSpacing = 8 };
        counts.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        counts.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); counts.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        counts.Children.Add(new TextBlock { Text = Text("changed_files") + "  " + Number((git["files"] as JsonArray)?.Count ?? 0), FontSize = 12, Foreground = Theme.Brush(static () => Theme.ControlGlyph) });
        var added = new TextBlock { Text = "+" + Number(Format.Number(git, "added")), FontSize = 12, FontWeight = FontWeights.SemiBold, Foreground = Theme.Brush(static () => Theme.DiffAdded) };
        var removed = new TextBlock { Text = "−" + Number(Format.Number(git, "removed")), FontSize = 12, FontWeight = FontWeights.SemiBold, Foreground = Theme.Brush(static () => Theme.DiffRemoved) };
        Grid.SetColumn(added, 1); counts.Children.Add(added); Grid.SetColumn(removed, 2); counts.Children.Add(removed); body.Children.Add(counts);
        if (Format.Flag(git, "partial")) body.Children.Add(new TextBlock { Text = Text("partial_counts"), FontSize = 11, Foreground = Theme.Brush(static () => Theme.ControlGlyph), TextWrapping = TextWrapping.Wrap });
        if (Format.Number(git, "ahead") > 0 || Format.Number(git, "behind") > 0) body.Children.Add(FieldRow(new(Text("upstream"), "↑ " + Number(Format.Number(git, "ahead")) + "  ↓ " + Number(Format.Number(git, "behind")), true)));
        return new Border { Background = Theme.AccentSoftBrush, BorderBrush = Theme.AccentBrush, BorderThickness = new Thickness(0.5), CornerRadius = new CornerRadius(8), Padding = new Thickness(8), Child = body };
    }
}
