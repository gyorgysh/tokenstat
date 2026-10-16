// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Tokenstat.Navigation;

namespace Tokenstat.Pages;

internal sealed partial class ChatPage
{
    private readonly StackPanel _activitySummaryHost = new();
    private string? _commandActivitySection;
    private bool _inspectionLiveLease;
    private long _inspectionVisibilityGeneration;
    private Window? _inspectionWindow;
    private bool _inspectionPeerAvailable = true;
    private static string ActivityText(string key, params string[] args)
    {
        var resource = "common.chat.activity." + key;
        return L10n.Text(resource, args);
    }
    private JsonNode? CurrentInspection
    {
        get
        {
            if (_inspectionOwner != InspectionOwner()) return null;
            if (_inspectionLiveLease || _inspection is not JsonObject snapshot) return _inspection;
            var historical = (JsonObject)snapshot.DeepClone(); historical["currentRun"] = false; return historical;
        }
    }
    private void AttachInspectionWindow()
    {
        DetachInspectionWindow();
        _inspectionWindow = App.CurrentWindow;
        _inspectionPeerAvailable = !RemoteWorkspaces.TrySplit(_workspaceId, out var peer, out _)
            || (RemoteWorkspaces.IsConnected(peer) && RemoteWorkspaces.CachedFolder(_workspaceId) is not null);
        AppServices.AccountChanged += InspectionAccountChanged;
        RemoteWorkspaces.Changed += InspectionPeerChanged;
        if (_inspectionWindow is not null) _inspectionWindow.Activated += InspectionWindowActivated;
    }
    private void DetachInspectionWindow()
    {
        if (_inspectionWindow is not null) _inspectionWindow.Activated -= InspectionWindowActivated;
        AppServices.AccountChanged -= InspectionAccountChanged;
        RemoteWorkspaces.Changed -= InspectionPeerChanged;
        _inspectionWindow = null; _inspectionLiveLease = false; _inspectionVisibilityGeneration++;
    }
    private void InspectionAccountChanged() => DispatcherQueue.TryEnqueue(() => {
        CancelDropImport();
        _inspectionVisibilityGeneration++; _inspectionLiveLease = false; _inspection = null; _inspectionOwner = null; _inspectionAt = default;
        RenderInspection(); _commandDialog?.Hide();
    });
    private void InspectionPeerChanged() => DispatcherQueue.TryEnqueue(() => {
        var remote = RemoteWorkspaces.TrySplit(_workspaceId, out var peer, out _);
        var folderPresent = !remote || RemoteWorkspaces.CachedFolder(_workspaceId) is not null;
        var available = !remote || (RemoteWorkspaces.IsConnected(peer) && folderPresent);
        if (available == _inspectionPeerAvailable && folderPresent) return;
        _inspectionPeerAvailable = available; _inspectionVisibilityGeneration++; _inspectionLiveLease = false; _inspectionAt = default;
        if (!folderPresent) { _inspection = null; _inspectionOwner = null; _commandDialog?.Hide(); }
        RenderInspection();
        if (available) _ = RefreshInspectionAsync(force: true);
    });
    private void InspectionWindowActivated(object sender, WindowActivatedEventArgs args)
    {
        _inspectionLiveLease = false; _inspectionVisibilityGeneration++;
        RenderInspection();
        if (args.WindowActivationState != WindowActivationState.Deactivated) { _inspectionAt = default; _ = RefreshInspectionAsync(force: true); }
    }
    private static string ActivityStatus(string status, bool live)
    {
        var text = ActivityText("status_" + status);
        return live ? text : ActivityText("last_reported", text);
    }
    private static string ActivitySummary(ChatActivityData data)
    {
        var values = new List<string>();
        if (data.Goal is { } goal)
        {
            values.Add(ActivityStatus(goal.Status, data.Live));
            if (goal.TokenBudget is double budget) values.Add(ActivityText("tokens") + " " + ActivityText("progress", goal.TokensUsed?.ToString("N0") ?? "—", budget.ToString("N0")));
        }
        if (data.PlanReported && data.Plan.Length > 0) values.Add(ActivityText("steps", data.CompletedSteps.ToString("N0"), data.Plan.Length.ToString("N0")));
        if (data.AgentsReported && data.Agents.Length > 0) values.Add(data.RunningAgents is int running
            ? ActivityText("running_agents", running.ToString("N0")) : ActivityText("agents", data.Agents.Length.ToString("N0")));
        if (!string.IsNullOrWhiteSpace(data.Headline)) values.Add(data.Headline);
        return values.Count == 0 ? ActivityText("no_activity") : string.Join(" · ", values);
    }
    private void RenderActivitySummary()
    {
        _activitySummaryHost.Children.Clear();
        var data = ChatActivityData.Read(CurrentInspection, _openChat);
        if (data?.HasContent != true) { _activitySummaryHost.Visibility = Visibility.Collapsed; return; }
        _activitySummaryHost.Visibility = Visibility.Visible;
        var row = new Grid { ColumnSpacing = 7 };
        row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var icon = ActionIcon.Plan.Icon(); icon.Width = 14; icon.Height = 14; icon.Foreground = Theme.AccentBrush; row.Children.Add(icon);
        var title = new TextBlock { Text = ActivityText("title"), FontSize = 11, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(title, 1); row.Children.Add(title);
        var summary = new TextBlock { Text = ActivitySummary(data), FontSize = 11, Opacity = .75, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(summary, 2); row.Children.Add(summary);
        var chevron = new TextBlock { Text = "›", FontSize = 16, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(chevron, 3); row.Children.Add(chevron);
        var button = new Button { Content = row, Padding = new Thickness(10, 7, 10, 7), MinHeight = 32,
            Background = Theme.PanelBrush, BorderBrush = Theme.BorderBrush, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetName(button, ActivityText("details") + ": " + ActivitySummary(data));
        button.Click += async (_, _) => {
            var owner = InspectionOwner();
            try { await ShowActivityAsync("all"); }
            catch (Exception error) { if (InspectionOwner() == owner && IsLoaded) Banner(error.Message); }
        };
        _activitySummaryHost.Children.Add(button);
    }
    private async Task ShowActivityAsync(string section)
    {
        if (_commandDialog is not null || _commandDialogOpening || _imageDialog is not null || _openId is null) return;
        // Claim the dialog before discovery yields. A second tap or composer
        // command must not race this fetch into a second native modal window.
        _commandDialogOpening = true;
        try
        {
            var owner = InspectionOwner();
            await RefreshInspectionAsync(force: true);
            if (InspectionOwner() != owner || !IsLoaded) return;
            foreach (var key in _statsExpanded.Keys.Where(key => key.StartsWith("activity/dialog/", StringComparison.Ordinal)).ToArray()) _statsExpanded.Remove(key);
            var body = new StackPanel { Spacing = Theme.SpaceS };
            _commandDialogBody = body; _commandDialogOwner = owner; _commandActivitySection = section;
            RenderCommandStats();
            var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = ActivityText("title"),
                Content = new ScrollViewer { Content = body, MaxHeight = 560 }, CloseButtonText = L10n.Text("common.done") };
            _commandDialog = dialog;
            try { await dialog.ShowAsync(); }
            finally { _commandDialog = null; _commandDialogBody = null; _commandDialogOwner = null; _commandActivitySection = null; }
        }
        finally { _commandDialogOpening = false; }
    }
    private UIElement ActivityCard(JsonNode? inspection, bool expanded = false, string? section = null)
    {
        var data = ChatActivityData.Read(inspection, _openChat);
        var scope = section is null ? "inspector/" : "dialog/";
        FrameworkElement Details()
        {
            var body = new StackPanel { Spacing = 4 };
            if (data is null) body.Children.Add(Muted(ActivityText("unavailable")));
            else
            {
                body.Children.Add(Muted(ActivityText(data.Live ? "live" : "report_only")));
                FrameworkElement GoalDetails()
                {
                    var goalBody = new StackPanel { Spacing = 4 };
                    if (!data.GoalReported) goalBody.Children.Add(Muted(ActivityText("not_reported")));
                    else if (data.Goal is not { } goal) goalBody.Children.Add(Muted(ActivityText("none")));
                    else
                    {
                        goalBody.Children.Add(new TextBlock { Text = goal.Objective, FontSize = 12, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
                        goalBody.Children.Add(Muted(ActivityStatus(goal.Status, data.Live)));
                        AddActivityMetric(goalBody, "tokens", goal.TokensUsed, goal.TokenBudget);
                        AddActivityMetric(goalBody, "time", goal.TimeUsedSeconds, goal.TimeBudgetSeconds, seconds: true);
                        AddActivitySource(goalBody, goal.Source);
                    }
                    return goalBody;
                }
                body.Children.Add(ActivityDisclosure(ActivityText("goal"), scope + "goal", GoalDetails, section is "goal" or "all"));
                FrameworkElement PlanDetails()
                {
                    var planBody = new StackPanel { Spacing = 4 };
                    if (!data.PlanReported) planBody.Children.Add(Muted(ActivityText("not_reported")));
                    else if (data.Plan.Length == 0) planBody.Children.Add(Muted(ActivityText("none")));
                    else
                    {
                        planBody.Children.Add(Muted(ActivityText("steps", data.CompletedSteps.ToString("N0"), data.Plan.Length.ToString("N0"))));
                        planBody.Children.Add(ActivityProgress((double)data.CompletedSteps / data.Plan.Length));
                        for (var i = 0; i < data.Plan.Length; i++)
                        {
                            var step = data.Plan[i];
                            var row = new StackPanel { Spacing = 2, Margin = new Thickness(0, 2, 0, 2) };
                            row.Children.Add(new TextBlock { Text = $"{i + 1}. {step.Text}", FontSize = 12, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
                            row.Children.Add(Muted(ActivityStatus(step.Status, data.Live))); planBody.Children.Add(row);
                        }
                        AddActivitySource(planBody, data.PlanSource);
                    }
                    return planBody;
                }
                body.Children.Add(ActivityDisclosure(ActivityText("plan"), scope + "plan", PlanDetails, section is "plan" or "all"));
                FrameworkElement AgentDetails()
                {
                    var agentBody = new StackPanel { Spacing = 2 };
                    if (!data.AgentsReported) agentBody.Children.Add(Muted(ActivityText("not_reported")));
                    else if (data.Agents.Length == 0) agentBody.Children.Add(Muted(ActivityText("none")));
                    else foreach (var agent in data.Agents)
                    {
                        FrameworkElement AgentDetail()
                        {
                            var details = new StackPanel { Spacing = 4 };
                            details.Children.Add(Muted(agent.Id));
                            if (agent.Task is not null) details.Children.Add(new TextBlock { Text = agent.Task, FontSize = 12, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
                            if (agent.Model is not null) details.Children.Add(Muted(agent.Model));
                            AddActivitySource(details, agent.Source);
                            return details;
                        }
                        agentBody.Children.Add(ActivityDisclosure(agent.Name ?? agent.Id, scope + "agent/" + agent.Id, AgentDetail, status: ActivityStatus(agent.DisplayStatus(data.Live), data.Live)));
                    }
                    return agentBody;
                }
                body.Children.Add(ActivityDisclosure(ActivityText("subagents"), scope + "subagents", AgentDetails, section is "subagents" or "all"));
                if (data.Partial) body.Children.Add(Muted(ActivityText("partial")));
                if (data.ObservedAtMs is long stamp) body.Children.Add(Muted(ActivityText("last_reported", DateTimeOffset.FromUnixTimeMilliseconds(stamp).ToLocalTime().ToString("g"))));
            }
            return body;
        }
        var summary = data is null ? ActivityText("unavailable") : ActivitySummary(data);
        return ActivityDisclosure(ActivityText("title"), scope + "activity", Details, expanded, summary, card: true);
    }
    private UIElement ActivityDisclosure(string title, string key, Func<FrameworkElement> makeBody, bool initiallyExpanded = false, string? status = null, bool card = false)
    {
        var identity = "activity/" + key;
        var expanded = _statsExpanded.TryGetValue(identity, out var saved) ? saved : initiallyExpanded;
        var row = new Grid { ColumnSpacing = 6 };
        row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        row.Children.Add(new TextBlock { Text = title, FontWeight = FontWeights.SemiBold, FontSize = 12, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis });
        var chevron = new TextBlock { FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(chevron, 1); row.Children.Add(chevron);
        var header = new StackPanel { Spacing = 3 }; header.Children.Add(row);
        if (!string.IsNullOrEmpty(status)) header.Children.Add(new TextBlock { Text = status, FontSize = 11, Opacity = .7, TextTrimming = TextTrimming.CharacterEllipsis });
        var button = new Button { Content = header, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Background = Theme.PanelBrush, BorderThickness = new Thickness(0), Padding = new Thickness(0, 5, 0, 5), MinHeight = 30 };
        var body = new StackPanel();
        void State() {
            if (expanded && body.Children.Count == 0) body.Children.Add(makeBody());
            body.Visibility = expanded ? Visibility.Visible : Visibility.Collapsed; chevron.Text = expanded ? "⌃" : "⌄";
            AutomationProperties.SetHelpText(button, L10n.Text(expanded ? "common.collapse" : "common.expand"));
        }
        button.Click += (_, _) => { expanded = !expanded; _statsExpanded[identity] = expanded; State(); }; State();
        var stack = new StackPanel { Spacing = 3 }; stack.Children.Add(button); stack.Children.Add(body);
        return card ? new Border { Child = stack, Background = Theme.PanelBrush, BorderBrush = Theme.BorderBrush, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(Theme.CardRadius), Padding = new Thickness(12, 7, 12, 7) } : stack;
    }
    private static void AddActivitySource(StackPanel body, string? source)
    {
        if (source is not null) body.Children.Add(Muted(ActivityText("source", source is "agent" or "tool" ? ActivityText("source_" + source) : source)));
    }
    private static void AddActivityMetric(StackPanel body, string label, double? used, double? budget, bool seconds = false)
    {
        if (used is null && budget is null) return;
        string Amount(double? value) => value is not double amount ? ActivityText("not_reported") : seconds ? ActivityText("seconds", amount.ToString("N0")) : amount.ToString("N0");
        var text = budget is null ? Amount(used) : ActivityText("progress", Amount(used), Amount(budget));
        body.Children.Add(StatsMetric(ActivityText(label), text));
        if (ChatActivityData.Progress(used, budget) is double fraction) body.Children.Add(ActivityProgress(fraction));
    }
    private static ProgressBar ActivityProgress(double fraction) => new() { Minimum = 0, Maximum = 1, Value = fraction,
        Height = 4, MinHeight = 0, IsHitTestVisible = false, HorizontalAlignment = HorizontalAlignment.Stretch };
}
