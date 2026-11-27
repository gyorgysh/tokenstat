// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Tokenstat.Navigation;

namespace Tokenstat.Pages;

internal sealed class AgentProfiles(JsonNode value)
{
    internal const string SystemId = "system";
    internal const int MinimumProtocol = 57;
    internal JsonObject[] Choices { get; } = (value["profiles"] as JsonArray ?? []).OfType<JsonObject>().ToArray();
    internal string DefaultId => Format.Text(value, "default", SystemId);
    internal string[] Agents => (value["agents"] as JsonArray ?? []).Select(item => item?.ToString() ?? "").ToArray();

    internal JsonObject? Find(string id) => Choices.FirstOrDefault(p => Format.Text(p, "id") == id);
    internal string Title(string id)
    {
        var profile = Find(id);
        if (id != SystemId) return profile is null ? L10n.Text("common.profiles.removed") : Format.Text(profile, "name");
        return L10n.Text("common.profiles.main");
    }
    internal string? Lock(string? workspace) => workspace is null
        ? null : value["workspaceLocks"]?[workspace]?.ToString();
    internal bool Owns(string id, string agent) => (Find(id)?["own"] as JsonArray)?.Any(item => item?.ToString() == agent) == true;

    internal static async Task<AgentProfiles?> ReadAsync(string workspace)
    {
        if (RemoteWorkspaces.TrySplit(workspace, out var peer, out _) &&
            !RemoteFeatureGate.SupportsProtocol(await RemoteFeatureGate.PeerProtocolAsync(peer), MinimumProtocol))
            return null;
        var profiles = await RemoteWorkspaces.CallWorkspaceAsync(workspace, "profiles.list", new JsonObject());
        return new AgentProfiles(profiles);
    }

    internal FrameworkElement? Picker(string selected, string? locked, bool enabled, Func<string, Task> onChoose, Func<Task>? onManaged = null)
    {
        // Shown with only Main too: the menu is where somebody finds out that
        // profiles exist.
        if (locked == selected)
        {
            var label = new TextBlock { Text = L10n.Text("common.profiles.locked", Title(selected)), TextWrapping = TextWrapping.Wrap };
            AutomationProperties.SetAutomationId(label, "agentProfiles.locked");
            return label;
        }
        var menu = new MenuFlyout();
        menu.Items.Add(new MenuFlyoutItem { Text = L10n.Text("common.profiles.explain"), IsEnabled = false });
        foreach (var profile in Choices)
        {
            var id = Format.Text(profile, "id");
            if (locked is not null && id != locked) continue;
            var item = new MenuFlyoutItem { Text = Title(id), IsEnabled = id != selected };
            if (id == selected) item.Icon = new FontIcon { Glyph = "\uE73E" }; // CheckMark
            AutomationProperties.SetAutomationId(item, "agentProfiles.option." + id);
            item.Click += async (_, _) => await onChoose(id);
            menu.Items.Add(item);
        }
        Button? picker = null;
        if (locked is null)
        {
            menu.Items.Add(new MenuFlyoutSeparator());
            var add = new MenuFlyoutItem { Text = L10n.Text("common.profiles.add_ellipsis"), Icon = new FontIcon { Glyph = "\uE710" } }; // Add
            AutomationProperties.SetAutomationId(add, "agentProfiles.add");
            // The same settings as in Account, where a profile is named and
            // its agents signed in, without leaving the chat.
            add.Click += async (_, _) =>
            {
                if (picker?.XamlRoot is null) return;
                var dialog = new ContentDialog
                {
                    XamlRoot = picker.XamlRoot,
                    Title = L10n.Text("windows.profiles.title"),
                    Content = new ScrollViewer { Content = new AgentProfileSettings(), MaxHeight = 560 },
                    CloseButtonText = L10n.Text("common.done"),
                    DefaultButton = ContentDialogButton.Close,
                };
                await Chrome.ShowDialog(picker, dialog);
                if (onManaged is not null) await onManaged();
            };
            menu.Items.Add(add);
        }
        // A small chip beside the panel's title, as on the Mac and the phones:
        // which login the listed agents run as, one tap from changing.
        var chip = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
        chip.Children.Add(new FontIcon { Glyph = "\uE77B", FontSize = 12 }); // Contact
        chip.Children.Add(new TextBlock { Text = Title(selected), FontSize = 12, VerticalAlignment = VerticalAlignment.Center });
        chip.Children.Add(new FontIcon { Glyph = "\uE70D", FontSize = 9 }); // ChevronDown
        picker = new Button
        {
            Content = chip,
            Flyout = menu, IsEnabled = enabled,
            Foreground = Theme.AccentBrush,
            Background = Theme.Brush(static () => Theme.AccentSoft),
            BorderThickness = new Thickness(0),
            CornerRadius = new CornerRadius(12),
            Padding = new Thickness(10, 3, 10, 3),
            MinHeight = 0,
            VerticalAlignment = VerticalAlignment.Center,
        };
        ToolTipService.SetToolTip(picker, L10n.Text("common.profiles.label"));
        AutomationProperties.SetName(picker, L10n.Text("common.profiles.label") + ", " + Title(selected));
        AutomationProperties.SetAutomationId(picker, "agentProfiles.picker");
        return picker;
    }
}
