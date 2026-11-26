// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Tokenstat.Navigation;

namespace Tokenstat.Pages;

/// <summary>
/// Which agent profile and which local model the tools launched in a project
/// use, per project, like the Mac's terminal bar. Until somebody picks a
/// profile, a launch follows the default for new chats, so a terminal and a
/// chat in one project sign in the same way. A repository locked to a profile
/// always launches on it. A plain file beside the bypass setting, for the
/// same reason: this app is unpackaged.
/// </summary>
internal static class WorkspaceLaunchChoices
{
    private static readonly object Gate = new();

    /// The tools the host can point at a local model server. The host decides
    /// what the pick turns into and refuses a pair it has no contract for.
    private static readonly string[] LocalModelTools = ["claude_code", "codex", "opencode", "opencode2", "copilot"];

    private static string FilePath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "tokenstat",
        "workspace-launch.json");

    internal static string? Profile(string workspaceId) => Get(workspaceId, "profile");
    internal static string? LocalModel(string workspaceId) => Get(workspaceId, "localModel");

    /// <summary>Adds the remembered profile and local model to a launch.</summary>
    internal static async Task AddToAsync(JsonObject spawn, string workspaceId, string launcherId)
    {
        try
        {
            if (await AgentProfiles.ReadAsync(workspaceId) is { } profiles && profiles.Lock(workspaceId) is null)
            {
                var id = SelectedProfile(workspaceId, profiles);
                if (id != AgentProfiles.SystemId) spawn["profileId"] = id;
            }
        }
        catch
        {
            // A host that cannot list profiles launches on its own logins.
        }
        if (LocalModelTools.Contains(launcherId) && LocalModel(workspaceId) is { } key
            && key.IndexOf(':') is > 0 and var at && at < key.Length - 1)
        {
            spawn["modelProvider"] = key[..at];
            spawn["modelId"] = key[(at + 1)..];
        }
    }

    /// <summary>The profile menu for the project's bar. Empty until there is
    /// a profile other than the computer's own.</summary>
    internal static DropDownButton ProfileControl(string workspaceId, Action changed)
    {
        var button = Menu("", "workspace.launchProfile"); // Contact
        _ = FillProfilesAsync(button, workspaceId, changed);
        return button;
    }

    /// <summary>The local model menu for the project's bar. Shown once the
    /// host has LM Studio or Ollama serving a model.</summary>
    internal static DropDownButton ModelControl(string workspaceId, Action changed)
    {
        var button = Menu("", "workspace.launchModel"); // Devices
        _ = FillModelsAsync(button, workspaceId, changed);
        return button;
    }

    private static string SelectedProfile(string workspaceId, AgentProfiles profiles)
    {
        if (profiles.Lock(workspaceId) is { } locked) return locked;
        var id = Profile(workspaceId) ?? profiles.DefaultId;
        // The launch and its label agree when a remembered profile was removed.
        return profiles.Find(id) is not null ? id : AgentProfiles.SystemId;
    }

    private static async Task FillProfilesAsync(DropDownButton button, string workspaceId, Action changed)
    {
        AgentProfiles? profiles;
        try { profiles = await AgentProfiles.ReadAsync(workspaceId); }
        catch { return; }
        if (profiles is null || profiles.Choices.Length < 2) return;
        var locked = profiles.Lock(workspaceId);
        var current = SelectedProfile(workspaceId, profiles);
        SetLabel(button, locked is null ? "" : "", profiles.Title(current), current != AgentProfiles.SystemId);
        var flyout = new MenuFlyout();
        foreach (var choice in profiles.Choices)
        {
            var id = Format.Text(choice, "id");
            var item = new ToggleMenuFlyoutItem
            {
                Text = profiles.Title(id),
                IsChecked = id == current,
                IsEnabled = locked is null || locked == id,
            };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(item, "workspace.launchProfile.option." + id);
            item.Click += (_, _) => { Set(workspaceId, "profile", id); changed(); };
            flyout.Items.Add(item);
        }
        if (locked is not null)
        {
            flyout.Items.Add(new MenuFlyoutSeparator());
            flyout.Items.Add(new MenuFlyoutItem { Text = L10n.Text("common.profiles.locked", profiles.Title(locked)), IsEnabled = false });
        }
        button.Flyout = flyout;
        ToolTipService.SetToolTip(button, L10n.Text("common.profiles.launch_help"));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, L10n.Text("common.profiles.label"));
        button.Visibility = Visibility.Visible;
    }

    private static async Task FillModelsAsync(DropDownButton button, string workspaceId, Action changed)
    {
        JsonNode servers;
        try { servers = await RemoteWorkspaces.CallWorkspaceAsync(workspaceId, "local.models", new JsonObject()); }
        catch { return; }
        var choices = (servers as JsonArray ?? []).OfType<JsonObject>()
            .Where(server => server["available"]?.GetValue<bool>() == true)
            .SelectMany(server => (server["models"] as JsonArray ?? []).OfType<JsonObject>().Select(model => (
                Key: $"{Format.Text(server, "id")}:{Format.Text(model, "id")}",
                Label: $"{Format.Text(server, "name")}: {Format.Text(model, "name", Format.Text(model, "id"))}")))
            .ToList();
        var selected = LocalModel(workspaceId);
        if (choices.Count == 0 && selected is null) return;
        var defaultLabel = L10n.Text("common.launch.each_tool_default");
        var current = choices.FirstOrDefault(choice => choice.Key == selected).Label
            ?? (selected is null ? defaultLabel : selected[(selected.IndexOf(':') + 1)..]);
        SetLabel(button, selected is null ? "" : "", current, selected is not null); // Cloud, Devices
        var flyout = new MenuFlyout();
        var standard = new ToggleMenuFlyoutItem { Text = defaultLabel, IsChecked = selected is null };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(standard, "workspace.launchModel.default");
        standard.Click += (_, _) => { Set(workspaceId, "localModel", null); changed(); };
        flyout.Items.Add(standard);
        if (choices.Count > 0) flyout.Items.Add(new MenuFlyoutSeparator());
        foreach (var choice in choices)
        {
            var item = new ToggleMenuFlyoutItem { Text = choice.Label, IsChecked = choice.Key == selected };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(item, "workspace.launchModel.option." + choice.Key);
            item.Click += (_, _) => { Set(workspaceId, "localModel", choice.Key); changed(); };
            flyout.Items.Add(item);
        }
        button.Flyout = flyout;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, L10n.Text("common.launch.model", current));
        button.Visibility = Visibility.Visible;
    }

    private static DropDownButton Menu(string glyph, string automationId)
    {
        var button = new DropDownButton
        {
            Background = Theme.ClearBrush,
            BorderThickness = new Thickness(0),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(8, 0, 8, 0),
            Height = 30,
            MinHeight = 0,
            MinWidth = 0,
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = Visibility.Collapsed,
        };
        SetLabel(button, glyph, "", false);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(button, automationId);
        return button;
    }

    private static void SetLabel(DropDownButton button, string glyph, string text, bool accent)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
        row.Children.Add(new FontIcon { Glyph = glyph, FontSize = 12 });
        row.Children.Add(new TextBlock { Text = text, FontSize = 12, MaxWidth = 180, TextTrimming = TextTrimming.CharacterEllipsis });
        button.Content = row;
        button.Foreground = accent ? Theme.Brush(static () => Theme.Accent) : Theme.Brush(static () => Theme.ControlGlyph);
    }

    private static string? Get(string workspaceId, string field)
    {
        lock (Gate)
        {
            return Read()[workspaceId]?[field] is JsonValue value && value.TryGetValue<string>(out var text)
                && text.Length > 0 ? text : null;
        }
    }

    private static void Set(string workspaceId, string field, string? value)
    {
        lock (Gate)
        {
            var all = Read();
            if (all[workspaceId] is not JsonObject entry)
            {
                // A node can only have one parent, so attach a new one once.
                entry = new JsonObject();
                all[workspaceId] = entry;
            }
            if (value is null) entry.Remove(field);
            else entry[field] = value;
            if (entry.Count == 0) all.Remove(workspaceId);
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
                File.WriteAllText(FilePath, all.ToJsonString());
            }
            catch
            {
                // Not remembered: the next launch uses the default profile and
                // each tool's own model, which is what it did before a pick.
            }
        }
    }

    private static JsonObject Read()
    {
        try
        {
            return File.Exists(FilePath) && JsonNode.Parse(File.ReadAllText(FilePath)) is JsonObject all
                ? all
                : new JsonObject();
        }
        catch
        {
            return new JsonObject();
        }
    }
}
