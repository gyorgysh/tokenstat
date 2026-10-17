// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Tokenstat.Design;
using Tokenstat.Pages;

namespace NativeUiTests;

internal static class HarnessConfigSmoke
{
    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        yield return root;
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++)
            foreach (var child in Descendants(VisualTreeHelper.GetChild(root, index))) yield return child;
    }
    private static T? Find<T>(DependencyObject root, string id) where T : FrameworkElement =>
        Descendants(root).OfType<T>().FirstOrDefault(element => AutomationProperties.GetAutomationId(element) == id);
    private static ContentDialog? OpenDialog(FrameworkElement host) => VisualTreeHelper.GetOpenPopupsForXamlRoot(host.XamlRoot)
        .SelectMany(popup => popup.Child is null ? Enumerable.Empty<DependencyObject>() : Descendants(popup.Child))
        .OfType<ContentDialog>().FirstOrDefault(dialog => AutomationProperties.GetAutomationId(dialog) == "harness.config");
    private static async Task Until(FrameworkElement host, Func<bool> ready, string failure)
    {
        for (var attempt = 0; attempt < 500; attempt++)
        {
            host.UpdateLayout();
            if (ready()) return;
            await Task.Delay(20);
        }
        throw new Exception(failure);
    }
    private static JsonNode Config() => JsonNode.Parse("""
        {"available":true,"path":"fixture/settings.json","fields":[
          {"key":"model","label":"Model","kind":"text","value":"original"},
          {"key":"effort","label":"Effort","kind":"choice","options":["low","high"],"value":"low"},
          {"key":"thinking","label":"Always thinking","kind":"bool","value":"false"},
          {"key":"compact","label":"Auto compact","kind":"number","min":0,"max":100,"step":1,"default":30,"value":null},
          {"key":"defaultFlag","label":"Default toggle","kind":"bool","value":null},
          {"key":"defaultNumber","label":"Default number","kind":"number","min":0,"max":100,"default":30,"value":null}]}
        """)!;

    internal static async Task Run(StackPanel host)
    {
        var profile = JsonNode.Parse("""{"id":"fixture-tool","name":"Fixture tool","installed":true,"command":"fixture-tool","installCommand":"fixture official installer"}""")!;
        var installs = 0;
        var reads = 0;
        var version = 37;
        JsonNode? saved = null;
        var completion = new TaskCompletionSource<JsonNode>(TaskCreationOptions.RunContinuationsAsynchronously);
        Task<JsonNode> Call(string method, JsonNode? parameters, TimeSpan? patience)
        {
            if (method == "protocol") return Task.FromResult<JsonNode>(new JsonObject { ["protocolVersion"] = version });
            if (method == "harness.config.get")
            {
                reads++;
                var config = Config();
                if (reads > 1) config["fields"]![0]!["value"] = "installer default";
                return Task.FromResult(config);
            }
            if (method == "launcher.reinstall")
            {
                if (patience != LauncherInstaller.Patience) throw new Exception("Reinstall lost its full deadline");
                installs++;
                return completion.Task;
            }
            if (method == "harness.config.set")
            {
                saved = parameters?.DeepClone();
                var config = Config();
                foreach (var field in config["fields"]!.AsArray())
                    if (parameters?["values"]?[field!["key"]!.GetValue<string>()] is { } value) field["value"] = value.DeepClone();
                return Task.FromResult(config);
            }
            throw new Exception("Unexpected harness call: " + method);
        }
        var showing = HarnessConfigDialog.ShowAsync(host, profile, "native-ui-fixture", Call);
        ContentDialog? dialog = null;
        try
        {
            await Until(host, () => (dialog = OpenDialog(host)) is not null && Find<TextBox>(dialog, "harness.field.model") is not null
                && Find<Button>(dialog, "harness.reinstall") is not null, "Configurator did not render settings and Reinstall");
            var model = Find<TextBox>(dialog!, "harness.field.model")!;
            if (AutomationProperties.GetName(model) != "Model") throw new Exception("The model field lost its accessible label");
            model.Text = "unsaved model";
            Find<ComboBox>(dialog!, "harness.field.effort")!.SelectedItem = "high";
            Find<ToggleSwitch>(dialog!, "harness.field.thinking")!.IsOn = true;
            Find<Slider>(dialog!, "harness.field.compact")!.Value = 80;
            if (!dialog!.IsPrimaryButtonEnabled || saved is not null) throw new Exception("Editing settings wrote before Save or did not enable Save");
            ContextMenus.Invoke(Find<Button>(dialog, "harness.reinstall")!);
            await Until(host, () => Find<Button>(dialog, "harness.reinstall.confirm")?.ActualHeight > 0, "Explicit reinstall confirmation did not appear");
            if (installs != 0) throw new Exception("Reinstall ran before confirmation");
            ContextMenus.Invoke(Find<Button>(dialog, "harness.reinstall.confirm")!);
            await Until(host, () => installs == 1, "Confirmation did not start the installer");
            if (dialog.IsPrimaryButtonEnabled || model.IsEnabled || Find<Button>(dialog, "harness.reinstall")!.IsEnabled)
                throw new Exception("Settings and duplicate actions stayed enabled during reinstallation");
            completion.SetResult(new JsonObject { ["ok"] = true });
            await Until(host, () => reads == 2 && dialog.IsPrimaryButtonEnabled, "Installer completion did not reload the configuration");
            if (Find<TextBox>(dialog, "harness.field.model")!.Text != "unsaved model" || saved is not null)
                throw new Exception("Reinstall discarded or saved pending edits");
            // Detached TextBoxes can still deliver a deferred TextChanged.
            model.Text = "detached editor";
            await Task.Delay(20);
            if (Find<TextBox>(dialog, "harness.field.model")!.Text != "unsaved model")
                throw new Exception("A detached editor changed the reloaded draft");
            var save = Descendants(dialog).OfType<Button>().FirstOrDefault(button => button.Name == "PrimaryButton")
                ?? throw new Exception("Native Save button was not mounted");
            ContextMenus.Invoke(save);
            await Until(host, () => showing.IsCompleted, "Save did not close the configurator");
            if (!await showing || saved?["values"]?["model"]?.GetValue<string>() != "unsaved model"
                || saved?["values"]?["effort"]?.GetValue<string>() != "high"
                || saved?["values"]?["thinking"]?.GetValue<string>() != "true"
                || saved?["values"]?["compact"]?.GetValue<string>() != "80"
                || saved?["values"]?.AsObject().Count != 4)
                throw new Exception("Save did not submit the changed tool settings");
            Program.Log("PASS: native harness settings edit/save and confirmed reinstall preserve drafts and disable busy actions");
        }
        finally { completion.TrySetResult(new JsonObject { ["ok"] = false }); dialog?.Hide(); }

        version = 36;
        reads = 0;
        showing = HarnessConfigDialog.ShowAsync(host, profile, "native-ui-old-host", Call);
        dialog = null;
        try
        {
            await Until(host, () => (dialog = OpenDialog(host)) is not null && Find<TextBox>(dialog, "harness.field.model") is { IsEnabled: true }, "Old-host settings did not remain editable");
            if (Find<Button>(dialog!, "harness.reinstall") is not null) throw new Exception("An older host received a Reinstall control");
            dialog!.Hide();
            if (await showing) throw new Exception("Dismissing settings reported an installation");
            Program.Log("PASS: native harness configuration hides Reinstall on pre-37 hosts");
        }
        finally { dialog?.Hide(); }
    }
}
