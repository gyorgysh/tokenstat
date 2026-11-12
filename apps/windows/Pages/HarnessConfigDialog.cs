// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Globalization;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;

namespace Tokenstat.Pages;

/// <summary>The tool's own settings and explicit installer, on its owning machine.</summary>
internal static class HarnessConfigDialog
{
    public static async Task<bool> ShowAsync(UIElement owner, JsonNode profile, string machine,
        Func<string, JsonNode?, TimeSpan?, Task<JsonNode>> call)
    {
        var id = Format.Text(profile, "id");
        var name = Format.Text(profile, "name", id);
        var state = new HarnessConfigState();
        var editors = new Dictionary<string, Func<string>>(StringComparer.Ordinal);
        var generation = 0;
        var fields = new StackPanel { Spacing = Theme.SpaceM };
        var notices = new StackPanel { Spacing = Theme.SpaceS };
        var installation = new StackPanel { Spacing = Theme.SpaceS };
        var versions = new StackPanel { Spacing = Theme.SpaceS };
        var path = new TextBlock { FontFamily = Fonts.Mono, FontSize = 11, IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap };
        var progress = new ProgressRing { Width = 20, Height = 20, IsActive = false, HorizontalAlignment = HorizontalAlignment.Left };
        var confirmPanel = new StackPanel { Spacing = Theme.SpaceS, Visibility = Visibility.Collapsed };
        var body = new StackPanel { Spacing = Theme.SpaceM, MinWidth = 430, MaxWidth = 600 };
        body.Children.Add(new TextBlock { Text = L10n.Text("windows.harnessconfig.subtitle"), TextWrapping = TextWrapping.Wrap, Opacity = 0.7 });
        body.Children.Add(new TextBlock { Text = Format.Text(profile, "command"), FontFamily = Fonts.Mono, FontSize = 11, IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap });
        body.Children.Add(path);
        body.Children.Add(notices);
        body.Children.Add(progress);
        body.Children.Add(fields);
        body.Children.Add(installation);
        var dialog = new ContentDialog
        {
            Title = L10n.Text("windows.harnessconfig.title", name),
            Content = new ScrollViewer { Content = body, MaxHeight = 520 },
            PrimaryButtonText = L10n.Text("common.save"), CloseButtonText = L10n.Text("common.cancel"),
            IsPrimaryButtonEnabled = false, DefaultButton = ContentDialogButton.Primary,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(dialog, "harness.config");
        var busy = false;
        var changedInstallation = false;
        Button? reinstall = null;
        TaskCompletionSource<bool>? confirmation = null;
        void UpdateButtons()
        {
            dialog.IsPrimaryButtonEnabled = !busy && state.Dirty;
            foreach (var control in fields.Children.OfType<StackPanel>().SelectMany(row => row.Children.OfType<Control>()))
                control.IsEnabled = !busy;
            if (reinstall is not null) reinstall.IsEnabled = !busy;
            foreach (var button in versions.Children.OfType<StackPanel>().SelectMany(row => row.Children.OfType<Button>()))
                button.IsEnabled = !busy;
            progress.IsActive = busy;
            progress.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        }
        void Notice(string text, bool success = false)
        {
            notices.Children.Clear();
            notices.Children.Add(Chrome.Banner(text, success ? Theme.Success : Theme.Danger, success ? Symbol.Accept : Symbol.Important));
        }
        void Set(string key, string value) { state.Values[key] = value; UpdateButtons(); }
        void CaptureEdits()
        {
            foreach (var editor in editors) state.Values[editor.Key] = editor.Value();
        }
        void RenderFields()
        {
            var renderedGeneration = ++generation;
            editors.Clear();
            fields.Children.Clear();
            path.Text = Format.Text(state.Config, "path");
            if (!Format.Flag(state.Config, "available") || !state.Fields.Any())
            {
                fields.Children.Add(new TextBlock { Text = Format.Text(state.Config, "reason", L10n.Text("windows.harnessconfig.no_settings")), TextWrapping = TextWrapping.Wrap });
                return;
            }
            foreach (var field in state.Fields)
            {
                var key = Format.Text(field, "key");
                void Change(string value)
                {
                    if (generation == renderedGeneration) Set(key, value);
                }
                var current = state.Values.GetValueOrDefault(key, "");
                var row = new StackPanel { Spacing = 6 };
                row.Children.Add(new TextBlock { Text = Format.Text(field, "label", key), FontSize = 12, Opacity = 0.7 });
                switch (Format.Text(field, "kind"))
                {
                    case "bool":
                        var toggle = new ToggleSwitch { IsOn = current == "true",
                            OnContent = L10n.Text("windows.harnessconfig.on"), OffContent = L10n.Text("windows.harnessconfig.off") };
                        string ToggleValue() => toggle.IsOn == (current == "true") ? current : toggle.IsOn ? "true" : "false";
                        toggle.Toggled += (_, _) => Change(ToggleValue());
                        editors[key] = ToggleValue;
                        row.Children.Add(toggle);
                        break;
                    case "choice":
                        var choices = (field["options"] as JsonArray ?? new JsonArray()).Select(value => value?.ToString() ?? "").ToList();
                        if (current.Length > 0 && !choices.Contains(current)) choices.Add(current);
                        var selection = new ComboBox { ItemsSource = choices, SelectedItem = current, HorizontalAlignment = HorizontalAlignment.Stretch };
                        selection.SelectionChanged += (_, _) => { if (selection.SelectedItem is string value) Change(value); };
                        editors[key] = () => selection.SelectedItem as string ?? current;
                        row.Children.Add(selection);
                        break;
                    case "number" when field["min"] is not null && field["max"] is not null:
                        var low = field["min"]!.GetValue<double>();
                        var high = field["max"]!.GetValue<double>();
                        var fallback = field["default"]?.GetValue<double>() ?? low;
                        var number = double.TryParse(current, NumberStyles.Float, CultureInfo.InvariantCulture, out var parsed) ? parsed : fallback;
                        var slider = new Slider { Minimum = low, Maximum = high, StepFrequency = Math.Max(1, field["step"]?.GetValue<double>() ?? 1), Value = Math.Clamp(number, low, high) };
                        var valueLabel = new TextBlock { Text = current.Length == 0 ? L10n.Text("windows.harnessconfig.default_value", fallback) : current, FontFamily = Fonts.Mono, FontSize = 11 };
                        var numberEdited = false;
                        var initialNumber = slider.Value;
                        slider.ValueChanged += (_, args) => {
                            if (!numberEdited && args.NewValue == initialNumber) return;
                            numberEdited = true; var value = Math.Round(args.NewValue).ToString(CultureInfo.InvariantCulture); valueLabel.Text = value; Change(value);
                        };
                        editors[key] = () => numberEdited ? Math.Round(slider.Value).ToString(CultureInfo.InvariantCulture) : current;
                        row.Children.Add(slider);
                        row.Children.Add(valueLabel);
                        break;
                    default:
                        var input = new TextBox { Text = current, HorizontalAlignment = HorizontalAlignment.Stretch };
                        input.TextChanged += (_, _) => Change(input.Text);
                        editors[key] = () => input.Text;
                        row.Children.Add(input);
                        break;
                }
                var hint = Format.Text(field, "hint");
                foreach (var control in row.Children.OfType<Control>())
                {
                    Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(control, "harness.field." + key);
                    Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(control, Format.Text(field, "label", key));
                }
                if (hint.Length > 0) row.Children.Add(new TextBlock { Text = hint, TextWrapping = TextWrapping.Wrap, FontSize = 11, Opacity = 0.6 });
                fields.Children.Add(row);
            }
        }
        async Task Reload(bool preserve = false)
        {
            state.Load(await call("harness.config.get", new JsonObject { ["id"] = id }, null), preserve);
            RenderFields();
        }
        async Task<bool> Confirm()
        {
            confirmation = new(TaskCreationOptions.RunContinuationsAsynchronously);
            confirmPanel.Visibility = Visibility.Visible;
            confirmPanel.DispatcherQueue.TryEnqueue(() => confirmPanel.StartBringIntoView());
            try { return await confirmation.Task; }
            finally { confirmPanel.Visibility = Visibility.Collapsed; confirmation = null; }
        }
        var command = Format.Text(profile, "installCommand");
        installation.Children.Add(versions);
        async Task ConfigureVersions(JsonNode protocol)
        {
            if (!Format.Flag(profile, "installed") || !AgentUpdates.Supported(protocol)) return;
            var row = await AgentUpdates.RowAsync(id, false, call);
            if (row is null) return;
            var checkedNow = false;
            var line = new TextBlock { TextWrapping = TextWrapping.Wrap, Opacity = 0.7 };
            var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
            var check = ActionIconGlyph.Button(L10n.Text("common.agent_updates.check"), ActionIcon.Refresh, (_, _) => { });
            var update = ActionIconGlyph.Button(L10n.Text("common.agent_updates.update"), ActionIcon.Download, (_, _) => { });
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(check, "harness.updates.check");
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(update, "harness.update");
            void Show()
            {
                line.Text = AgentUpdates.Describe(row, checkedNow);
                update.Visibility = AgentUpdates.Offers(row, checkedNow) ? Visibility.Visible : Visibility.Collapsed;
                update.IsEnabled = !busy && !Format.Flag(row, "busy");
                check.IsEnabled = !busy;
                if (Format.Flag(row, "busy")) ToolTipService.SetToolTip(update, L10n.Text("common.agent_updates.busy"));
            }
            check.Click += async (_, _) =>
            {
                if (busy) return;
                busy = true; notices.Children.Clear(); UpdateButtons(); Show();
                try { row = await AgentUpdates.RowAsync(id, true, call) ?? row; checkedNow = true; }
                catch (Exception ex) { Notice(ex.Message); }
                finally { busy = false; UpdateButtons(); Show(); }
            };
            update.Click += async (_, _) =>
            {
                if (busy) return;
                CaptureEdits();
                busy = true; notices.Children.Clear(); UpdateButtons(); Show();
                try
                {
                    var result = await call("launcher.update", new JsonObject { ["id"] = id }, LauncherInstaller.Patience);
                    if (!Format.Flag(result, "ok"))
                        throw new InvalidOperationException(L10n.Text("common.agent_updates.failed", Format.Text(result, "output").Trim()));
                    changedInstallation = true;
                    var after = Format.Text(result, "after");
                    Notice(after.Length > 0 ? L10n.Text("common.agent_updates.updated", after) : L10n.Text("common.agent_updates.updated_unknown"), true);
                    row = await AgentUpdates.RowAsync(id, false, call) ?? row;
                    checkedNow = false;
                    await Reload(true);
                }
                catch (Exception ex) { Notice(ex.Message); }
                finally { busy = false; UpdateButtons(); Show(); }
            };
            buttons.Children.Add(check);
            buttons.Children.Add(update);
            versions.Children.Add(new TextBlock { Text = L10n.Text("common.agent_updates.title"), FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
            versions.Children.Add(line);
            versions.Children.Add(buttons);
            Show();
        }
        async Task ConfigureInstallation()
        {
            if (!Format.Flag(profile, "installed")) return;
            JsonNode protocol;
            try { protocol = await call("protocol", null, null); }
            catch { return; }
            try { await ConfigureVersions(protocol); }
            catch (Exception ex) { Notice(ex.Message); }
            if (command.Length == 0 || !LauncherInstaller.SupportsReinstall(protocol)) return;
            installation.Children.Add(new Microsoft.UI.Xaml.Shapes.Rectangle { Height = 1, Fill = Theme.BorderBrush });
            installation.Children.Add(new TextBlock { Text = L10n.Text("windows.harnessconfig.installation"), FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
            installation.Children.Add(new TextBlock { Text = L10n.Text("windows.harnessconfig.reinstall_hint"), TextWrapping = TextWrapping.Wrap, Opacity = 0.7 });
            installation.Children.Add(new TextBlock { Text = command, FontFamily = Fonts.Mono, FontSize = 11, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
            reinstall = ActionIconGlyph.Button(L10n.Text("windows.workspacepage.reinstall.c630a782"), ActionIcon.Refresh, (_, _) => { });
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(reinstall, "harness.reinstall");
            reinstall.Click += async (_, _) =>
            {
                if (busy) return;
                CaptureEdits();
                busy = true; notices.Children.Clear(); UpdateButtons();
                try
                {
                    if (await LauncherInstaller.RunAsync(machine, id, true, call, Confirm))
                    {
                        changedInstallation = true;
                        await Reload(true);
                        Notice(L10n.Text("windows.harnessconfig.reinstall_complete"), true);
                    }
                }
                catch (Exception ex) { Notice(ex.Message); }
                finally { busy = false; UpdateButtons(); }
            };
            installation.Children.Add(reinstall);
            confirmPanel.Children.Add(new TextBlock { Text = L10n.Text("windows.harnessconfig.reinstall_confirmation"), TextWrapping = TextWrapping.Wrap });
            var confirmButtons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
            var confirmReinstall = ActionIconGlyph.Button(L10n.Text("windows.workspacepage.reinstall.c630a782"), ActionIcon.Refresh, (_, _) => confirmation?.TrySetResult(true));
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(confirmReinstall, "harness.reinstall.confirm");
            confirmButtons.Children.Add(confirmReinstall);
            confirmButtons.Children.Add(ActionIconGlyph.Button(L10n.Text("common.cancel"), ActionIcon.Dismiss, (_, _) => confirmation?.TrySetResult(false)));
            confirmPanel.Children.Add(confirmButtons);
            installation.Children.Add(confirmPanel);
        }
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            if (busy) return;
            CaptureEdits();
            if (!state.Dirty) return;
            busy = true; notices.Children.Clear(); UpdateButtons();
            var deferral = args.GetDeferral();
            try
            {
                state.Load(await call("harness.config.set", new JsonObject { ["id"] = id, ["values"] = state.Changes }, null));
                args.Cancel = false;
            }
            catch (Exception ex) { Notice(ex.Message); }
            finally { busy = false; UpdateButtons(); deferral.Complete(); }
        };
        dialog.CloseButtonClick += (_, args) => { args.Cancel = busy; };
        dialog.Closed += (_, _) => confirmation?.TrySetResult(false);
        dialog.Opened += async (_, _) =>
        {
            busy = true; UpdateButtons();
            try { await Reload(); }
            catch (Exception ex) { Notice(ex.Message); }
            try { await ConfigureInstallation(); }
            catch (Exception ex) { Notice(ex.Message); }
            busy = false; UpdateButtons();
        };
        await Chrome.ShowDialog(owner, dialog);
        return changedInstallation;
    }
}
