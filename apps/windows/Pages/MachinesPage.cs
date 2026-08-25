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
        var tier = Format.Text(account, "tier");
        var isLegend = Format.IsLegend(tier);
        var thisKey = "";
        try
        {
            var identity = await AppServices.Host.CallAsync("machine.identity");
            thisKey = Format.Text(identity, "key");
        }
        catch
        {
            // Viewing still works from publicIdentity on the record.
        }
        var machines = account["machines"] as JsonArray;
        if (machines is null || machines.Count == 0)
        {
            _root.Children.Add(Chrome.Empty(
                "No devices yet",
                "This account has no linked machines.",
                Symbol.CellPhone));
            return;
        }

        var list = new StackPanel { Spacing = Theme.SpaceM };
        var viewable = 0;
        foreach (var machine in machines)
        {
            var id = Format.Text(machine, "id");
            var name = Format.Text(machine, "label", Format.Text(machine, "name", id));
            var kind = Format.Text(machine, "kind");
            var online = Format.Flag(machine, "online");
            var mine = id == thisId;
            if (string.IsNullOrEmpty(id))
            {
                continue;
            }

            var bits = new List<string>();
            if (online)
            {
                bits.Add("online");
            }
            if (mine)
            {
                bits.Add("this device");
            }
            if (!string.IsNullOrEmpty(kind))
            {
                bits.Add(kind);
            }

            var body = new StackPanel { Spacing = Theme.SpaceS };
            body.Children.Add(new TextBlock
            {
                Text = name,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                TextWrapping = TextWrapping.Wrap,
            });
            if (bits.Count > 0)
            {
                body.Children.Add(new TextBlock
                {
                    Text = string.Join(" · ", bits),
                    Opacity = 0.7,
                    TextWrapping = TextWrapping.Wrap,
                });
            }

            var machineId = id;
            var machineName = name;
            var peer = Format.Text(machine, "publicIdentity");
            var kindLower = kind.ToLowerInvariant();
            var isClient = kindLower == "client";
            var isThis = mine || (!string.IsNullOrEmpty(thisKey) && peer == thisKey);
            var actions = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = Theme.SpaceS,
            };
            if (!isThis && !isClient)
            {
                viewable++;
                var peerKey = peer;
                var label = machineName;
                var subtitle = isLegend
                    ? "End-to-end encrypted from this device."
                    : "Requires Legend";
                actions.Children.Add(ActionIconGlyph.Button("View screen", ActionIcon.Preview, (_, _) =>
                {
                    if (string.IsNullOrEmpty(peerKey))
                    {
                        _root.Children.Insert(1, Chrome.Banner(
                            "No other host to view. Screen share is for another machine on this account.",
                            Theme.Accent,
                            Symbol.View));
                        return;
                    }
                    var open = AppServices.OpenScreen;
                    if (open is null)
                    {
                        _root.Children.Insert(1, Chrome.Banner(
                            "Screen share is not wired in this window.",
                            Theme.Danger,
                            Symbol.Important));
                        return;
                    }
                    open(peerKey, label);
                }));
                body.Children.Add(new TextBlock
                {
                    Text = subtitle,
                    Opacity = 0.7,
                    TextWrapping = TextWrapping.Wrap,
                });
            }
            actions.Children.Add(ActionIconGlyph.Button("Rename", ActionIcon.Edit, async (_, _) =>
            {
                await RenameAsync(machineId, machineName);
            }));
            actions.Children.Add(ActionIconGlyph.Button("Unlink", ActionIcon.Disconnect, async (_, _) =>
            {
                await UnlinkAsync(machineId, machineName);
            }));
            body.Children.Add(actions);
            list.Children.Add(body);
        }
        if (viewable == 0)
        {
            _root.Children.Add(Chrome.Banner(
                "No other host to view. Screen share is for another machine on this account.",
                Theme.Accent,
                Symbol.View));
        }
        _root.Children.Add(Chrome.Card("Devices", list));
    }

    private async Task RenameAsync(string id, string current)
    {
        var box = new TextBox { Text = current, PlaceholderText = "Device name" };
        var dialog = new ContentDialog
        {
            Title = "Rename device",
            Content = box,
            PrimaryButtonText = "Save",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await Chrome.ShowDialog(this, dialog) != ContentDialogResult.Primary)
        {
            return;
        }
        var name = box.Text.Trim();
        if (name.Length == 0)
        {
            return;
        }
        try
        {
            await AppServices.Host.CallAsync(
                "account.renameMachine",
                new JsonObject { ["id"] = id, ["name"] = name });
        }
        catch (Exception ex)
        {
            _root.Children.Insert(1, Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important));
            return;
        }
        await LoadAsync();
    }

    private async Task UnlinkAsync(string id, string name)
    {
        var dialog = new ContentDialog
        {
            Title = "Unlink this device?",
            Content = new TextBlock
            {
                Text = $"{name} will leave the account. Sign in again on that machine to link it.",
                TextWrapping = TextWrapping.Wrap,
            },
            PrimaryButtonText = "Unlink",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
        };
        if (await Chrome.ShowDialog(this, dialog) != ContentDialogResult.Primary)
        {
            return;
        }
        try
        {
            await AppServices.Host.CallAsync(
                "account.unlinkMachine",
                new JsonObject { ["id"] = id });
        }
        catch (Exception ex)
        {
            _root.Children.Insert(1, Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important));
            return;
        }
        await LoadAsync();
    }
}
