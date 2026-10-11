// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Tokenstat.Host;
using Tokenstat.Navigation;

namespace Tokenstat.Pages;
internal sealed partial class ChatPage
{
    private static string RoutingActivityLabel(string kind) => kind switch
    {
        "usage" => L10n.Text("common.chat_route_event_usage"),
        "throttle" => L10n.Text("common.chat_route_event_throttle"),
        "error" => L10n.Text("common.chat_route_event_error"),
        "auth" => L10n.Text("common.chat_route_event_auth"),
        "failure" => L10n.Text("common.chat_route_event_failure"),
        "settings" => L10n.Text("common.chat_route_event_settings"),
        "switched" => L10n.Text("common.chat_route_event_switched"),
        "resumed" => L10n.Text("common.chat_route_event_resumed"),
        "returned" => L10n.Text("common.chat_route_event_returned"),
        "cancelled" => L10n.Text("common.chat_route_event_cancelled"),
        "skipped" => L10n.Text("common.chat_route_event_skipped"),
        _ => L10n.Text("common.chat_route_event_paused")
    };
    private UIElement RoutingControls()
    {
        var body = new StackPanel { Spacing = Theme.SpaceS };
        if (_openId is not string chat) return body;
        var generation = _openGeneration;
        var accountGeneration = AppServices.AccountGeneration;
        var snapshot = _openChat;
        bool Current() => OpenChatIs(chat) && generation == _openGeneration && accountGeneration == AppServices.AccountGeneration;
        async Task ApplyAsync(string method, JsonObject extra)
        {
            try
            {
                if (!Current() || snapshot?["sendRevision"] is null) return;
                var request = new JsonObject { ["id"] = chat, ["expectedRevision"] = Format.Long(snapshot, "sendRevision") };
                foreach (var item in extra) request[item.Key] = item.Value?.DeepClone();
                await CallChatAsync(method, request);
                if (!Current()) return;
                await RefreshCatalogAsync();
                if (Current()) { _openChat = FindChat(chat); PaintConversation(); StartPoll(); }
            }
            catch (Exception ex) { if (Current()) Banner(ex.Message); }
        }
        if (snapshot?["routing"] is JsonObject state && state["limit"] is JsonObject limit)
        {
            body.Children.Add(new TextBlock { Text = (Format.Text(limit, "kind") == "usage" ? L10n.Text("common.chat_limit_reached", Format.Text(limit, "provider")) : Format.Text(limit, "kind") == "throttle" ? L10n.Text("common.chat_throttled", Format.Text(limit, "provider")) : L10n.Text("common.chat_route_failure", Format.Text(limit, "provider"))), TextWrapping = TextWrapping.Wrap, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
            body.Children.Add(Muted(Format.Text(limit, "reason")));
            var reset = limit["resetsAtMs"] is null ? (long?)null : Format.Long(limit, "resetsAtMs");
            body.Children.Add(Muted(reset.HasValue ? L10n.Text("common.chat_resets_at", DateTimeOffset.FromUnixTimeMilliseconds(reset.Value).LocalDateTime.ToString("g")) : L10n.Text("common.chat_reset_unknown")));
            var nextReset = state["nextReset"] as JsonObject;
            if(nextReset is not null && Format.Text(nextReset["destination"], "backend") != Format.Text(limit, "provider")) body.Children.Add(Muted(L10n.Text("common.chat_route_waiting_for", Format.Text(nextReset["destination"], "backend"), DateTimeOffset.FromUnixTimeMilliseconds(Format.Long(nextReset, "atMs")).ToLocalTime().ToString("g"))));
            if (Format.Flag(state, "needsDeliveryCheck")) body.Children.Add(Muted(L10n.Text("common.chat_route_delivery")));
            if (Format.Text(state, "note") is string note && note.Length > 0) body.Children.Add(Muted(note));
            var policy = state["policy"] as JsonObject;
            var wait = new CheckBox { Content = L10n.Text("common.chat_wait_reset"), IsChecked = Format.Flag(policy, "waitForReset"), IsEnabled = (reset.HasValue || nextReset is not null) && !Format.Flag(state, "needsDeliveryCheck") };
            wait.Click += async (_, _) => { var changed = (JsonObject?)policy?.DeepClone() ?? new JsonObject(); changed["waitForReset"] = wait.IsChecked == true; await ApplyAsync("chat.routing", new JsonObject { ["routing"] = changed }); };
            body.Children.Add(wait);
            var actions = new FlowPanel { Spacing = Theme.SpaceS };
            var retry = ActionIconGlyph.Button(L10n.Text("common.chat_route_retry"), ActionIcon.Refresh, async (_, _) => await ApplyAsync("chat.routeAction", new JsonObject { ["choice"] = "resume" }));
            retry.IsEnabled = !Format.Flag(snapshot, "running") && !Format.Flag(state, "needsDeliveryCheck");
            actions.Children.Add(retry);
            actions.Children.Add(ActionIconGlyph.Button(L10n.Text("common.cancel"), ActionIcon.Dismiss, async (_, _) => await ApplyAsync("chat.routeAction", new JsonObject { ["choice"] = "cancel" })));
            body.Children.Add(actions);
        }
        var routing = new StackPanel { Spacing = Theme.SpaceS };
        var routePolicy = snapshot?["routing"]?["policy"];
        routing.Children.Add(Muted(Format.Flag(routePolicy, "enabled") ? Format.Flag(routePolicy, "waitForReset") ? L10n.Text("common.chat_route_combined_mode") : L10n.Text("common.chat_route_fallback_mode") : Format.Flag(routePolicy, "waitForReset") ? L10n.Text("common.chat_route_wait_mode") : L10n.Text("common.chat_route_manual")));
        if (routePolicy?["routes"] is JsonArray destinations && destinations.Count > 0) routing.Children.Add(Muted(string.Join(" → ", destinations.Select(d => Format.Text(d, "backend")))));
        if (Format.Flag(routePolicy, "returnPreferred")) routing.Children.Add(Muted(L10n.Text("common.chat_route_preferred", Format.Text(routePolicy?["preferred"] ?? snapshot?["routing"]?["preferred"], "backend", Format.Text(snapshot, "backend")))));
        routing.Children.Add(ActionIconGlyph.PrimaryButton(L10n.Text("common.chat_route_setup"), ActionIcon.Settings, async (_, _) => await ShowRoutingAsync()));
        body.Children.Add(SetupSection(L10n.Text("common.chat_routing"), routing, ActionIcon.Settings, L10n.Text("common.chat_routing_intro")));
        return body;
    }

    private async Task ShowRoutingAsync()
    {
        if (_openId is not string chat) return;
        var generation = _openGeneration;
        var accountGeneration = AppServices.AccountGeneration;
        bool Current() => OpenChatIs(chat) && generation == _openGeneration && accountGeneration == AppServices.AccountGeneration;
        try
        {
            var protocol = RemoteFeatureGate.ProtocolOf(await CallChatAsync("protocol", new JsonObject()));
            if (!Current()) return;
            if (protocol < 34) { Banner(L10n.Text("common.chat_route_unavailable")); return; }
            var state = await CallChatAsync("chat.routing", new JsonObject { ["id"] = chat });
            if (!Current()) return;
            var revision = _openChat?["sendRevision"]?.DeepClone();
            var policy = (JsonObject?)state["policy"]?.DeepClone() ?? new JsonObject();
            var routes = (policy["routes"] as JsonArray)?.Select(r => (JsonObject)r!.DeepClone()).ToList() ?? [];
            var enabled = new CheckBox { Content = L10n.Text("common.chat_routing_enabled"), IsChecked = Format.Flag(policy, "enabled") };
            var wait = new CheckBox { Content = L10n.Text("common.chat_wait_reset"), IsChecked = Format.Flag(policy, "waitForReset") };
            var returns = new CheckBox { Content = L10n.Text("common.chat_return_preferred"), IsChecked = Format.Flag(policy, "returnPreferred") };
            var defaults = new CheckBox { Content = L10n.Text("common.chat_route_default"), IsChecked = Format.Flag(policy, "useAsDefault") };
            var throttles = new CheckBox { Content = L10n.Text("common.chat_route_throttle"), IsChecked = Format.Flag(policy, "failoverOnThrottle") };
            var outages = new CheckBox { Content = L10n.Text("common.chat_route_errors"), IsChecked = Format.Flag(policy, "failoverOnErrors") };
            var auth = new CheckBox { Content = L10n.Text("common.chat_route_auth"), IsChecked = Format.Flag(policy, "failoverOnAuth") };
            var failures = new CheckBox { Content = L10n.Text("common.chat_route_agent_errors"), IsChecked = Format.Flag(policy, "failoverOnFailures") };
            var notifies = new CheckBox { Content = L10n.Text("common.chat_route_notify"), IsChecked = policy["notify"]?.GetValue<bool>() != false };
            var body = new StackPanel { Spacing = Theme.SpaceM, MaxWidth = 560 };
            body.Children.Add(Muted(L10n.Text("common.chat_route_explanation")));
            body.Children.Add(enabled); body.Children.Add(wait); body.Children.Add(returns); body.Children.Add(defaults);
            var advanced = new StackPanel { Spacing = Theme.SpaceS };
            advanced.Children.Add(throttles); advanced.Children.Add(outages); advanced.Children.Add(auth); advanced.Children.Add(failures); advanced.Children.Add(notifies);
            body.Children.Add(new Expander { Header = L10n.Text("common.settings"), Content = advanced, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch });
            body.Children.Add(Muted(L10n.Text("common.chat_route_policy_help")));
            body.Children.Add(Muted(L10n.Text("common.chat_route_priority_help")));
            body.Children.Add(Muted(L10n.Text("common.chat_route_preferred", Format.Text(state["preferred"], "backend") is { Length: > 0 } preferred ? preferred : Format.Text(_openChat, "backend"))));
            body.Children.Add(Chrome.SectionLabel(L10n.Text("common.chat_route_order")));
            var rows = new StackPanel { Spacing = Theme.SpaceS }; body.Children.Add(rows);
            var preferredPicker = new ComboBox { Header = L10n.Text("common.chat_route_preferred_picker"), HorizontalAlignment = HorizontalAlignment.Stretch };
            JsonObject? preferredRoute = policy["preferred"] as JsonObject;
            var repaintingPreferred = false;
            void PaintRoutes()
            {
                rows.Children.Clear();
                repaintingPreferred = true;
                preferredPicker.Items.Clear();
                preferredPicker.Items.Add(new ComboBoxItem { Content = L10n.Text("common.chat_route_current_preferred") });
                var preferredIndex = 0;
                foreach (var candidate in routes)
                {
                    preferredPicker.Items.Add(new ComboBoxItem { Content = Format.Text(candidate, "backend"), Tag = candidate });
                    if (ReferenceEquals(candidate, preferredRoute) || JsonNode.DeepEquals(candidate, preferredRoute)) { preferredRoute = candidate; preferredIndex = preferredPicker.Items.Count - 1; }
                }
                preferredPicker.SelectedIndex = preferredIndex;
                preferredRoute = (preferredPicker.SelectedItem as ComboBoxItem)?.Tag as JsonObject;
                repaintingPreferred = false;
                for (var i = 0; i < routes.Count; i++)
                {
                    var index = i; var route = routes[i];
                    var row = new StackPanel { Spacing = Theme.SpaceS };
                    row.Children.Add(Muted($"{index + 1}. {Format.Text(route, "backend")}"));
                    if (Format.Text(route, "backend") == "muse" && Format.Text(_openChat, "autonomy") != "bypass") row.Children.Add(Muted(L10n.Text("common.chat_route_permissions")));
                    var models = new ComboBox { Header = L10n.Text("windows.chatpage.model.5e2c614c"), HorizontalAlignment = HorizontalAlignment.Stretch };
                    var choices = new List<string> { "" };
                    if (Backend(Format.Text(route, "backend"))?["models"] is JsonArray list) choices.AddRange(list.Select(m => m?.GetValue<string>() ?? "").Where(m => m.Length > 0));
                    var selected = Format.Text(route, "model"); if (!choices.Contains(selected)) choices.Add(selected);
                    foreach (var model in choices) models.Items.Add(new ComboBoxItem { Content = model.Length == 0 ? L10n.Text("windows.chatpage.default.21b111cb") : model, Tag = model });
                    models.SelectedIndex = choices.IndexOf(selected);
                    models.SelectionChanged += (_, _) => { if (models.SelectedItem is ComboBoxItem choice) route["model"] = (string?)choice.Tag; };
                    row.Children.Add(models);
                    if (Backend(Format.Text(route, "backend"))?["efforts"] is JsonArray effortList && effortList.Count > 0)
                    {
                        var effort = new ComboBox { Header = L10n.Text("windows.chatpage.effort.4387e5d3"), HorizontalAlignment = HorizontalAlignment.Stretch };
                        var effortChoices = new List<string> { "" };
                        effortChoices.AddRange(effortList.Select(e => e?.GetValue<string>() ?? "").Where(e => e.Length > 0));
                        var selectedEffort = Format.Text(route, "effort");
                        if (!effortChoices.Contains(selectedEffort)) effortChoices.Add(selectedEffort);
                        foreach (var value in effortChoices) effort.Items.Add(new ComboBoxItem { Content = value.Length == 0 ? L10n.Text("windows.chatpage.default.21b111cb") : value, Tag = value });
                        effort.SelectedIndex = effortChoices.IndexOf(selectedEffort);
                        effort.SelectionChanged += (_, _) => { if (effort.SelectedItem is ComboBoxItem picked) route["effort"] = ((string?)picked.Tag)?.Length > 0 ? (string?)picked.Tag : null; };
                        row.Children.Add(effort);
                    }

                    var actions = new FlowPanel { Spacing = Theme.SpaceS };
                    var up = ActionIconGlyph.Button(L10n.Text("common.move_up"), ActionIcon.Move, (_, _) => { (routes[index - 1], routes[index]) = (routes[index], routes[index - 1]); PaintRoutes(); }); up.IsEnabled = index > 0; actions.Children.Add(up);
                    actions.Children.Add(ActionIconGlyph.Button(L10n.Text("common.remove"), ActionIcon.Delete, (_, _) => { routes.RemoveAt(index); PaintRoutes(); }));
                    row.Children.Add(actions); rows.Children.Add(row);
                }
            }
            PaintRoutes();
            preferredPicker.SelectionChanged += (_, _) => { if (!repaintingPreferred) preferredRoute = (preferredPicker.SelectedItem as ComboBoxItem)?.Tag as JsonObject; };
            body.Children.Add(preferredPicker);
            var add = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch };
            foreach (var backend in _backends.Where(b => Format.Text(b, "id") != "sh" && Installed(b))) add.Items.Add(new ComboBoxItem { Content = Format.Text(backend, "label"), Tag = Format.Text(backend, "id") });
            add.PlaceholderText = L10n.Text("common.add");
            add.SelectionChanged += (_, _) => { if (add.SelectedItem is ComboBoxItem picked && routes.Count < 8) { routes.Add(new JsonObject { ["backend"] = (string?)picked.Tag }); add.SelectedIndex = -1; PaintRoutes(); } };
            body.Children.Add(add);
            var history = new StackPanel { Spacing = Theme.SpaceS };
            string? historyCursor = null;
            var historyLoading = false;
            void PaintHistory(JsonArray? activity)
            {
                history.Children.Clear();
                if (activity is { Count: > 0 })
                {
                    foreach (var entry in activity.Reverse())
                    {
                        history.Children.Add(Muted($"{RoutingActivityLabel(Format.Text(entry, "kind"))} · {DateTimeOffset.FromUnixTimeMilliseconds(Math.Clamp(Format.Long(entry, "atMs"), 0, 253402300799999)).ToLocalTime():g}"));
                        if(entry?["target"] is JsonObject target) history.Children.Add(Muted($"{Format.Text(entry["source"], "backend")} → {Format.Text(target, "backend")} · {Format.Text(target, "model")} · {Format.Text(target, "effort")}"));
                        history.Children.Add(Muted(Format.Text(entry, "reason")));
                    }
                }
                else history.Children.Add(Muted(L10n.Text("common.chat_route_empty_history")));
                var actions = new FlowPanel { Spacing = Theme.SpaceS };
                actions.Children.Add(ActionIconGlyph.Button(L10n.Text("common.refresh"), ActionIcon.Refresh, async (_, _) => await LoadHistory(null)));
                if (historyCursor is not null) actions.Children.Add(ActionIconGlyph.Button(L10n.Text("common.chat_route_older"), ActionIcon.History, async (_, _) => await LoadHistory(historyCursor)));
                history.Children.Add(actions);
            }
            async Task LoadHistory(string? cursor)
            {
                if(historyLoading || !Current()) return;
                historyLoading = true;
                try
                {
                    var request = new JsonObject { ["id"] = chat };
                    if(cursor is not null) request["cursor"] = cursor;
                    var page = await CallChatAsync("chat.routingHistory", request);
                    if(!Current()) return;
                    historyCursor = page["cursor"]?.GetValue<string>();
                    PaintHistory(page["activity"] as JsonArray);
                }
                catch(Exception error) { if(Current()) history.Children.Add(Muted(error.Message)); }
                finally { historyLoading = false; }
            }
            PaintHistory(state["activity"] as JsonArray);
            var historyExpander = new Expander { Header = L10n.Text("common.chat_route_history"), Content = history, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch };
            historyExpander.Expanding += async (_, _) => await LoadHistory(null);
            body.Children.Add(historyExpander);
            var dialog = new ContentDialog { Title = L10n.Text("common.chat_routing"), Content = new ScrollViewer { Content = body, MaxHeight = 500 }, PrimaryButtonText = L10n.Text("common.save"), CloseButtonText = L10n.Text("common.cancel") };
            if (await Chrome.ShowDialog(this, dialog) != ContentDialogResult.Primary || !Current() || revision is null) return;
            policy["enabled"] = enabled.IsChecked == true; policy["waitForReset"] = wait.IsChecked == true; policy["returnPreferred"] = returns.IsChecked == true; policy["useAsDefault"] = defaults.IsChecked == true; policy["failoverOnThrottle"] = throttles.IsChecked == true; policy["failoverOnErrors"] = outages.IsChecked == true; policy["failoverOnAuth"] = auth.IsChecked == true; policy["failoverOnFailures"] = failures.IsChecked == true; policy["notify"] = notifies.IsChecked == true; policy["preferred"] = preferredRoute?.DeepClone();
            policy["routes"] = new JsonArray(routes.Select(r => (JsonNode)r.DeepClone()).ToArray());
            await CallChatAsync("chat.routing", new JsonObject { ["id"] = chat, ["expectedRevision"] = revision, ["routing"] = policy });
            if (!Current()) return;
            await RefreshCatalogAsync(); if (Current()) { _openChat = FindChat(chat); PaintConversation(); StartPoll(); }
        }
        catch (Exception ex) { if (Current()) Banner(ex.Message); }
    }
}
