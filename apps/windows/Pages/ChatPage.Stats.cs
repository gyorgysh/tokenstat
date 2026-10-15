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
    private JsonNode? _inspection;
    private bool _inspectionRunning;
    private string? _inspectionOwner;
    private string? _inspectionFlight;
    private DateTimeOffset _inspectionAt;
    private readonly Dictionary<string, bool> _statsExpanded = new();
    private readonly Dictionary<string, string> _statsQueries = new();
    private readonly List<TextBox> _statsFilters = new();
    private readonly StackPanel _commandMenu = new() { Spacing = 2 };
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
    private string? InspectionOwner() => _openId is null ? null : $"{AppServices.AccountGeneration}/{_openGeneration}/{_openId}/{Format.Text(_openChat, "backend")}/{Format.Text(_openChat, "model")}";
    private async Task RefreshInspectionAsync(bool force = false)
    {
        var owner = InspectionOwner();
        if (owner is null || owner == _inspectionFlight) return;
        if (_inspectionOwner != owner)
        {
            _inspectionOwner = owner; _inspection = null; _inspectionAt = default; _statsExpanded.Clear(); _statsQueries.Clear(); RenderInspection();
        }
        if (!force && DateTimeOffset.UtcNow - _inspectionAt < TimeSpan.FromSeconds(5)) return;
        _inspectionFlight = owner;
        try
        {
            var next = await CallChatAsync("chat.inspection", new JsonObject { ["id"] = _openId });
            if (InspectionOwner() != owner || !IsLoaded || Format.Text(next, "backend") != Format.Text(_openChat, "backend")) return;
            _inspectionAt = DateTimeOffset.UtcNow;
            var running = Format.Flag(_openChat, "running");
            if (!JsonNode.DeepEquals(next, _inspection) || _inspectionRunning != running) {
                _inspection = next; _inspectionRunning = running; RenderInspection();
            }
        }
        catch { if (InspectionOwner() == owner) { _inspectionAt = DateTimeOffset.UtcNow; _inspection = null; RenderInspection(); } }
        finally { if (_inspectionFlight == owner) _inspectionFlight = null; }
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
        if (_commandDialogBody is not null && _commandDialogOwner == InspectionOwner()) RenderCommandStats();
        else _commandDialog?.Hide();
        if (filter is not null && _statsFilters.LastOrDefault(field => Equals(field.Tag, filter)) is TextBox replacement)
            DispatcherQueue.TryEnqueue(() => {
                if (owner != InspectionOwner() || !_statsFilters.Contains(replacement) || !replacement.IsLoaded) return;
                replacement.Focus(FocusState.Programmatic);
                replacement.Select(Math.Min(caret, replacement.Text.Length), Math.Min(length, Math.Max(0, replacement.Text.Length - caret)));
            });
    }
    private void RenderCommandStats()
    {
        if (_commandDialogBody is not StackPanel body) return;
        body.Children.Clear(); AddStats(body);
        body.Children.Add(new TextBlock { Text = L10n.Text("common.chat.commands"), FontWeight = FontWeights.SemiBold });
        foreach (var command in Commands()) body.Children.Add(Muted(command.Name + " · " + command.Detail));
        body.Children.Add(Muted(L10n.Text("common.chat.command.unsupported")));
    }
    private void AddStats(StackPanel target)
    {
        var data = _inspectionOwner == InspectionOwner() ? _inspection : null;
        var body = new StackPanel { Spacing = Theme.SpaceS };
        var details = new StackPanel { Spacing = Theme.SpaceS };
        body.Children.Add(new TextBlock { Text = Format.Text(data, "model", Format.Text(_openChat, "backend")),
            FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
        if (data is null) body.Children.Add(Muted(L10n.Text("common.chat.stats.unavailable")));
        else
        {
            var used = Format.Number(data, "contextUsed");
            var window = Format.Number(data, "contextWindow");
            if (data["contextUsed"] is not null)
            {
                var amount = new Grid { ColumnSpacing = 8 };
                amount.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                amount.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                var tokens = Fonts.Tabular(new TextBlock { FontSize = 12, TextWrapping = TextWrapping.Wrap });
                tokens.Inlines.Add(new Run { Text = used.ToString("N0"), FontSize = 22, FontWeight = FontWeights.SemiBold });
                tokens.Inlines.Add(new Run { Text = $" / {(window > 0 ? window.ToString("N0") : "—")}" });
                amount.Children.Add(tokens);
                if (window > 0) {
                    var percent = Fonts.Tabular(new TextBlock { Text = Math.Clamp(used / window, 0, 1).ToString("P0"),
                        FontSize = 12, FontWeight = FontWeights.SemiBold, Foreground = Theme.AccentBrush, VerticalAlignment = VerticalAlignment.Center });
                    Grid.SetColumn(percent, 1); amount.Children.Add(percent);
                }
                body.Children.Add(amount);
                if (window > 0) body.Children.Add(new ProgressBar { Minimum = 0, Maximum = 1, Value = Math.Clamp(used / window, 0, 1) });
            }
            else body.Children.Add(Muted(L10n.Text("common.chat.stats.no_data")));
            if (data["contextBreakdown"] is JsonObject prompt) {
                details.Children.Add(Muted(L10n.Text("common.chat.stats.last_prompt")));
                details.Children.Add(Muted($"{L10n.Text("common.chat.stats.input")} · {Format.Number(prompt, "input"):N0}"));
                details.Children.Add(Muted($"{L10n.Text("common.chat.stats.cache_read")} · {Format.Number(prompt, "cacheRead"):N0}"));
                details.Children.Add(Muted($"{L10n.Text("common.chat.stats.cache_write")} · {Format.Number(prompt, "cacheWrite"):N0}"));
                details.Children.Add(Muted(L10n.Text("common.chat.stats.prompt_note")));
            }
            if (Format.Text(data, "windowSource") == "catalog") details.Children.Add(Muted(L10n.Text("common.chat.stats.catalog_window")));
            var history = AsArray(data, "contextHistory").Select(p => Format.Number(p, "tokens")).ToArray();
            if (history.Length > 1)
            {
                details.Children.Add(Muted(L10n.Text("common.chat.stats.history")));
                var canvas = new Canvas { Height = 48, HorizontalAlignment = HorizontalAlignment.Stretch };
                var line = new Polyline { Stroke = Theme.AccentBrush, StrokeThickness = 2 };
                canvas.Children.Add(line);
                canvas.SizeChanged += (_, _) => {
                    var peak = Math.Max(1, history.Max());
                    line.Points = new PointCollection();
                    for (var i = 0; i < history.Length; i++) line.Points.Add(new Point(canvas.ActualWidth * i / (history.Length - 1), 48 * (1 - history[i] / peak)));
                };
                details.Children.Add(canvas);
                details.Children.Add(Muted($"{history.First():N0} → {history.Last():N0}"));
                details.Children.Add(Muted(L10n.Text("common.chat.stats.history_note")));
            }
            if (data["usage"] is JsonObject usage) AppendUsage(details, usage);
            if (data["tools"] is JsonArray tools) details.Children.Add(ToolBrowser(tools, L10n.Text("common.chat.stats.available_tools", tools.Count.ToString("N0")), "available"));
            if (data["usedTools"] is JsonArray usedTools && usedTools.Count > 0) details.Children.Add(ToolBrowser(usedTools, L10n.Text("common.chat.stats.used_tools", usedTools.Count.ToString("N0")), "used"));
            if (Format.Flag(data, "inventoryPartial")) details.Children.Add(Muted(L10n.Text("common.chat.stats.partial")));
        }
        if (data is null && _aggregateUsage is JsonObject cached) AppendUsage(details, cached);
        var status = new Border { Background = Theme.AccentSoftBrush, CornerRadius = new CornerRadius(12),
            Padding = new Thickness(8, 3, 8, 3), Child = Muted(Format.Flag(_openChat, "running") ? L10n.Text("common.running") : L10n.Text("common.idle")) };
        target.Children.Add(CollapsibleStatsCard(L10n.Text("common.chat.stats"), "context", body, details, status));
        if (data is null) return;
        var servers = AsArray(data, "mcpServers").OfType<JsonObject>().ToArray();
        var connected = servers.Where(s => Format.Text(s, "source") == "agent" && Format.Text(s, "status") == "connected").ToArray();
        var mcp = new StackPanel { Spacing = Theme.SpaceS };
        var mcpDetails = new StackPanel { Spacing = Theme.SpaceS };
        if (connected.Length > 0) mcp.Children.Add(Muted(Format.Flag(data, "currentRun") && Format.Flag(_openChat, "running") ? L10n.Text("common.chat.stats.live_servers", connected.Length.ToString("N0")) : L10n.Text("common.chat.stats.connected_servers", connected.Length.ToString("N0"))));
        if (servers.Length == 0) mcp.Children.Add(Muted(L10n.Text("common.chat.stats.no_servers")));
        var connections = new StackPanel();
        foreach (var server in connected) connections.Children.Add(ServerRow(server, Format.Flag(data, "currentRun") && Format.Flag(_openChat, "running")));
        if (connections.Children.Count > 0) mcpDetails.Children.Add(connections);
        var others = new StackPanel();
        foreach (var server in servers.Except(connected)) others.Children.Add(ServerRow(server, false));
        if (others.Children.Count > 0) mcp.Children.Add(Muted(L10n.Text("common.chat.stats.other_servers", others.Children.Count.ToString("N0"))));
        if (others.Children.Count > 0) mcpDetails.Children.Add(StatsDisclosure(L10n.Text("common.chat.stats.other_servers", others.Children.Count.ToString("N0")), others, "other-servers"));
        mcpDetails.Children.Add(Muted(L10n.Text("common.chat.stats.reported")));
        target.Children.Add(CollapsibleStatsCard(L10n.Text("common.chat.stats.mcp_servers"), "servers", mcp, mcpDetails));
    }
    private Border CollapsibleStatsCard(string title, string key, UIElement summary, FrameworkElement details, FrameworkElement? status = null)
    {
        var expanded = _statsExpanded.GetValueOrDefault(key);
        var header = new Grid { ColumnSpacing = 8 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(new TextBlock { Text = title, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center });
        if (status is not null) { Grid.SetColumn(status, 1); header.Children.Add(status); }
        var chevron = new TextBlock { Text = expanded ? "⌃" : "⌄", VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(chevron, 2); header.Children.Add(chevron);
        var toggle = new Button { Content = header, MinHeight = 44, Background = Theme.PanelBrush, BorderThickness = new Thickness(0),
            Padding = new Thickness(0), HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        void State() {
            details.Visibility = expanded ? Visibility.Visible : Visibility.Collapsed;
            chevron.Text = expanded ? "⌃" : "⌄";
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(toggle, L10n.Text(expanded ? "common.collapse" : "common.expand"));
        }
        State();
        toggle.Click += (_, _) => { expanded = !expanded; _statsExpanded[key] = expanded; State(); };
        var stack = new StackPanel { Spacing = Theme.SpaceS };
        stack.Children.Add(toggle); stack.Children.Add(summary); stack.Children.Add(details);
        return new Border { Background = Theme.PanelBrush, BorderBrush = Theme.BorderBrush, BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(Theme.CardRadius), Padding = new Thickness(Theme.CardPadding), Child = stack };
    }
    private void AppendUsage(StackPanel body, JsonObject usage)
    {
        body.Children.Add(new TextBlock { Text = L10n.Text("common.chat.stats.conversation"), FontWeight = FontWeights.SemiBold });
        var values = new[] { "input", "output", "cacheRead", "cacheWrite" }.Select(key => Math.Max(0, Format.Number(usage, key))).ToArray();
        var labels = new[] { L10n.Text("common.chat.stats.input"), L10n.Text("common.chat.stats.output"), L10n.Text("common.chat.stats.cache_read"), L10n.Text("common.chat.stats.cache_write") };
        var colors = new Brush[] { Theme.AccentBrush, Theme.Brush(static () => Theme.Secondary), Theme.AccentSoftBrush, Theme.Brush(static () => Theme.Warning) };
        var bar = new Grid { Height = 8 };
        for (var i = 0; i < values.Length; i++)
        {
            bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(values[i], GridUnitType.Star) });
            var segment = new Border { Background = colors[i] }; Grid.SetColumn(segment, i); bar.Children.Add(segment);
        }
        body.Children.Add(bar);
        var metrics = new Grid { ColumnSpacing = 12, RowSpacing = 8 };
        metrics.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        metrics.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        metrics.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        metrics.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        for (var i = 0; i < labels.Length; i++) {
            var metric = new StackPanel { Spacing = 2 };
            var label = new Grid { ColumnSpacing = 6 };
            label.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            label.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            label.Children.Add(new Ellipse { Width = 6, Height = 6, Fill = colors[i], VerticalAlignment = VerticalAlignment.Center });
            var title = Muted(labels[i]); Grid.SetColumn(title, 1); label.Children.Add(title);
            metric.Children.Add(label);
            metric.Children.Add(Fonts.Tabular(new TextBlock { Text = values[i].ToString("N0"), FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap }));
            Grid.SetRow(metric, i / 2); Grid.SetColumn(metric, i % 2); metrics.Children.Add(metric);
        }
        body.Children.Add(metrics);
        var cost = Format.Number(usage, "cost");
        if (cost > 0) body.Children.Add(Muted(L10n.Text("common.chat.stats.cost") + " · " + cost.ToString("C2", CultureInfo.GetCultureInfo("en-US"))));
    }
    private Expander StatsDisclosure(string title, UIElement content, string? identity = null)
    {
        var key = identity ?? title;
        var view = new Expander { Header = title, Content = content, HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch, IsExpanded = _statsExpanded.GetValueOrDefault(key) };
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
        var body = new StackPanel { Spacing = 4 };
        var row = new Grid { ColumnSpacing = 8, MinHeight = 32, Padding = new Thickness(0, 4, 0, 4) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.Children.Add(new Ellipse { Width = 7, Height = 7, VerticalAlignment = VerticalAlignment.Center,
            Fill = connected && live ? Theme.AccentBrush : connected ? Theme.AccentSoftBrush : Theme.Brush(static () => Theme.ControlGlyph) });
        var label = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        var name = new TextBlock { Text = Format.Text(server, "name").Replace("plugin:", "").Replace(":", " · "),
            FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(name, ServerStatus(Format.Text(server, "status"), live));
        label.Children.Add(name);
        label.Children.Add(Muted(ServerStatus(Format.Text(server, "status"), connected && live)));
        Grid.SetColumn(label, 1); row.Children.Add(label); body.Children.Add(row);
        if (server["tools"] is JsonArray tools && tools.Count > 0) body.Children.Add(ToolBrowser(tools, L10n.Text("common.chat.stats.available_tools", tools.Count.ToString("N0")), "server-tools:" + Format.Text(server, "name")));
        return body;
    }
    private static string ServerStatus(string status, bool live) => status switch {
        "connected" => live ? L10n.Text("common.chat.stats.connected") : L10n.Text("common.chat.stats.reported_connected"),
        "configured" => L10n.Text("common.chat.stats.configured"), "disabled" => L10n.Text("common.chat.stats.disabled"),
        "starting" => L10n.Text("common.chat.stats.starting"), "authenticationRequired" => L10n.Text("common.chat.stats.authenticationRequired"),
        "failed" => L10n.Text("common.chat.stats.failed"), "cancelled" => L10n.Text("common.chat.stats.cancelled"),
        "notStarted" => L10n.Text("common.chat.stats.notStarted"), _ => L10n.Text("common.chat.stats.unknown"),
    };
}
