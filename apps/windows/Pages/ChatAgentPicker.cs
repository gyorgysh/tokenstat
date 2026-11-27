// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Globalization;
using System.Text.Json.Nodes;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Tokenstat.Design;
using Tokenstat.Navigation;
using Windows.System;

namespace Tokenstat.Pages;

/// <summary>
/// Where the agent field reads and writes its choice. A running chat writes
/// through the host; the start page writes into its unsent draft.
/// </summary>
internal sealed record ChatAgentPickerSource(
    Func<JsonNode?> Chat,
    Func<IEnumerable<JsonNode?>> Backends,
    Func<JsonObject, Task<bool>> Update,
    Action Repaint,
    Func<bool>? Suppressed = null,
    Func<JsonNode, Task>? SignIn = null,
    /// <summary>Update this agent with its own updater (protocol 55).</summary>
    Func<JsonNode, Task>? UpdateAgent = null,
    Func<AgentProfiles?>? Profiles = null,
    Func<string>? SelectedProfile = null,
    Func<string?>? ProfileLock = null,
    Func<string, Task>? PickProfile = null,
    string? LimitsWorkspace = null,
    /// <summary>Read the profiles again after somebody manages them from the menu.</summary>
    Func<Task>? ReloadProfiles = null);

/// <summary>
/// The composer's agent field, as on the Mac: the harness mark, the model
/// and effort, opening one panel that asks agent, then model, then effort.
/// Shared by the chat composer and the start page so they cannot drift.
/// </summary>
internal static class ChatAgentPicker
{
    /// <summary>
    /// Whether an agent is on this computer. Missing means the host did not
    /// say, which is not the same as absent: only an explicit false hides it.
    /// </summary>
    internal static bool Installed(JsonNode? backend) =>
        backend?["installed"] is not JsonValue flag
        || flag.GetValueKind() != System.Text.Json.JsonValueKind.False;

    /// <summary>A short note on an agent row when it may not run as is.</summary>
    internal static string? Readiness(JsonNode? backend) => Format.Text(backend, "readiness") switch
    {
        "needsSignIn" => L10n.Text("windows.chatpage.sign_in_may_be_needed.c3dde98c"),
        "expired" => L10n.Text("windows.chatpage.stored_login_has_expired.bf189dae"),
        _ => null,
    };

    /// <summary>
    /// The agent, then a model or an effort only when one was chosen.
    /// The panel this opens is where the defaults are named.
    /// </summary>
    /// <summary>The last limits reading, shared by every open picker.</summary>
    private static long s_limitsAccount = -1;
    private static readonly Dictionary<string, (JsonArray Rows, DateTimeOffset Date)> LimitsByHost = new();

    private static FrameworkElement? QuotaLine(JsonArray? readings, string backend, string? profileId)
    {
        if (readings is null || ChatQuotaData.Read(readings, backend, profileId) is not { } provider) return null;
        var rows = ChatQuotaData.Headline(provider);
        if (rows.Count == 0) return null;
        var stale = provider["stale"] is JsonValue flag && flag.TryGetValue<bool>(out var old) && old;
        var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
        for (var i = 0; i < rows.Count; i++)
        {
            if (i > 0) line.Children.Add(new TextBlock { Text = "·", FontSize = 11, Opacity = 0.4 });
            line.Children.Add(new TextBlock { Text = rows[i].Tag, FontSize = 11, Opacity = 0.7 });
            var percent = rows[i].Percent;
            line.Children.Add(new TextBlock
            {
                Text = percent.ToString("0", CultureInfo.CurrentCulture) + "%", FontSize = 11,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                Foreground = stale ? Theme.Brush(static () => Theme.Secondary)
                    : percent >= 90 ? Theme.Brush(static () => Theme.Danger)
                    : percent >= 70 ? Theme.Brush(static () => Theme.Warning) : Theme.AccentBrush,
            });
        }
        AutomationProperties.SetName(line, string.Join(", ", rows.Select(r => $"{r.Tag} {r.Percent:0}%")));
        return line;
    }

