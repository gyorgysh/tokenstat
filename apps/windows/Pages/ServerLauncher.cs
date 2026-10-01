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
    internal static async Task<UIElement> CreateAsync(Func<JsonNode, Task> open)
    {
        var body = new StackPanel { Spacing = Theme.SpaceS };
        try
        {
            var hosts = await HostsAsync();
            var live = Format.Items(await AppServices.Host.CallAsync("ssh.session.list")) ?? new JsonArray();
            foreach (var host in hosts)
            {
                var connected = live.Any(session => Format.Flag(session, "alive") && Format.Text(session, "hostId") == Format.Text(host, "id"));
                var content = new StackPanel { Spacing = 3 };
                content.Children.Add(new TextBlock { Text = Name(host), FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis });
                content.Children.Add(new TextBlock { Text = connected ? L10n.Text("windows.serverlauncher.connected") : "SSH", Opacity = 0.7, FontSize = 12 });
                var button = new Button { Content = SshHostPlatform.Row(SshHostPlatform.Label(host), content), HorizontalAlignment = HorizontalAlignment.Stretch,
                    HorizontalContentAlignment = HorizontalAlignment.Stretch, Background = Theme.PanelBrush, BorderBrush = Theme.BorderBrush, Padding = new Thickness(12) };
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, Name(host) + ". " + L10n.Text("common.connect"));
                button.Click += async (_, _) =>
                {
                    button.IsEnabled = false;
                    try { await open(host); }
                    catch (Exception ex) { body.Children.Add(Chrome.Banner(FriendlyError.Display(ex.Message), Theme.Danger, Symbol.Important)); }
                    finally { button.IsEnabled = true; }
                };
                body.Children.Add(button);
            }
            if (hosts.Length == 0) body.Children.Add(new TextBlock { Text = L10n.Text("windows.serverlauncher.no_servers"), Opacity = 0.7, TextWrapping = TextWrapping.Wrap });
        }
        catch (Exception ex) { body.Children.Add(Chrome.Banner(FriendlyError.Display(ex.Message), Theme.Danger, Symbol.Important)); }
        return Chrome.Card(L10n.Text("windows.serverlauncher.servers"), body);
    }
}
