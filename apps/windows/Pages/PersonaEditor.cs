// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Tokenstat.Navigation;

namespace Tokenstat.Pages;

internal static class PersonaEditor
{
    internal static async Task<bool> ShowAsync(UIElement owner, string workspace, JsonArray backends,
        Func<string, JsonNode?, TimeSpan?, Task<JsonNode>> call, Func<bool> current)
    {
        var listing = await call("chat.personas", new JsonObject { ["workspaceId"] = workspace }, null);
        if (!current()) return false;
        var personas = (Format.Items(listing, "personas") ?? new JsonArray()).OfType<JsonObject>()
            .Where(persona => Format.Text(persona, "id").Length > 0).ToList();
        var defaultId = listing is JsonObject ? Format.Text(listing, "defaultId") : "";
        var target = RemoteWorkspaces.TrySplit(workspace, out _, out var inner) ? inner : workspace;
        var agents = backends.OfType<JsonObject>().Where(backend =>
            Format.Text(backend, "id") is not ("" or "sh") && backend["installed"]?.ToString() != "false").ToArray();
        var selected = new ComboBox { Header = L10n.Text("windows.personaeditor.persona"), HorizontalAlignment = HorizontalAlignment.Stretch };
        var name = new TextBox { Header = L10n.Text("windows.personaeditor.name") };
        var prompt = new TextBox
        {
            Header = L10n.Text("windows.personaeditor.instructions"), AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap, MinHeight = 104, MaxHeight = 210,
        };
        var everyProject = new CheckBox { Content = L10n.Text("windows.personaeditor.every_project") };
        var agent = new ComboBox
        {
            Header = L10n.Text("windows.personaeditor.drafting_agent"),
            ItemsSource = agents.Select(backend => Format.Text(backend, "label", Format.Text(backend, "id"))).ToArray(),
            SelectedIndex = agents.Length > 0 ? 0 : -1,
            Visibility = agents.Length > 0 ? Visibility.Visible : Visibility.Collapsed,
        };
        var improve = new Button { Content = L10n.Text("windows.personaeditor.improve"), Visibility = agent.Visibility };
        var makeDefault = new Button();
        var delete = new Button { Content = L10n.Text("common.delete") };
        var confirmDelete = new Button { Content = L10n.Text("windows.personaeditor.confirm_delete") };
        var cancelDelete = new Button { Content = L10n.Text("common.cancel") };
        var confirmation = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS, Visibility = Visibility.Collapsed,
            Children = { confirmDelete, cancelDelete } };
        var notice = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var body = new StackPanel
        {
            Spacing = Theme.SpaceS,
            Children =
            {
                selected, name, prompt, everyProject,
                new FlowPanel { Spacing = Theme.SpaceS, Children = { agent, improve } },
                new FlowPanel { Spacing = Theme.SpaceS, Children = { makeDefault, delete } },
                confirmation, notice,
            },
        };
        var dialog = new ContentDialog
        {
            Title = L10n.Text("windows.personaeditor.title"),
            Content = new ScrollViewer { Content = body, MaxHeight = 540 },
            PrimaryButtonText = L10n.Text("common.save"),
            CloseButtonText = L10n.Text("common.close"),
        };
        bool working = false, rendered = false, closed = false, changed = false;
        JsonObject? Choice() => selected.SelectedIndex > 0 && selected.SelectedIndex <= personas.Count
            ? personas[selected.SelectedIndex - 1] : null;
        void UpdateActions()
        {
            var id = Format.Text(Choice(), "id");
            selected.IsEnabled = name.IsEnabled = prompt.IsEnabled = everyProject.IsEnabled = agent.IsEnabled = !working;
            dialog.IsPrimaryButtonEnabled = !working && !string.IsNullOrWhiteSpace(name.Text);
            improve.IsEnabled = !working && agent.SelectedIndex >= 0 && !string.IsNullOrWhiteSpace(prompt.Text);
            makeDefault.Content = id == defaultId && id.Length > 0
                ? L10n.Text("windows.personaeditor.clear_default") : L10n.Text("windows.personaeditor.set_default");
            makeDefault.IsEnabled = !working && id.Length > 0;
            delete.IsEnabled = confirmDelete.IsEnabled = !working && id.Length > 0 && id != defaultId;
        }
        void PresentChoice()
        {
            var persona = Choice();
            name.Text = Format.Text(persona, "name");
            prompt.Text = Format.Text(persona, "systemPrompt");
            everyProject.IsChecked = persona is not null && Format.Text(persona, "workspaceId").Length == 0;
            confirmation.Visibility = Visibility.Collapsed;
            UpdateActions();
        }
        void SetChoices(string id)
        {
            rendered = false;
            selected.ItemsSource = new[] { L10n.Text("windows.personaeditor.new") }.Concat(personas.Select(persona => Format.Text(persona, "name"))).ToArray();
            selected.SelectedIndex = personas.FindIndex(persona => Format.Text(persona, "id") == id) + 1;
            rendered = true;
            PresentChoice();
        }
        async Task RunAsync(string status, Func<Task> action)
        {
            if (working || closed || !current()) return;
            working = true;
            notice.Foreground = Theme.Brush(static () => Theme.ControlGlyph);
            notice.Text = status;
            UpdateActions();
            try { await action(); }
            catch (Exception error)
            {
                if (!closed && current())
                {
                    notice.Foreground = Theme.Brush(static () => Theme.Danger);
                    notice.Text = FriendlyError.Display(error.Message);
                }
            }
            finally
            {
                working = false;
                if (!closed && current()) UpdateActions();
            }
        }
        dialog.Closed += (_, _) => closed = true;
        selected.SelectionChanged += (_, _) =>
        {
            if (!rendered) return;
            notice.Text = "";
            PresentChoice();
        };
        name.TextChanged += (_, _) => UpdateActions();
        prompt.TextChanged += (_, _) => UpdateActions();
        agent.SelectionChanged += (_, _) => UpdateActions();
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            await RunAsync(L10n.Text("windows.personaeditor.saving"), async () =>
            {
                var data = Choice()?.DeepClone() as JsonObject ?? new JsonObject { ["id"] = "" };
                data["name"] = name.Text.Trim();
                if (Format.Text(data, "name").Length == 0) return;
                data["systemPrompt"] = prompt.Text;
                data["workspaceId"] = everyProject.IsChecked == true ? null : target;
                var response = await call("chat.personaSave", new JsonObject { ["workspaceId"] = workspace, ["persona"] = data }, null);
                if (response is not JsonObject saved || Format.Text(saved, "id") is not { Length: > 0 } id)
                    throw new InvalidDataException(L10n.Text("windows.personaeditor.unconfirmed"));
                changed = true;
                if (closed || !current()) return;
                var at = personas.FindIndex(persona => Format.Text(persona, "id") == id);
                if (at >= 0) personas[at] = saved;
                else personas.Add(saved);
                SetChoices(id);
                notice.Text = L10n.Text("windows.personaeditor.saved");
            });
        };
        improve.Click += async (_, _) => await RunAsync(L10n.Text("windows.personaeditor.drafting"), async () =>
        {
            if (agent.SelectedIndex < 0 || string.IsNullOrWhiteSpace(prompt.Text)) return;
            var data = new JsonObject { ["backend"] = Format.Text(agents[agent.SelectedIndex], "id"), ["text"] = prompt.Text.Trim() };
            if (!string.IsNullOrWhiteSpace(name.Text)) data["name"] = name.Text.Trim();
            var result = await call("chat.personaDraft", data, TimeSpan.FromMinutes(3));
            if (closed || !current()) return;
            var revised = Format.Text(result, "systemPrompt");
            if (revised.Length == 0) throw new InvalidDataException(L10n.Text("windows.personaeditor.unconfirmed"));
            if (string.IsNullOrWhiteSpace(name.Text)) name.Text = Format.Text(result, "name");
            prompt.Text = revised;
            notice.Text = L10n.Text("windows.personaeditor.review_draft");
        });
        makeDefault.Click += async (_, _) => await RunAsync(L10n.Text("windows.personaeditor.saving"), async () =>
        {
            var id = Format.Text(Choice(), "id");
            if (id.Length == 0) return;
            var next = defaultId == id ? "" : id;
            await call("chat.personaDefault", new JsonObject { ["workspaceId"] = workspace, ["personaId"] = next }, null);
            changed = true;
            if (closed || !current()) return;
            defaultId = next;
            notice.Text = L10n.Text("windows.personaeditor.default_updated");
        });
        delete.Click += (_, _) =>
        {
            confirmation.Visibility = Visibility.Visible;
            notice.Text = L10n.Text("windows.personaeditor.delete_confirmation");
        };
        cancelDelete.Click += (_, _) => { confirmation.Visibility = Visibility.Collapsed; notice.Text = ""; };
        confirmDelete.Click += async (_, _) => await RunAsync(L10n.Text("windows.personaeditor.deleting"), async () =>
        {
            var id = Format.Text(Choice(), "id");
            if (id.Length == 0 || id == defaultId) return;
            var response = await call("chat.personaRemove", new JsonObject { ["id"] = id }, null);
            if (!Format.Flag(response, "removed")) throw new InvalidDataException(L10n.Text("windows.personaeditor.unconfirmed"));
            changed = true;
            if (closed || !current()) return;
            personas.RemoveAll(persona => Format.Text(persona, "id") == id);
            SetChoices("");
            notice.Text = L10n.Text("windows.personaeditor.deleted");
        });
        dialog.Closing += (_, args) => args.Cancel = working && current();
        SetChoices(defaultId.Length > 0 ? defaultId : Format.Text(personas.FirstOrDefault(), "id"));
        await Chrome.ShowDialog(owner, dialog);
        return changed;
    }
}
