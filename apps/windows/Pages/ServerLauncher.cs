// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;

namespace Tokenstat.Pages;

/// <summary>Saved names and connection state, without exposing SSH endpoints.</summary>
internal static class ServerLauncher
{
    internal static string Name(JsonNode host) => SshHostPlatform.SessionLabel(host);
    internal static async Task<JsonNode[]> HostsAsync()
    {
        var hosts = Format.Items(await AppServices.Host.CallAsync("ssh.host.list"));
        return (hosts ?? new JsonArray()).OfType<JsonNode>().OrderByDescending(host => Format.Flag(host, "favorite"))
            .ThenBy(host => Format.Long(host, "sortIndex")).ThenBy(Name, StringComparer.CurrentCultureIgnoreCase).ToArray();
    }
    /// <summary>
    /// Saved servers in the launcher column, like the Mac: a heading with
    /// Manage servers on the right, then one row per server that says what a
    /// click does. Not a card of its own, so it lines up with the tiles.
    /// </summary>
    internal static async Task<UIElement> CreateAsync(Func<JsonNode, Task> open, Action manage)
    {
        var body = new StackPanel { Spacing = Theme.SpaceS };
        var header = new Grid { ColumnSpacing = Theme.SpaceS };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(new FontIcon { Glyph = "\uE968", FontSize = 14, VerticalAlignment = VerticalAlignment.Center }); // Network
        var title = new TextBlock
        {
            Text = L10n.Text("windows.serverlauncher.servers"),
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(title, 1);
        header.Children.Add(title);
        var manageButton = Link(L10n.Text("windows.serverlauncher.manage_servers"), ActionIcon.Settings);
        manageButton.Click += (_, _) => manage();
        Grid.SetColumn(manageButton, 2);
        header.Children.Add(manageButton);
        body.Children.Add(header);
        try
        {
            var hosts = await HostsAsync();
            var live = Format.Items(await AppServices.Host.CallAsync("ssh.session.list")) ?? new JsonArray();
            foreach (var host in hosts)
            {
                var connected = live.Any(session => Format.Flag(session, "alive") && Format.Text(session, "hostId") == Format.Text(host, "id"));
                var content = new StackPanel { Spacing = 3 };
                content.Children.Add(new TextBlock { Text = Name(host), FontWeight = Microsoft.UI.Text.FontWeights.Medium, TextTrimming = TextTrimming.CharacterEllipsis });
                content.Children.Add(new TextBlock { Text = connected ? L10n.Text("windows.serverlauncher.connected") : "SSH", Opacity = 0.7, FontSize = 12 });
                var row = new Grid { ColumnSpacing = Theme.SpaceS };
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                row.Children.Add(SshHostPlatform.Row(SshHostPlatform.Label(host), content));
                // What a click does, in words: back to the live shell, or the
                // connection form.
                var verb = Verb(connected ? L10n.Text("common.open") : L10n.Text("common.connect"),
                    connected ? ActionIcon.Run : ActionIcon.Next);
                Grid.SetColumn(verb, 1);
                row.Children.Add(verb);
                var button = new Button
                {
                    Content = row,
                    HorizontalAlignment = HorizontalAlignment.Stretch,
                    HorizontalContentAlignment = HorizontalAlignment.Stretch,
                    Background = Theme.PanelBrush,
                    BorderBrush = Theme.BorderBrush,
                    BorderThickness = new Thickness(1),
                    CornerRadius = new CornerRadius(8),
                    Padding = new Thickness(Theme.SpaceM),
                };
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, Name(host) + ". " + (connected ? L10n.Text("common.open") : L10n.Text("common.connect")));
                button.Click += async (_, _) =>
                {
                    button.IsEnabled = false;
                    try { await open(host); }
                    catch (Exception ex) { body.Children.Add(Chrome.Banner(FriendlyError.Display(ex.Message), Theme.Danger, Symbol.Important)); }
                    finally { button.IsEnabled = true; }
                };
                body.Children.Add(button);
            }
            if (hosts.Length == 0) body.Children.Add(new TextBlock { Text = L10n.Text("windows.serverlauncher.no_servers"), Opacity = 0.7, FontSize = 12, TextWrapping = TextWrapping.Wrap });
        }
        catch (Exception ex) { body.Children.Add(Chrome.Banner(FriendlyError.Display(ex.Message), Theme.Danger, Symbol.Important)); }
        return body;
    }

    /// <summary>A quiet accent link with its glyph, the Mac's plain caption button.</summary>
    private static Button Link(string title, ActionIcon icon)
    {
        var button = new Button
        {
            Content = Verb(title, icon),
            Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(4, 2, 4, 2),
            MinHeight = 0,
            MinWidth = 0,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, title);
        return button;
    }

    /// <summary>Glyph and caption in the accent, for what a row or link does.</summary>
    private static StackPanel Verb(string title, ActionIcon icon)
    {
        var glyph = icon.Icon();
        glyph.Foreground = Theme.AccentBrush;
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        row.Children.Add(new Viewbox { Width = 12, Height = 12, Child = glyph, VerticalAlignment = VerticalAlignment.Center });
        row.Children.Add(new TextBlock { Text = title, FontSize = 12, FontWeight = Microsoft.UI.Text.FontWeights.Medium, Foreground = Theme.AccentBrush, VerticalAlignment = VerticalAlignment.Center });
        return row;
    }
}
