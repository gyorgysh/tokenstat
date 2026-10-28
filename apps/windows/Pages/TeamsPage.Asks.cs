// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Tokenstat.Host;

namespace Tokenstat.Pages;

internal sealed partial class TeamsPage
{
    private static string AskMessage(string value, string computer) => value switch {
        "ask_save_failed" => L10n.Text("common.teams.ask_save_failed"),
        "ask_unconfirmed" => L10n.Text("common.teams.ask_unconfirmed"),
        "run_status_unconfirmed" => L10n.Text("common.teams.run_status_unconfirmed"),
        "agent_runs_off" => L10n.Text("common.teams.agent_runs_off", computer),
        "agent_waiting_approval" => L10n.Text("common.teams.agent_waiting_approval", computer),
        "agent_approval_expired" => L10n.Text("common.teams.agent_approval_expired", computer),
        _ => value,
    };
    private async Task<TeamAskModel?> AskModelAsync(JsonObject target, string title, string computer)
    {
        var checkout = (JsonObject)target.DeepClone(); checkout.Remove("share");
        var host = _checkoutHosts.GetValueOrDefault(checkout.ToJsonString());
        var origin = Format.Text(_scope, "origin"); var person = _person;
        if (origin.Length == 0 || string.IsNullOrEmpty(person) || string.IsNullOrEmpty(host)) return null;
        var binding = new TeamCommentTarget(origin, person, Format.Text(target, "organization"), Format.Text(target, "repository"), Format.Text(target, "checkout"), Format.Text(target, "share"), host);
        if (!_asks.TryGetValue(binding, out var model))
        {
            var scope = _scope!.DeepClone(); var session = _session;
            bool Current() => _scope?.ToJsonString() == scope.ToJsonString() && _session == session && _person == person;
            async Task<JsonNode> BoundCall(string method, JsonObject parameters)
            {
                try { return await _call("teams.ask", new JsonObject {
                    ["target"] = target.DeepClone(), ["method"] = method, ["params"] = parameters.DeepClone(),
                    ["_accountScope"] = scope.DeepClone(), ["_accountSession"] = session,
                }); }
                catch (HostException failure) when (method == "team.chat.ask" && failure.Code is "team_run_review_changed" or "invalid_ask" or "team_agent_request_denied" or "team_agent_runs_off") { throw new TeamAskNotAccepted(failure.Message); }
                catch (HostException failure) when (method == "team.chat.ask" && failure.Code == "team_agent_approval_pending") { throw new TeamAskAwaitingApproval(); }
            }
            static string Label(string value) => string.Concat(value.EnumerateRunes().Take(160)
                .Where(r => System.Text.Rune.GetUnicodeCategory(r) != System.Globalization.UnicodeCategory.Format)
                .Select(r => System.Text.Rune.IsControl(r) ? " " : r.ToString()));
            _asks[binding] = model = new(_askStorage, binding, Label(title) + " · " + Label(computer), Current, BoundCall);
        }
        await model.RestoreAsync(); return model;
    }
    private (StackPanel Panel, Action<bool> Allow) AskControls(TeamAskModel model, JsonObject target, string title, string computer, int view)
    {
        var allowed = false;
        var panel = new StackPanel { Spacing = Theme.SpaceS };
        var note = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var status = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var detail = new TextBlock { Text = L10n.Text("common.teams.ask_runs_on", computer), FontSize = 12, Opacity = 0.7, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
        ToolTipService.SetToolTip(detail, L10n.Text("common.teams.ask_detail", computer));
        var question = new TextBox { Text = model.Text, PlaceholderText = L10n.Text("common.teams.ask_placeholder"), AcceptsReturn = true, TextWrapping = TextWrapping.Wrap,
            BorderThickness = new Thickness(0), Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent), MinHeight = 40, MaxHeight = 180 };
        question.Resources["TextControlBackgroundFocused"] = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent);
        question.Resources["TextControlBackgroundPointerOver"] = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent);
        question.Resources["TextControlBorderThemeThicknessFocused"] = new Thickness(0);
        Button? ask = null;
        ask = Buttons.Primary(L10n.Text("common.teams.ask"), ActionIcon.Run, async (_, _) => {
            await model.AskAsync();
            if (IsLoaded && _view == view) await ShowChatAsync(target, title, computer);
        });
        var stop = Buttons.Destructive(L10n.Text("common.teams.stop_agent"), ActionIcon.Stop, async (_, _) => await model.StopAsync(), small: true);
        var retry = Buttons.Secondary(L10n.Text("common.teams.load_saved_ask"), ActionIcon.Refresh, async (_, _) => await model.RestoreAsync(true), small: true);
        Grid? running = null; Grid? footer = null;
        void Update()
        {
            if (!IsLoaded || _view != view) return;
            panel.Visibility = allowed || model.Fence is not null || model.Pending || model.Error is not null ? Visibility.Visible : Visibility.Collapsed;
            note.Text = model.Error is { } error ? AskMessage(error, computer) : "";
            question.Visibility = ask.Visibility = model.Fence is null && (allowed || model.Pending) ? Visibility.Visible : Visibility.Collapsed;
            detail.Visibility = question.Visibility;
            question.IsReadOnly = !model.Loaded || model.Busy || model.Pending;
            if (question.Text != model.Text) question.Text = model.Text;
            ask.IsEnabled = model.CanAsk;
            var name = L10n.Text(model.Pending ? "common.teams.retry_same_ask" : "common.teams.ask");
            ((StackPanel)ask.Content).Children.OfType<TextBlock>().Last().Text = name;
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(ask, name);
            status.Visibility = stop.Visibility = model.Fence is null ? Visibility.Collapsed : Visibility.Visible;
            status.Text = model.Stopping ? L10n.Text("common.teams.agent_stopping") : L10n.Text("common.teams.agent_working", computer);
            stop.IsEnabled = !model.Stopping;
            retry.Visibility = model.Fence is null && model.Error is not null ? Visibility.Visible : Visibility.Collapsed;
            retry.IsEnabled = !model.Busy;
            if (running is not null) running.Visibility = status.Visibility;
            if (footer is not null) footer.Visibility = question.Visibility == Visibility.Visible || retry.Visibility == Visibility.Visible ? Visibility.Visible : Visibility.Collapsed;
        }
        question.TextChanged += (_, _) => { if (_view == view && !model.Pending && !model.Busy && question.Text != model.Text) { model.Text = question.Text; Update(); } };
        // Running state on one line with Stop at its end; otherwise the field,
        // then where it runs on the leading side and Ask on the trailing side.
        status.Foreground = Theme.AccentBrush; status.VerticalAlignment = VerticalAlignment.Center;
        running = Row(status, stop); footer = Row(detail, retry, ask);
        panel.Children.Add(note); panel.Children.Add(running); panel.Children.Add(question); panel.Children.Add(footer);
        model.Changed = Update;
        Update();
        return (panel, value => { allowed = value; Update(); });
    }
    private async Task WatchAskAsync(TeamAskModel model, JsonObject target, string title, string computer, int view, Func<bool> canRefresh)
    {
        while (model.Fence is not null)
        {
            await Task.Delay(3000);
            if (!IsLoaded || _view != view) return;
            await model.CheckAsync();
            if (!IsLoaded || _view != view) return;
            if (model.Error == "run_status_unconfirmed") continue;
            if (_fileOperations == 0 && canRefresh() && _body.Children.OfType<TextBox>().All(input => input.Text.Length == 0))
            {
                await ShowChatAsync(target, title, computer); return;
            }
        }
    }
}