    internal static string Summary(JsonNode? backend, string backendId, string model, string effort)
    {
        var parts = new List<string> { Format.Text(backend, "label", backendId) };
        if (!string.IsNullOrEmpty(model)) parts.Add(LocalChatModel.Title(model));
        if (backend?["efforts"] is JsonArray { Count: > 0 } && !string.IsNullOrEmpty(effort)) parts.Add(effort + " effort");
        return string.Join(" · ", parts);
    }

    internal static Button Build(ChatAgentPickerSource source, bool locked)
    {
        JsonNode? Backend(string id) => source.Backends().FirstOrDefault(backend => Format.Text(backend, "id") == id);
        var chat = source.Chat() ?? new JsonObject();
        var backendId = Format.Text(chat, "backend");
        var backend = Backend(backendId);
        var model = Format.Text(chat, "model");
        var effort = Format.Text(chat, "effort");
        var label = backendId.Length == 0 ? L10n.Text("common.chat.select_agent") : Summary(backend, backendId, model, effort);
        var account = AppServices.AccountGeneration;
        if (s_limitsAccount != account)
        {
            s_limitsAccount = account;
            LimitsByHost.Clear();
        }
        var workspace = source.LimitsWorkspace;
        var host = workspace is not null && RemoteWorkspaces.TrySplit(workspace, out var peer, out _) ? peer : "";
        JsonArray? Readings() => account == AppServices.AccountGeneration && LimitsByHost.TryGetValue(host, out var entry)
            ? entry.Rows : null;
        var profiles = source.Profiles?.Invoke();
        var profileId = source.SelectedProfile?.Invoke() ?? AgentProfiles.SystemId;
        var profileLabel = profileId != AgentProfiles.SystemId ? profiles?.Title(profileId) : null;
        if (profileLabel is not null) label += " · " + profileLabel;
        var field = new Grid { MaxWidth = 280, ColumnSpacing = 6 };
        field.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        field.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        field.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var mark = AgentMark.View(backendId, 16);
        mark.VerticalAlignment = VerticalAlignment.Center;
        AutomationProperties.SetAccessibilityView(mark, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        if (backendId.Length > 0) field.Children.Add(mark);
        var modelText = new TextBlock
        {
            Text = backendId.Length == 0 ? label : string.IsNullOrWhiteSpace(model) ? Format.Text(backend, "label", backendId) : LocalChatModel.Title(model),
            TextWrapping = TextWrapping.NoWrap, TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
        };
        if (profileLabel is not null) modelText.Text += " · " + profileLabel;
        Grid.SetColumn(modelText, 1);
        field.Children.Add(modelText);
        if (backend?["efforts"] is JsonArray { Count: > 0 } && !string.IsNullOrWhiteSpace(effort))
        {
            var effortText = new TextBlock { Text = "· " + effort, TextWrapping = TextWrapping.NoWrap,
                VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(effortText, 2);
            field.Children.Add(effortText);
        }
        var behind = Format.Flag(backend, "updateAvailable") && Installed(backend);
        if (behind)
        {
            field.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var dot = new Microsoft.UI.Xaml.Shapes.Ellipse
            {
                Width = 7, Height = 7, Fill = Theme.AccentBrush,
                VerticalAlignment = VerticalAlignment.Top,
            };
            AutomationProperties.SetAccessibilityView(dot, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
            Grid.SetColumn(dot, 3);
            field.Children.Add(dot);
        }

        // Agent, then model, then effort, one question at a time. Picking a
        // row answers the step and moves on, the last step closes the panel,
        // and the strip at the top says what each step is set to and goes back
        // to any of them. The conversation repaints once, when the panel
        // closes: repainting mid-way would rebuild this button under the open
        // flyout and close it.
        var flyout = new Flyout();
        var panel = new StackPanel { Spacing = Theme.SpaceS, Width = 360 };
        var header = new Grid { ColumnSpacing = Theme.SpaceS };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(new TextBlock { Text = L10n.Text("windows.chatpage.agent_model_and_effort.217ff8ae"), FontSize = 16, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        if (profiles is not null && source.PickProfile is { } pickProfile &&
            profiles.Picker(profileId, source.ProfileLock?.Invoke(), !locked, async id =>
            {
                await pickProfile(id);
                flyout.Hide();
                source.Repaint();
            }, async () =>
            {
                flyout.Hide();
                if (source.ReloadProfiles is { } reload) await reload();
                source.Repaint();
            }) is FrameworkElement picker)
        {
            Grid.SetColumn(picker, 1);
            header.Children.Add(picker);
        }
        panel.Children.Add(header);
        var strip = new Grid { ColumnSpacing = 2 };
        panel.Children.Add(new Border
        {
            Child = strip, Padding = new Thickness(3), CornerRadius = new CornerRadius(10),
            Background = Theme.BackgroundBrush, BorderBrush = Theme.BorderBrush, BorderThickness = new Thickness(1),
        });
        var searchRow = new Grid { ColumnSpacing = Theme.SpaceS };
        searchRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        searchRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var back = new Button { Content = ActionIcon.Back.Icon(), MinWidth = 40, MinHeight = 36, Padding = new Thickness(8, 4, 8, 4) };
        AutomationProperties.SetName(back, L10n.Text("common.back"));
        ToolTipService.SetToolTip(back, L10n.Text("common.back"));
        searchRow.Children.Add(back);
        var search = new TextBox();
        Grid.SetColumn(search, 1);
        searchRow.Children.Add(search);
        panel.Children.Add(searchRow);
        var choices = new StackPanel { Spacing = 4 };
        panel.Children.Add(new ScrollViewer { MaxHeight = 360, Content = choices, HorizontalScrollMode = ScrollMode.Disabled });
        var step = ChatAgentSteps.Agent;
        var changed = false;
        var picking = false;
        var flyoutOpen = false;

        string StepTitle(string name) => name switch
        {
            ChatAgentSteps.Model => L10n.Text("windows.chatpage.model.5e2c614c"),
            ChatAgentSteps.Effort => L10n.Text("windows.chatpage.effort.4387e5d3"),
            _ => L10n.Text("windows.chatpage.agent.11b39c93"),
        };
        string StepPrompt(string name) => name switch
        {
            ChatAgentSteps.Model => L10n.Text("windows.chatpage.search_models.10421935"),
            ChatAgentSteps.Effort => L10n.Text("windows.chatpage.search_efforts.f7909b52"),
            _ => L10n.Text("windows.chatpage.search_agents.212fd04a"),
        };
        // Read fresh every time: picking an agent changes which models and
        // efforts exist while the panel is still open.
        JsonNode Chat() => source.Chat() ?? new JsonObject();
        JsonNode? CurrentBackend() => Backend(Format.Text(Chat(), "backend"));
        IReadOnlyList<string> Steps()
        {
            var current = CurrentBackend();
            return ChatAgentSteps.For(current is not null && Installed(current),
                current?["efforts"] is JsonArray { Count: > 0 });
        }
        string Value(string name)
        {
            var chat = Chat();
            if (name == ChatAgentSteps.Agent)
            {
                var id = Format.Text(chat, "backend");
                return Format.Text(Backend(id), "label", id);
            }
            var text = Format.Text(chat, name);
            return string.IsNullOrWhiteSpace(text) ? L10n.Text("windows.chatpage.default.21b111cb")
                : name == ChatAgentSteps.Model ? LocalChatModel.Title(text) : text;
        }
        List<(string Value, string Label)> Options(string name)
        {
            if (name == ChatAgentSteps.Agent)
            {
                var currentId = Format.Text(Chat(), "backend");
                return source.Backends().Where(item => item is not null
                        && (Format.Text(item, "id") != "sh" || currentId == "sh") && Installed(item))
                    .Select(item => (Format.Text(item, "id"), Format.Text(item, "label", Format.Text(item, "id"))))
                    .ToList();
            }
            var options = new List<(string, string)> { ("", L10n.Text("windows.chatpage.default.21b111cb")) };
            if (CurrentBackend()?[name + "s"] is JsonArray values)
            {
                foreach (var value in values)
                {
                    var text = value?.ToString() ?? "";
                    if (text.Length > 0) options.Add((text, name == ChatAgentSteps.Model ? LocalChatModel.Name(text) : text));
                }
            }
            var saved = Format.Text(Chat(), name);
            if (saved.Length > 0 && options.All(option => option.Item1 != saved)) options.Insert(1, (saved, saved));
            return options;
        }

        void Show(string name)
        {
            step = name;
            search.Text = "";
            Render();
            search.Focus(FocusState.Programmatic);
        }

        async Task Choose(string value)
        {
            if (source.Suppressed?.Invoke() == true || picking) return;
            picking = true;
            try
            {
                var answered = step;
                var current = answered == ChatAgentSteps.Agent ? Format.Text(Chat(), "backend") : Format.Text(Chat(), answered);
                if (value != current)
                {
                    var patch = new JsonObject { [answered] = value };
                    if (answered == ChatAgentSteps.Agent && Format.Text(Backend(value), "gateTier") == "bypassOnly") patch["autonomy"] = "bypass";
                    if (!await source.Update(patch)) return;
                    changed = true;
                    if (!flyoutOpen)
                    {
                        source.Repaint();
                        return;
                    }
                }
                if (!flyoutOpen) return;
                if (ChatAgentSteps.Next(Steps(), answered) is string next) Show(next);
                else flyout.Hide();
            }
            finally
            {
                picking = false;
            }
        }

        Button? signInButton = null;
        void Render()
        {
            var selectedBackend = CurrentBackend();
            if (signInButton is not null)
                signInButton.Visibility = selectedBackend is not null && source.SignIn is not null && Installed(selectedBackend) && AgentSignInDialog.Supported(selectedBackend)
                    ? Visibility.Visible : Visibility.Collapsed;
            var steps = Steps();
            step = ChatAgentSteps.Current(steps, step);
            var active = steps.ToList().IndexOf(step);

            strip.Children.Clear();
            strip.ColumnDefinitions.Clear();
            for (var index = 0; index < steps.Count; index++)
            {
                var name = steps[index];
                var selected = index == active;
                var answered = index < active;
                strip.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                var badge = new Border
                {
                    Width = 15, Height = 15, CornerRadius = new CornerRadius(7.5),
                    Background = selected || answered ? Theme.AccentBrush : Theme.BorderBrush,
                };
                if (answered)
                {
                    badge.Child = new FontIcon { Glyph = "\uE73E", FontSize = 9, Foreground = Theme.OnAccentBrush };
                }
                else
                {
                    var number = new TextBlock
                    {
                        Text = (index + 1).ToString(CultureInfo.InvariantCulture), FontSize = 9,
                        FontWeight = Microsoft.UI.Text.FontWeights.Bold,
                        HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
                    };
                    if (selected) number.Foreground = Theme.OnAccentBrush;
                    badge.Child = number;
                }
                var heading = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
                heading.Children.Add(badge);
                var title = new TextBlock
                {
                    Text = StepTitle(name).ToUpperInvariant(), FontSize = 10, CharacterSpacing = 60,
                    FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                    Opacity = selected ? 1 : 0.7, VerticalAlignment = VerticalAlignment.Center,
                };
                if (selected) title.Foreground = Theme.AccentBrush;
                heading.Children.Add(title);
                var lines = new StackPanel { Spacing = 1 };
                lines.Children.Add(heading);
                lines.Children.Add(new TextBlock
                {
                    Text = Value(name), TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap,
                    FontWeight = selected ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal,
                    Opacity = selected ? 1 : 0.75,
                });
                var tab = new Button
                {
                    Content = lines, MinHeight = 44,
                    HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left,
                    Background = selected ? Theme.AccentSoftBrush : Theme.ClearBrush,
                    BorderBrush = Theme.AccentBrush, BorderThickness = new Thickness(selected ? 1 : 0),
                    CornerRadius = new CornerRadius(7), Padding = new Thickness(8, 4, 8, 4),
                };
                AutomationProperties.SetName(tab, StepTitle(name) + ", " + Value(name));
                var target = name;
                tab.Click += (_, _) => { if (!picking) Show(target); };
                Grid.SetColumn(tab, index);
                strip.Children.Add(tab);
            }

            back.Visibility = ChatAgentSteps.Previous(steps, step) is null ? Visibility.Collapsed : Visibility.Visible;
            search.PlaceholderText = StepPrompt(step);

            choices.Children.Clear();
            var current = step == ChatAgentSteps.Agent ? Format.Text(Chat(), "backend") : Format.Text(Chat(), step);
            var query = search.Text;
            var matches = Options(step)
                .Where(item => string.IsNullOrWhiteSpace(query)
                    || query.Split(' ', StringSplitOptions.RemoveEmptyEntries).All(word => item.Label.Contains(word, StringComparison.OrdinalIgnoreCase)))
                .ToList();
            if (matches.Count == 0)
            {
                choices.Children.Add(new TextBlock
                {
                    Text = L10n.Text("windows.chatpage.nothing_matches.965b516d"), Opacity = 0.7,
                    Margin = new Thickness(8, 12, 8, 12), HorizontalAlignment = HorizontalAlignment.Center,
                });
                return;
            }
            foreach (var item in matches)
            {
                var text = new TextBlock { Text = item.Label, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
                if (item.Value == current) text.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
                FrameworkElement label = text;
                var ownLogin = profiles?.Owns(profileId, Format.Text(Backend(item.Value), "launcherId")) == true;
                if (step == ChatAgentSteps.Agent && !ownLogin && Readiness(Backend(item.Value)) is string note)
                {
                    var rows = new StackPanel { Spacing = 1 };
                    rows.Children.Add(text);
                    rows.Children.Add(new TextBlock { Text = note, FontSize = 11, Opacity = 0.7, TextTrimming = TextTrimming.CharacterEllipsis });
                    label = rows;
                }
                if (step == ChatAgentSteps.Model && item.Value.Length > 0)
                {
                    // Where the model runs, at a glance: the provider's
                    // cloud, or a server on the machine, with its name.
                    var local = LocalChatModel.Provider(item.Value);
                    var lines = new StackPanel { Spacing = 1, VerticalAlignment = VerticalAlignment.Center };
                    lines.Children.Add(label);
                    if (local is not null)
                    {
                        var place = L10n.Text("common.chat.local_model_host", local);
                        var tokens = (CurrentBackend()?["localModels"] as JsonArray)?.OfType<JsonObject>()
                            .FirstOrDefault(entry => Format.Text(entry, "id") == item.Value) is { } info
                            ? Format.Long(info, "contextLength") : 0;
                        if (tokens > 0 && tokens < LocalChatModel.RoomyContext)
                            place += " · " + L10n.Text("common.chat.local_model_small", $"{tokens / 1024}K");
                        lines.Children.Add(new TextBlock { Text = place, FontSize = 11, Opacity = 0.7 });
                    }
                    var mark = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
                    mark.Children.Add(new FontIcon
                    {
                        Glyph = local is null ? "\uE753" : "\uE7F8", // Cloud, Devices
                        FontSize = 13,
                        Width = 20,
                        Foreground = local is null ? Theme.Brush(static () => Theme.ControlGlyph) : Theme.Brush(static () => Theme.Accent),
                        VerticalAlignment = VerticalAlignment.Center,
                    });
                    mark.Children.Add(lines);
                    label = mark;
                }
                FrameworkElement content = step == ChatAgentSteps.Agent ? AgentMark.Row(item.Value, label) : label;
                if (step == ChatAgentSteps.Agent && QuotaLine(Readings(), item.Value, ownLogin ? profileId : null) is { } quota)
                {
                    var withQuota = new Grid { ColumnSpacing = Theme.SpaceS };
                    withQuota.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                    withQuota.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                    withQuota.Children.Add(content);
                    Grid.SetColumn(quota, 1); withQuota.Children.Add(quota);
                    content = withQuota;
                }
                var pick = new Button
                {
                    Content = content,
                    HorizontalAlignment = HorizontalAlignment.Stretch,
                    HorizontalContentAlignment = HorizontalAlignment.Stretch,
                    Background = item.Value == current ? Theme.AccentSoftBrush : Theme.PanelBrush,
                    BorderThickness = new Thickness(0), Padding = new Thickness(8), MinHeight = 44,
                };
                var value = item.Value;
                pick.Click += async (_, _) => await Choose(value);
                var rowBackend = step == ChatAgentSteps.Agent ? Backend(value) : null;
                if (rowBackend is not null && source.UpdateAgent is { } updateAgent
                    && Format.Flag(rowBackend, "updateAvailable") && Installed(rowBackend))
                {
                    var latest = Format.Text(rowBackend, "latestVersion");
                    var tip = latest.Length > 0
                        ? L10n.Text("common.agent_updates.update_to", Format.Text(rowBackend, "label", value), latest)
                        : L10n.Text("common.agent_updates.update");
                    var update = ActionIconGlyph.Button(L10n.Text("common.agent_updates.update"), ActionIcon.Download, (_, _) => { });
                    update.VerticalAlignment = VerticalAlignment.Center;
                    ToolTipService.SetToolTip(update, tip);
                    AutomationProperties.SetName(update, tip);
                    update.Click += async (_, _) =>
                    {
                        update.IsEnabled = false;
                        flyout.Hide();
                        await updateAgent(rowBackend);
                    };
                    var withUpdate = new Grid { ColumnSpacing = Theme.SpaceXs };
                    withUpdate.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                    withUpdate.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                    withUpdate.Children.Add(pick);
                    Grid.SetColumn(update, 1); withUpdate.Children.Add(update);
                    choices.Children.Add(withUpdate);
                    continue;
                }
                choices.Children.Add(pick);
            }
        }

        back.Click += (_, _) =>
        {
            if (!picking && ChatAgentSteps.Previous(Steps(), step) is string previous) Show(previous);
        };
        search.TextChanged += (_, _) => Render();
        // Enter takes the marked row on an empty field, so a keyboard walks all
        // the steps without changing anything, and the first match otherwise.
        search.KeyDown += async (_, e) =>
        {
            if (e.Key != VirtualKey.Enter) return;
            e.Handled = true;
            var query = search.Text;
            var current = step == ChatAgentSteps.Agent ? Format.Text(Chat(), "backend") : Format.Text(Chat(), step);
            var options = Options(step);
            var words = query.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            var matches = options
                .Where(option => words.All(word => option.Label.Contains(word, StringComparison.OrdinalIgnoreCase)))
                .ToList();
            if (matches.Count == 0) return;
            var exact = matches.FindIndex(option => option.Label.Equals(query.Trim(), StringComparison.OrdinalIgnoreCase));
            var marked = matches.FindIndex(option => option.Value == current);
            var chosen = words.Length == 0
                ? (marked >= 0 ? marked : 0)
                : (exact >= 0 ? exact : 0);
            await Choose(matches[chosen].Value);
        };
        Render();
        var signIn = ActionIconGlyph.Button(L10n.Text("windows.agentsetup.open_terminal"), ActionIcon.SignIn, async (_, _) =>
        {
            var current = CurrentBackend();
            flyout.Hide();
            if (source.SignIn is not null && current is not null && Installed(current) && AgentSignInDialog.Supported(current))
                await source.SignIn!(current);
        });
        signIn.IsEnabled = !locked;
        signInButton = signIn;
        panel.Children.Add(signIn);
        Render();
        flyout.Content = new Border { Background = Theme.PanelBrush, Child = panel };
        flyout.Opening += (_, _) =>
        {
            flyoutOpen = true;
            step = ChatAgentSteps.Agent;
            changed = false;
            search.Text = "";
            Render();
            if (!LimitsByHost.TryGetValue(host, out var entry) || DateTimeOffset.UtcNow - entry.Date >= TimeSpan.FromSeconds(30))
                _ = LoadLimitsAsync();
        };
        async Task LoadLimitsAsync()
        {
            try
            {
                var request = new JsonObject { ["force"] = false };
                var result = workspace is null
                    ? await AppServices.Host.CallAsync("usage.limits", request)
                    : await RemoteWorkspaces.CallWorkspaceAsync(workspace, "usage.limits", request);
                if (account == AppServices.AccountGeneration && result is JsonArray readings)
                {
                    LimitsByHost[host] = (readings, DateTimeOffset.UtcNow);
                    if (flyoutOpen && step == ChatAgentSteps.Agent) Render();
                }
            }
            catch { /* The rows simply carry no quota. */ }
        }
        flyout.Opened += (_, _) => search.Focus(FocusState.Programmatic);
        flyout.Closed += (_, _) =>
        {
            flyoutOpen = false;
            if (changed) source.Repaint();
        };

        var button = new Button
        {
            Content = field,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Flyout = flyout,
            IsEnabled = !locked,
            Background = Theme.PanelBrush,
            BorderBrush = Theme.BorderBrush,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(10, 6, 10, 6),
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, label);
        ToolTipService.SetToolTip(button, label);
        return button;
    }
}
