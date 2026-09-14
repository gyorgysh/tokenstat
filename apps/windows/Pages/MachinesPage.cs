// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Diagnostics;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;

namespace Tokenstat.Pages;

/// <summary>
/// This PC, who may reach it, and who it can reach. Ordered by what somebody
/// came here to do: read this PC's own two words, flip reach, then the
/// account devices with rename, view, and remove.
/// </summary>
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
            _root.Children.Add(Chrome.Banner(
                FriendlyError.Display(ex.Message), Theme.Danger, Symbol.Important));
            return;
        }

        if (!(account["signedIn"]?.GetValue<bool>() ?? false))
        {
            _root.Children.Add(Chrome.Empty(
                "Sign in to see devices",
                "Devices live on the account, so a closed laptop still counts. Open Account in the sidebar to link this machine.",
                ActionIcon.Device));
            return;
        }

        var thisId = Format.Text(account, "thisMachineId");
        var tier = Format.Text(account, "tier");
        var allowed = RemoteReachAllowed(account);
        var thisKey = "";
        var words = "";
        var selfName = "";
        try
        {
            var identity = await AppServices.Host.CallAsync("machine.identity");
            thisKey = Format.Text(identity, "key");
            words = Format.Text(identity, "words");
            selfName = Format.Text(identity, "label");
        }
        catch
        {
            // Viewing still works from publicIdentity on the record.
        }
        var tunnel = false;
        try
        {
            var status = await AppServices.Host.CallAsync("remote.status");
            tunnel = status["tunnel"]?.GetValue<bool>() ?? false;
        }
        catch
        {
            // The switch reads off until the helper says otherwise.
        }

        _root.Children.Add(ThisMachineCard(selfName, words, allowed, tunnel, account));
        if (!allowed)
        {
            _root.Children.Add(RemoteLockedCard(account));
        }

        var machines = account["machines"] as JsonArray;
        if (machines is null || machines.Count == 0)
        {
            _root.Children.Add(EmptyState.View(
                "No devices yet",
                "This account has no linked machines.",
                EmptyArtKind.Devices));
            return;
        }

        var list = new StackPanel { Spacing = Theme.SpaceM };
        var viewable = 0;
        foreach (var machine in machines)
        {
            var id = Format.Text(machine, "id");
            if (string.IsNullOrEmpty(id))
            {
                continue;
            }
            var peer = Format.Text(machine, "publicIdentity");
            var isSelf = id == thisId
                || (!string.IsNullOrEmpty(thisKey) && peer == thisKey);
            var row = DeviceRow(machine, id, isSelf, tier, ref viewable);
            list.Children.Add(row);
        }
        _root.Children.Add(Chrome.Card(
            "Your devices",
            list,
            "Select a device for connection details. Phones and tablets connect to this PC."));
        if (viewable == 0)
        {
            _root.Children.Add(Chrome.Banner(
                "No other host to view. Screen share is for another machine on this account.",
                Theme.Accent,
                Symbol.View));
        }
    }

    /// <summary>
    /// Whether the relay will take this account. The relay enforces the plan
    /// at every HELLO, so this is the courtesy copy of the same gate.
    /// </summary>
    internal static bool RemoteReachAllowed(JsonNode? account)
    {
        if (account?["canRemote"] is JsonValue flag
            && flag.GetValueKind() is System.Text.Json.JsonValueKind.True
                or System.Text.Json.JsonValueKind.False)
        {
            return flag.GetValue<bool>();
        }
        if (!(account?["signedIn"]?.GetValue<bool>() ?? false))
        {
            return false;
        }
        var tier = Format.Text(account, "tier").ToLowerInvariant();
        return tier is "patron" or "legend";
    }

    /// <summary>
    /// Identity and remote access for this PC. The name, the two words to
    /// compare with the other end, and the one switch.
    /// </summary>
    private UIElement ThisMachineCard(
        string selfName, string words, bool allowed, bool tunnel, JsonNode account)
    {
        var body = new StackPanel { Spacing = Theme.SpaceM };
        var nameRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        nameRow.Children.Add(new TextBlock { Text = "Name", Opacity = 0.7, VerticalAlignment = VerticalAlignment.Center });
        nameRow.Children.Add(new TextBlock
        {
            Text = string.IsNullOrEmpty(selfName) ? "This PC" : selfName,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
        });
        nameRow.Children.Add(ActionIconGlyph.Button(
            "Rename", ActionIcon.Edit, async (_, _) => await RenameSelfAsync(selfName)));
        body.Children.Add(nameRow);
        if (!string.IsNullOrEmpty(words))
        {
            // The comparison a person actually performs. The words are derived
            // from a public key: there is nothing private in them, so they are
            // shown plain and selectable.
            var knownRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
            knownRow.Children.Add(new TextBlock { Text = "Known as", Opacity = 0.7, VerticalAlignment = VerticalAlignment.Center });
            knownRow.Children.Add(new TextBlock
            {
                Text = words,
                FontWeight = Microsoft.UI.Text.FontWeights.Medium,
                Foreground = Theme.AccentBrush,
                IsTextSelectionEnabled = true,
                VerticalAlignment = VerticalAlignment.Center,
            });
            body.Children.Add(knownRow);
        }
        body.Children.Add(Chrome.ToggleChip("Reach devices from anywhere", allowed && tunnel, async on =>
        {
            if (!allowed)
            {
                return;
            }
            try
            {
                await AppServices.Host.CallAsync(
                    "remote.serve",
                    new JsonObject { ["tunnel"] = on });
            }
            catch (Exception ex)
            {
                _root.Children.Insert(1, Chrome.Banner(
                    FriendlyError.Display(ex.Message), Theme.Danger, Symbol.Important));
                return;
            }
            await LoadAsync();
        }));
        body.Children.Add(new TextBlock
        {
            Text = allowed && tunnel
                ? "Remote access is on. This PC will be reachable while tokenstat is running."
                : "Turn this on to make this PC reachable from your other devices.",
            Opacity = 0.7,
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
        });
        body.Children.Add(new TextBlock
        {
            Text = "Connections are end-to-end encrypted. Screen sharing prefers a direct local route and otherwise uses the tunnel.",
            Opacity = 0.6,
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
        });
        if (!allowed)
        {
            body.Children.Add(new TextBlock
            {
                Text = (account["signedIn"]?.GetValue<bool>() ?? false)
                    ? "This computer and another device already share the account."
                    : "Remote reach needs a signed-in Patron account.",
                FontWeight = Microsoft.UI.Text.FontWeights.Medium,
                TextWrapping = TextWrapping.Wrap,
            });
            body.Children.Add(new TextBlock
            {
                Text = (account["signedIn"]?.GetValue<bool>() ?? false)
                    ? "Free and Supporter add up usage from every device you link. Opening folders and terminals on this PC from another device is on Patron."
                    : "Sign in with an account that includes it, then turn the switch on.",
                Opacity = 0.7,
                FontSize = 12,
                TextWrapping = TextWrapping.Wrap,
            });
        }
        return Chrome.Card(
            "Connection settings",
            body,
            "Identity and remote access for this PC");
    }

    /// <summary>
    /// Free and Supporter already share usage. One upgrade card, then the
    /// machine list, matching the Mac: the action that ends it reaches the
    /// first screenful.
    /// </summary>
    private static UIElement RemoteLockedCard(JsonNode account)
    {
        var signedIn = account["signedIn"]?.GetValue<bool>() ?? false;
        var body = new StackPanel { Spacing = Theme.SpaceM };
        body.Children.Add(new TextBlock
        {
            Text = signedIn
                ? "This PC already shares the account and sees usage from every device on it. Opening folders and terminals from another device is a paid feature."
                : "Sign in with a Patron or Legend account to open folders and terminals on this PC from another device.",
            Opacity = 0.7,
            TextWrapping = TextWrapping.Wrap,
        });
        body.Children.Add(ActionIconGlyph.Button(
            "See plans", ActionIcon.Plans, (_, _) => Open("https://tokenstat.ai/pricing")));
        return Chrome.Card("Remote is on Patron", body);
    }

    /// <summary>
    /// One account device. The title is never the id: the code sits under it
    /// in monospace, where an identifier belongs.
    /// </summary>
    private UIElement DeviceRow(
        JsonNode? machine, string id, bool isSelf, string tier, ref int viewable)
    {
        var label = Format.Text(machine, "label");
        var kind = Format.Text(machine, "kind");
        var isHost = kind != "client";
        var title = !string.IsNullOrEmpty(label)
            ? label
            : isHost ? "Unnamed computer" : "Unnamed device";
        var body = new StackPanel { Spacing = Theme.SpaceS };
        var head = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        head.Children.Add(new TextBlock
        {
            Text = title,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
            VerticalAlignment = VerticalAlignment.Center,
        });
        if (isSelf)
        {
            head.Children.Add(new TextBlock { Text = "THIS PC", Opacity = 0.6, FontSize = 11, VerticalAlignment = VerticalAlignment.Center });
        }
        body.Children.Add(head);
        var platform = Format.Text(machine, "platform");
        if (!string.IsNullOrEmpty(platform))
        {
            body.Children.Add(new TextBlock { Text = platform, Opacity = 0.7, FontSize = 12 });
        }
        if (!string.IsNullOrEmpty(label))
        {
            body.Children.Add(new TextBlock
            {
                Text = id,
                FontFamily = Fonts.Mono,
                Opacity = 0.55,
                FontSize = 11,
                IsTextSelectionEnabled = true,
            });
        }
        body.Children.Add(new TextBlock
        {
            Text = HomePage.StatusLine(machine, isSelf),
            Opacity = 0.7,
            FontSize = 12,
        });

        var peer = Format.Text(machine, "publicIdentity");
        var actions = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Theme.SpaceS,
        };
        if (isHost && !isSelf)
        {
            viewable++;
            var peerKey = peer;
            var deviceName = title;
            var isLegend = Format.IsLegend(tier);
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
                open(peerKey, deviceName);
            }));
            actions.Children.Add(new TextBlock
            {
                Text = subtitle,
                Opacity = 0.7,
                FontSize = 12,
                VerticalAlignment = VerticalAlignment.Center,
            });
        }
        actions.Children.Add(ActionIconGlyph.Button("Rename", ActionIcon.Edit, async (_, _) =>
        {
            await RenameAsync(id, label);
        }));
        actions.Children.Add(ActionIconGlyph.Button("Unlink", ActionIcon.Disconnect, async (_, _) =>
        {
            await UnlinkAsync(id, title);
        }));
        body.Children.Add(actions);
        return body;
    }

    /// <summary>
    /// This PC names itself: that writes the local label, so the two agree.
    /// Clearing the field hands the name back to the device.
    /// </summary>
    private async Task RenameSelfAsync(string current)
    {
        var box = new TextBox { Text = current, PlaceholderText = "Device name" };
        var dialog = new ContentDialog
        {
            Title = "Rename this PC",
            Content = box,
            PrimaryButtonText = "Save",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await Chrome.ShowDialog(this, dialog) != ContentDialogResult.Primary)
        {
            return;
        }
        try
        {
            await AppServices.Host.CallAsync(
                "machine.rename",
                new JsonObject { ["name"] = box.Text.Trim() });
            var renamed = box.Text.Trim();
        }
        catch (Exception ex)
        {
            _root.Children.Insert(1, Chrome.Banner(
                FriendlyError.Display(ex.Message), Theme.Danger, Symbol.Important));
            return;
        }
        await LoadAsync();
        _root.Children.Insert(1, Chrome.Banner(
            renamed.Length == 0
                ? "Back to the name that device gives itself."
                : $"Every screen on this account calls it {renamed} now.",
            Theme.Accent,
            Symbol.Contact));
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
        try
        {
            await AppServices.Host.CallAsync(
                "account.renameMachine",
                new JsonObject { ["id"] = id, ["name"] = name });
        }
        catch (Exception ex)
        {
            _root.Children.Insert(1, Chrome.Banner(
                FriendlyError.Display(ex.Message), Theme.Danger, Symbol.Important));
            return;
        }
        await LoadAsync();
        _root.Children.Insert(1, Chrome.Banner(
            name.Length == 0
                ? "Back to the name that device gives itself."
                : $"Every screen on this account calls it {name} now.",
            Theme.Accent,
            Symbol.Contact));
    }

    /// <summary>
    /// Destructive on the server: the machine's uploaded history is deleted,
    /// which is what a stale device id after a reinstall needs so a live
    /// machine can use its slot. Never from a single click.
    /// </summary>
    private async Task UnlinkAsync(string id, string name)
    {
        var dialog = new ContentDialog
        {
            Title = "Remove from account?",
            Content = new TextBlock
            {
                Text = $"{name} will be removed from this account and its uploaded history deleted. "
                    + "Use this for a device id that no longer exists, for example after a reinstall.",
                TextWrapping = TextWrapping.Wrap,
            },
            PrimaryButtonText = "Remove",
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
            _root.Children.Insert(1, Chrome.Banner(
                FriendlyError.Display(ex.Message), Theme.Danger, Symbol.Important));
            return;
        }
        await LoadAsync();
        _root.Children.Insert(1, Chrome.Banner(
            $"{name} removed from the account.",
            Theme.Accent,
            Symbol.Contact));
    }

    private static void Open(string url)
    {
        try
        {
            Process.Start(new ProcessStartInfo { FileName = url, UseShellExecute = true });
        }
        catch
        {
            // The card names the page, so the address is one search away.
        }
    }
}
