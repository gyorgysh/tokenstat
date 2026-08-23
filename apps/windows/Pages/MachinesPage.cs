// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;

namespace Tokenstat.Pages;

internal sealed class MachinesPage : Page
{
    private readonly StackPanel _root = new() { Spacing = Theme.SpaceL };

    public MachinesPage()
    {
        _root.Children.Add(ActionIconGlyph.Button(
            "Refresh", ActionIcon.Refresh, async (_, _) => await LoadAsync()));
        Content = new ScrollViewer
        {
            Padding = new Thickness(Theme.SpaceL),
            Content = _root,
        };
        Loaded += async (_, _) => await LoadAsync();
    }

    private async Task LoadAsync()
    {
        while (_root.Children.Count > 1)
        {
            _root.Children.RemoveAt(1);
        }
        JsonNode account;
        try
        {
            account = await AppServices.Host.CallAsync("account.status");
        }
        catch (Exception ex)
        {
            _root.Children.Add(Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important));
            return;
        }

        if (!(account["signedIn"]?.GetValue<bool>() ?? false))
        {
            _root.Children.Add(Chrome.Empty(
                "Sign in to see devices",
                "Devices live on the account, so a closed laptop still counts. Open Account in the sidebar to link this machine.",
                Symbol.CellPhone));
            return;
        }

        var thisId = Format.Text(account, "thisMachineId");
        var machines = account["machines"] as JsonArray;
        if (machines is null || machines.Count == 0)
        {
            _root.Children.Add(Chrome.Empty(
                "No devices yet",
                "This account has no linked machines.",
                Symbol.CellPhone));
            return;
        }

        var list = new StackPanel { Spacing = Theme.SpaceS };
        foreach (var machine in machines)
        {
            var id = Format.Text(machine, "id");
            var name = Format.Text(machine, "label", Format.Text(machine, "name", id));
            var kind = Format.Text(machine, "kind");
            var online = Format.Flag(machine, "online") ? "online" : "";
            var mine = id == thisId ? "this device" : "";
            var bits = new[] { name, kind, online, mine }.Where(s => s.Length > 0);
            list.Children.Add(new TextBlock
            {
                Text = string.Join(" · ", bits),
                TextWrapping = TextWrapping.Wrap,
            });
        }
        _root.Children.Add(Chrome.Card("Devices", list));
    }
}
