// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Globalization;
using System.Text.Json.Nodes;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Tokenstat.Design;
using Windows.Foundation;
using Windows.System;

namespace Tokenstat.Pages;

internal sealed partial class ChatPage
{
    private readonly StackPanel _inspectionHost = new() { Spacing = Theme.SpaceM };
    private readonly StackPanel _sessionIdentityHost = new();
    private JsonNode? _inspection;
    private bool _inspectionRunning;
    private string? _inspectionOwner;
    private string? _inspectionFlight;
    private DateTimeOffset _inspectionAt;
    private readonly Dictionary<string, bool> _statsExpanded = new();
    private readonly Dictionary<string, string> _statsQueries = new();
    private readonly List<TextBox> _statsFilters = new();
    private readonly StackPanel _commandMenu = new() { Spacing = 2 };
    private readonly ScrollViewer _commandScroll = new() { MaxHeight = 220 };
    private int _commandIndex;
    private bool _commandsDismissed;
    private bool _commandInFlight;
    private ContentDialog? _commandDialog;
    private StackPanel? _commandDialogBody;
    private string? _commandDialogOwner;

    private static (string Name, string Detail)[] Commands() => [
        ("/compact", L10n.Text("common.chat.command.compact")),
        ("/status", L10n.Text("common.chat.command.status")),
        ("/context", L10n.Text("common.chat.command.context")),
        ("/usage", L10n.Text("common.chat.command.usage")),
        ("/mcp", L10n.Text("common.chat.command.mcp")),
        ("/tools", L10n.Text("common.chat.command.tools")),
        ("/goal", L10n.Text("common.chat.activity.command_goal")),
        ("/plan", L10n.Text("common.chat.activity.command_plan")),
        ("/subagents", L10n.Text("common.chat.activity.command_subagents")),
        ("/help", L10n.Text("common.chat.command.help")),
        ("/stop", L10n.Text("common.chat.command.stop")),
    ];
    private (string Name, string Detail)[] CommandMatches()
    {
        var text = _draft.Text.Trim();
        var names = ChatCommandRules.Matches(text);
        return !_commandsDismissed ? Commands().Where(c => names.Contains(c.Name)).ToArray() : [];
    }
    private void RenderCommandMenu()
    {
        _commandMenu.Children.Clear();
        var matches = CommandMatches();
        _commandIndex = Math.Clamp(_commandIndex, 0, Math.Max(0, matches.Length - 1));
        for (var index = 0; index < matches.Length; index++)
        {
            var command = matches[index];
            var label = new StackPanel { Spacing = 3 };
            label.Children.Add(new TextBlock { Text = command.Name, FontWeight = FontWeights.SemiBold });
            label.Children.Add(Muted(command.Detail));
            var button = new Button { Content = label,
                HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left, MinHeight = 44 };
            if (index == _commandIndex) button.Background = Theme.AccentSoftBrush;
            button.Click += (_, _) => { _draft.Text = command.Name; _draft.SelectionStart = _draft.Text.Length; _draft.Focus(FocusState.Programmatic); };
            _commandMenu.Children.Add(button);
        }
    }
    private async Task<bool> ConsumeCommandAsync()
    {
        var text = _draft.Text.Trim();
        var action = ChatCommandRules.Evaluate(text, Format.Text(_openChat, "backend"), Busy(), _attachments.Count > 0, _commandIndex);
        if (action.Kind is ChatCommandRules.Kind.Message or ChatCommandRules.Kind.Compact) return false;
        if (action.Kind == ChatCommandRules.Kind.Complete) { _draft.Text = action.Completion!; _draft.SelectionStart = _draft.Text.Length; return true; }
        var refusal = action.Kind switch {
            ChatCommandRules.Kind.Attachments => L10n.Text("common.chat.command.no_attachments"),
            ChatCommandRules.Kind.Arguments => L10n.Text("common.chat.command.no_arguments"),
            ChatCommandRules.Kind.Unsupported => L10n.Text("common.chat.command.unsupported"),
            ChatCommandRules.Kind.Running => L10n.Text("common.chat.command.idle"), _ => null,
        };
        if (refusal is not null) { Banner(refusal); return true; }
        if (_commandInFlight) return true;
        _commandInFlight = true;
        var id = _openId;
        var generation = _openGeneration;
        var account = AppServices.AccountGeneration;
        bool Current() => id == _openId && generation == _openGeneration && account == AppServices.AccountGeneration && IsLoaded;
        try {
            if (action.Kind == ChatCommandRules.Kind.Stop) await StopAsync();
            else
            {
                if (text is "/goal" or "/plan" or "/subagents")
                {
                    await ShowActivityAsync(text[1..]);
                    if (Current() && _draft.Text.Trim() == text) _draft.Text = "";
                    return true;
                }
                await RefreshInspectionAsync(force: true);
                if (id != _openId || generation != _openGeneration || account != AppServices.AccountGeneration || !IsLoaded) return true;
                var body = new StackPanel { Spacing = Theme.SpaceM };
                _commandDialogBody = body;
                _commandDialogOwner = InspectionOwner();
                RenderCommandStats();
                var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = L10n.Text("common.chat.stats.overview"),
                    Content = new ScrollViewer { Content = body, MaxHeight = 600 }, CloseButtonText = L10n.Text("common.done") };
                _commandDialog = dialog;
                try { await dialog.ShowAsync(); }
                finally { _commandDialog = null; _commandDialogBody = null; _commandDialogOwner = null; }
            }
            if (id == _openId && generation == _openGeneration && account == AppServices.AccountGeneration && _draft.Text.Trim() == text) _draft.Text = "";
            return true;
        } catch (Exception error) { if (Current()) Banner(error.Message); return true; }
        finally { _commandInFlight = false; }
    }
    private string? InspectionOwner() => _openId is null ? null : $"{AppServices.AccountGeneration}/{_openGeneration}/{_openId}/{Format.Text(_openChat, "backend")}/{Format.Text(_openChat, "model")}/{_workspaceId}/{_openChat?["runRevision"] ?? _openChat?["sendRevision"]}";
    private async Task RefreshInspectionAsync(bool force = false)
    {
        var owner = InspectionOwner();
        var visibility = _inspectionVisibilityGeneration;
        var flight = $"{owner}/{visibility}";
        if (!IsLoaded || !_inspectionPeerAvailable || App.CurrentWindow is MainWindow { IsForeground: false } || owner is null || flight == _inspectionFlight) return;
        if (_inspectionOwner != owner)
        {
            _inspectionOwner = owner; _inspection = null; _inspectionLiveLease = false; _inspectionAt = default; _statsExpanded.Clear(); _statsQueries.Clear(); RenderInspection();
        }
        if (!force && DateTimeOffset.UtcNow - _inspectionAt < TimeSpan.FromSeconds(5)) return;
        _inspectionFlight = flight;
        try
        {
            var next = await CallChatAsync("chat.inspection", new JsonObject { ["id"] = _openId });
            if (InspectionOwner() != owner || visibility != _inspectionVisibilityGeneration || !IsLoaded || !_inspectionPeerAvailable || App.CurrentWindow is MainWindow { IsForeground: false } || Format.Text(next, "backend") != Format.Text(_openChat, "backend")) return;
            _inspectionAt = DateTimeOffset.UtcNow;
            var running = Format.Flag(_openChat, "running");
            var renewed = !_inspectionLiveLease; _inspectionLiveLease = true;
            if (renewed || !JsonNode.DeepEquals(next, _inspection) || _inspectionRunning != running) {
                _inspection = next; _inspectionRunning = running; RenderInspection();
            }
        }
        catch { if (InspectionOwner() == owner && visibility == _inspectionVisibilityGeneration) { _inspectionAt = DateTimeOffset.UtcNow; _inspection = null; _inspectionLiveLease = false; RenderInspection(); } }
        finally { if (_inspectionFlight == flight) _inspectionFlight = null; }
    }
    private void RenderInspection()
    {
        var focused = _statsFilters.LastOrDefault(field => field.IsLoaded && field.FocusState != FocusState.Unfocused);
        var filter = focused?.Tag as string;
        var caret = focused?.SelectionStart ?? 0;
        var length = focused?.SelectionLength ?? 0;
        var owner = InspectionOwner();
        _statsFilters.Clear();
        _inspectionHost.Children.Clear(); AddStats(_inspectionHost);
        RenderSessionIdentities();
        RenderActivitySummary();
        if (_commandDialogBody is not null && _commandDialogOwner == InspectionOwner()) RenderCommandStats();
        else _commandDialog?.Hide();
        if (filter is not null && _statsFilters.LastOrDefault(field => Equals(field.Tag, filter)) is TextBox replacement)
            DispatcherQueue.TryEnqueue(() => {
                if (owner != InspectionOwner() || !_statsFilters.Contains(replacement) || !replacement.IsLoaded) return;
                replacement.Focus(FocusState.Programmatic);
                replacement.Select(Math.Min(caret, replacement.Text.Length), Math.Min(length, Math.Max(0, replacement.Text.Length - caret)));
            });
    }
    private void RenderSessionIdentities()
    {
        _sessionIdentityHost.Children.Clear();
        if (_openChat is not null && _openId is not null)
            _sessionIdentityHost.Children.Add(SessionIdentityRows.Build(_openId, "common.session_identity.conversation",
                SessionIdentities.Read(CurrentInspection?["sessions"]), historyExpanded: _statsExpanded.GetValueOrDefault("session-history"),
                historyChanged: expanded => _statsExpanded["session-history"] = expanded));
    }
    private void RenderCommandStats()
    {
        if (_commandDialogBody is not StackPanel body) return;
        body.Children.Clear();
        if (_commandActivitySection is not null) { body.Children.Add(ActivityCard(CurrentInspection, expanded: true, section: _commandActivitySection)); return; }
        AddStats(body);
        body.Children.Add(new TextBlock { Text = L10n.Text("common.chat.commands"), FontWeight = FontWeights.SemiBold });
        foreach (var command in Commands()) body.Children.Add(Muted(command.Name + " · " + command.Detail));
        body.Children.Add(Muted(L10n.Text("common.chat.command.unsupported")));
    }
    private void AddStats(StackPanel target)
    {
        var data = CurrentInspection;
        target.Children.Add(ActivityCard(data));
        var summary = new StackPanel { Spacing = 3 };
        var details = new StackPanel { Spacing = 6 };
        var model = Format.Text(data, "model", Format.Text(_openChat, "model", Format.Text(_openChat, "backend")));
        summary.Children.Add(new TextBlock { Text = model, FontSize = 11, Opacity = .7, TextTrimming = TextTrimming.CharacterEllipsis,
            IsTextSelectionEnabled = true });
        if (data?["contextUsed"] is not null)
        {
            var used = Math.Max(0, Format.Number(data, "contextUsed"));
            var window = Math.Max(0, Format.Number(data, "contextWindow"));
            var amount = new Grid { ColumnSpacing = 8 };
            amount.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
            amount.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
            amount.Children.Add(Fonts.Tabular(new TextBlock { Text = L10n.Text("common.chat.stats.in_context", used.ToString("N0")),
                FontSize = 13, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap }));
            if (window > 0)
            {
                var capacity = Fonts.Tabular(new TextBlock { Text = $"{used:N0} / {window:N0} · {used / window:P0}",
                    FontSize = 11, Opacity = .7, VerticalAlignment = VerticalAlignment.Center });
                Grid.SetColumn(capacity, 1); amount.Children.Add(capacity);
            }
            summary.Children.Add(amount);
            summary.Children.Add(ContextUsageBar(data!, used, window));
        }
        else summary.Children.Add(Muted(L10n.Text(data is null ? "common.chat.stats.unavailable" : "common.chat.stats.no_data")));
        if (data is not null)
        {
            if (data["contextBreakdown"] is JsonObject prompt)
            {
                details.Children.Add(new TextBlock { Text = L10n.Text("common.chat.stats.last_prompt"), FontSize = 11, Opacity = .7 });
                details.Children.Add(StatsMetric(L10n.Text("common.chat.stats.input"), Format.Number(prompt, "input").ToString("N0")));
                details.Children.Add(StatsMetric(L10n.Text("common.chat.stats.cache_read"), Format.Number(prompt, "cacheRead").ToString("N0")));
                details.Children.Add(StatsMetric(L10n.Text("common.chat.stats.cache_write"), Format.Number(prompt, "cacheWrite").ToString("N0")));
            }
            if (Format.Text(data, "windowSource") == "catalog") details.Children.Add(Muted(L10n.Text("common.chat.stats.catalog_window")));
            if (Format.Text(data, "windowSource") == "previousAgent") details.Children.Add(Muted(L10n.Text("common.chat.stats.last_window")));
            if (data["tools"] is JsonArray tools) details.Children.Add(ToolBrowser(tools, L10n.Text("common.chat.stats.available_tools", tools.Count.ToString("N0")), "available"));
            if (data["usedTools"] is JsonArray usedTools && usedTools.Count > 0) details.Children.Add(ToolBrowser(usedTools, L10n.Text("common.chat.stats.used_tools", usedTools.Count.ToString("N0")), "used"));
            if (data["usage"] is JsonObject usage)
            {
                var metrics = new StackPanel { Spacing = 4 }; AppendUsage(metrics, usage);
                details.Children.Add(StatsDisclosure(L10n.Text("common.chat.stats.conversation"), metrics, "conversation-usage"));
            }
            var history = AsArray(data, "contextHistory").Select(point => Format.Number(point, "tokens")).ToArray();
            if (history.Length > 1)
            {
                var historyBody = new StackPanel { Spacing = 4 };
                var canvas = new Canvas { Height = 40, HorizontalAlignment = HorizontalAlignment.Stretch };
                var line = new Polyline { Stroke = Theme.AccentBrush, StrokeThickness = 1.5 }; canvas.Children.Add(line);
                canvas.SizeChanged += (_, _) => {
                    var peak = Math.Max(1, history.Max()); line.Points = new PointCollection();
                    for (var i = 0; i < history.Length; i++) line.Points.Add(new Point(canvas.ActualWidth * i / (history.Length - 1), 40 * (1 - history[i] / peak)));
                };
                historyBody.Children.Add(canvas); historyBody.Children.Add(Muted($"{history.First():N0} → {history.Last():N0}"));
                details.Children.Add(StatsDisclosure(L10n.Text("common.chat.stats.history"), historyBody, "context-history"));
            }
            if (Format.Flag(data, "inventoryPartial")) details.Children.Add(Muted(L10n.Text("common.chat.stats.partial")));
        }
        else if (_aggregateUsage is JsonObject cached)
        {
            var metrics = new StackPanel { Spacing = 4 }; AppendUsage(metrics, cached);
            details.Children.Add(StatsDisclosure(L10n.Text("common.chat.stats.conversation"), metrics, "conversation-usage"));
        }
        target.Children.Add(CollapsibleStatsCard(L10n.Text("common.chat.stats"), "context", summary, details));
        if (data is null) return;
        var servers = AsArray(data, "mcpServers").OfType<JsonObject>().ToArray();
        var connected = servers.Count(server => Format.Text(server, "source") == "agent" && Format.Text(server, "status") == "connected");
        var serverSummary = new TextBlock { Text = L10n.Text("common.chat.stats.connection_summary", connected.ToString("N0"), (servers.Length - connected).ToString("N0")), FontSize = 12 };
        var serverDetails = new StackPanel { Spacing = 2 };
        var live = Format.Flag(data, "currentRun") && Format.Flag(_openChat, "running");
        foreach (var server in servers) serverDetails.Children.Add(ServerRow(server, live));
        if (servers.Length == 0) serverDetails.Children.Add(Muted(L10n.Text("common.chat.stats.no_servers")));
        target.Children.Add(CollapsibleStatsCard(L10n.Text("common.chat.stats.mcp_servers"), "servers", serverSummary, serverDetails));
    }
    private static Grid ContextUsageBar(JsonNode data, double used, double window)
    {
        var colors = new Brush[] { Theme.AccentBrush, Theme.Brush(static () => Theme.Secondary), Theme.Brush(static () => Theme.Warning) };
        var values = data["contextBreakdown"] is JsonObject breakdown
            ? new[] { Math.Max(0, Format.Number(breakdown, "input")), Math.Max(0, Format.Number(breakdown, "cacheRead")), Math.Max(0, Format.Number(breakdown, "cacheWrite")) }
            : new[] { used };
        if (Math.Abs(values.Sum() - used) > .5) values = [used];
        var bar = new Grid { Height = 4, Background = Theme.AccentSoftBrush };
        for (var index = 0; index < values.Length; index++)
        {
            bar.ColumnDefinitions.Add(new() { Width = new GridLength(values[index], GridUnitType.Star) });
            var segment = new Border { Background = colors[index] }; Grid.SetColumn(segment, index); bar.Children.Add(segment);
        }
        if (window > used) bar.ColumnDefinitions.Add(new() { Width = new GridLength(window - used, GridUnitType.Star) });
        return bar;
    }
    private static Grid StatsMetric(string title, string value)
    {
        var row = new Grid { ColumnSpacing = 8, MinHeight = 20 };
        row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        row.Children.Add(new TextBlock { Text = title, FontSize = 12, Opacity = .75, VerticalAlignment = VerticalAlignment.Center });
        var amount = Fonts.Tabular(new TextBlock { Text = value, FontSize = 12, VerticalAlignment = VerticalAlignment.Center });
        Grid.SetColumn(amount, 1); row.Children.Add(amount); return row;
    }
    private Border CollapsibleStatsCard(string title, string key, UIElement summary, FrameworkElement details, Button? reveal = null, Action? opened = null)
    {
        var expanded = _statsExpanded.GetValueOrDefault(key);
        var header = new Grid { ColumnSpacing = 8 };
        header.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        header.Children.Add(new TextBlock { Text = title, FontSize = 12, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        var chevron = new TextBlock { Text = expanded ? "⌃" : "⌄", FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(chevron, 1); header.Children.Add(chevron);
        var toggle = new Button { Content = header, MinHeight = 28, Background = Theme.PanelBrush, BorderThickness = new Thickness(0),
            Padding = new Thickness(0), HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        void State() {
            details.Visibility = expanded ? Visibility.Visible : Visibility.Collapsed; chevron.Text = expanded ? "⌃" : "⌄";
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(toggle, L10n.Text(expanded ? "common.collapse" : "common.expand"));
            if (expanded) opened?.Invoke();
        }
        State(); toggle.Click += (_, _) => { expanded = !expanded; _statsExpanded[key] = expanded; State(); };
        if (reveal is not null) reveal.Click += (_, _) => { expanded = true; _statsExpanded[key] = true; State(); };
        var stack = new StackPanel { Spacing = 5 }; stack.Children.Add(toggle); stack.Children.Add(summary); stack.Children.Add(details);
        return new Border { Background = Theme.PanelBrush, BorderBrush = Theme.BorderBrush, BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(Theme.CardRadius), Padding = new Thickness(12, 8, 12, 8), Child = stack };
    }
    private void AppendUsage(StackPanel body, JsonObject usage)
    {
        foreach (var (key, label) in new[] { ("input", "common.chat.stats.input"), ("output", "common.chat.stats.output"),
            ("cacheRead", "common.chat.stats.cache_read"), ("cacheWrite", "common.chat.stats.cache_write") })
            body.Children.Add(StatsMetric(L10n.Text(label), Math.Max(0, Format.Number(usage, key)).ToString("N0")));
        var cost = Format.Number(usage, "cost");
        if (cost > 0) body.Children.Add(StatsMetric(L10n.Text("common.chat.stats.cost"), cost.ToString("C2", CultureInfo.GetCultureInfo("en-US"))));
    }
    private Expander StatsDisclosure(object title, UIElement content, string? identity = null)
    {
        var key = identity ?? title.ToString() ?? "";
        var view = new Expander { Header = title, Content = content, HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch, IsExpanded = _statsExpanded.GetValueOrDefault(key),
            MinHeight = 28, Padding = new Thickness(0) };
        view.Resources["ExpanderHeaderMinHeight"] = 28d;
        view.Expanding += (_, _) => _statsExpanded[key] = true;
        view.Collapsed += (_, _) => _statsExpanded[key] = false;
        return view;
    }
    private UIElement ToolBrowser(JsonArray raw, string title, string scope)
    {
        var names = raw.Select(n => n?.GetValue<string>() ?? "").Where(n => n.Length > 0).Distinct().ToArray();
        string Group(string name) => name.StartsWith("mcp__", StringComparison.Ordinal) ? name[5..].Split("__")[0] : L10n.Text("common.chat.stats.agent_tools");
        var body = new StackPanel { Spacing = Theme.SpaceS };
        var search = new TextBox { PlaceholderText = L10n.Text("common.chat.stats.search_tools"), Tag = scope, Text = _statsQueries.GetValueOrDefault(scope, "") };
        _statsFilters.Add(search);
        var results = new StackPanel { Spacing = Theme.SpaceS };
        void Render()
        {
            results.Children.Clear();
            foreach (var group in names.Where(n => n.Contains(search.Text, StringComparison.CurrentCultureIgnoreCase)).GroupBy(Group).OrderBy(g => g.Key))
            {
                var rows = new StackPanel { Spacing = Theme.SpaceS };
                void Populate() {
                    if (rows.Children.Count > 0) return;
                    foreach (var name in group) rows.Children.Add(new TextBlock { Text = name, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, FontSize = 12 });
                }
                var disclosure = StatsDisclosure($"{group.Key} · {group.Count():N0}", new ScrollViewer { Content = rows, MaxHeight = 220 }, scope + "/" + group.Key);
                disclosure.Expanding += (_, _) => Populate();
                if (disclosure.IsExpanded) Populate();
                results.Children.Add(disclosure);
            }
        }
        search.TextChanged += (_, _) => { _statsQueries[scope] = search.Text; Render(); }; Render(); body.Children.Add(search); body.Children.Add(results);
        return StatsDisclosure(title, body, scope);
    }
    private UIElement ServerRow(JsonNode server, bool live)
    {
        var connected = Format.Text(server, "source") == "agent" && Format.Text(server, "status") == "connected";
        var row = new Grid { ColumnSpacing = 8, MinHeight = 26 };
        row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        row.Children.Add(new TextBlock { Text = Format.Text(server, "name"), FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center, IsTextSelectionEnabled = true });
        var status = new TextBlock { Text = ServerStatus(Format.Text(server, "status"), connected && live), FontSize = 11, Opacity = .75,
            VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(status, 1); row.Children.Add(status);
        if (server["tools"] is not JsonArray tools || tools.Count == 0) return row;
        var names = new StackPanel { Spacing = 3 };
        foreach (var tool in tools) names.Children.Add(new TextBlock { Text = tool?.GetValue<string>() ?? "", FontSize = 11,
            TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
        ToolTipService.SetToolTip(row, L10n.Text("common.chat.stats.available_tools", tools.Count.ToString("N0")));
        return StatsDisclosure(row, new ScrollViewer { Content = names, MaxHeight = 180 }, "server-tools:" + Format.Text(server, "name"));
    }
    private static string ServerStatus(string status, bool live) => status switch {
        "connected" => live ? L10n.Text("common.chat.stats.connected") : L10n.Text("common.chat.stats.reported_connected"),
        "configured" => L10n.Text("common.chat.stats.configured"), "disabled" => L10n.Text("common.chat.stats.disabled"),
        "starting" => L10n.Text("common.chat.stats.starting"), "authenticationRequired" => L10n.Text("common.chat.stats.authenticationRequired"),
        "failed" => L10n.Text("common.chat.stats.failed"), "cancelled" => L10n.Text("common.chat.stats.cancelled"),
        "notStarted" => L10n.Text("common.chat.stats.notStarted"), _ => L10n.Text("common.chat.stats.unknown"),
    };
}
