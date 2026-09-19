// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Diagnostics;
using System.Linq;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Windows.ApplicationModel.DataTransfer;

namespace Tokenstat.Pages;

/// <summary>
/// This PC, who may reach it, and who it can reach. Mirrors the Mac Devices
/// screen: approvals first, then the account devices, then this PC's own
/// connection settings, then the encryption note. Ordered by what somebody
/// came here to do: decide about a machine that is knocking, then read this
/// PC's own two words to compare with the other end, then add something new.
/// </summary>
internal sealed class MachinesPage : Page, IInspectorContent
{
    private readonly ContentControl _barSlot = new()
    {
        HorizontalAlignment = HorizontalAlignment.Stretch,
        HorizontalContentAlignment = HorizontalAlignment.Stretch,
    };
    private readonly StackPanel _root = new() { Spacing = Theme.SpaceL };
    private readonly StackPanel _inspectorRoot = new()
    {
        Spacing = Theme.SpaceM,
        Padding = new Thickness(Theme.SpaceM),
    };

    private JsonNode? _account;
    private JsonNode? _identity;
    private JsonNode? _status;
    private JsonArray _peers = new();
    private string? _notice;

    /// <summary>
    /// What the inspector is showing. Keys only, so a refresh cannot pin a
    /// stale device value. Null means nothing is picked yet.
    /// </summary>
    private string? _selectedId;
    private bool _selectThis;

    public MachinesPage()
    {
        var scroller = new ScrollViewer
        {
            Padding = new Thickness(Theme.SpaceL),
            Content = _root,
        };
        var layout = new Grid();
        layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        layout.RowDefinitions.Add(new RowDefinition
        {
            Height = new GridLength(1, GridUnitType.Star),
        });
        layout.Children.Add(_barSlot);
        Grid.SetRow(scroller, 1);
        layout.Children.Add(scroller);
        Content = layout;
        RebuildChrome(false);
        RefreshInspector();
        Loaded += async (_, _) => await LoadAsync();
    }

    /// <summary>
    /// The inspector column content. Selection and reloads replace its
    /// children, so the column stays live without the shell asking again.
    /// </summary>
    public UIElement? Inspector => _inspectorRoot;

    private void RebuildChrome(bool allowed)
    {
        var trailing = new List<UIElement>
        {
            Buttons.ToolbarIcon(
                ActionIcon.Refresh,
                "Re-read this PC and its devices",
                async (_, _) => await LoadAsync()),
        };
        if (allowed)
        {
            trailing.Add(Buttons.ToolbarIcon(
                ActionIcon.Create,
                "Paste a key from another device to pair it",
                async (_, _) => await PairAsync()));
        }
        _barSlot.Content = DetailBar.View(trailing: trailing);
    }

    private async Task LoadAsync()
    {
        JsonNode account;
        try
        {
            account = await AppServices.Host.CallAsync("account.status");
        }
        catch (Exception ex)
        {
            _account = null;
            _root.Children.Clear();
            if (!string.IsNullOrEmpty(_notice))
            {
                _root.Children.Add(Chrome.Banner(_notice, Theme.Accent, Symbol.Contact));
                _notice = null;
            }
            _root.Children.Add(Chrome.Banner(
                FriendlyError.Display(ex.Message), Theme.Danger, Symbol.Important));
            RebuildChrome(false);
            RefreshInspector();
            return;
        }
        _account = account;

        try
        {
            _identity = await AppServices.Host.CallAsync("machine.identity");
        }
        catch
        {
            _identity = null;
        }
        try
        {
            _status = await AppServices.Host.CallAsync("remote.status");
        }
        catch
        {
            _status = null;
        }
        try
        {
            _peers = await AppServices.Host.CallAsync("machine.peers") as JsonArray ?? new();
        }
        catch
        {
            _peers = new();
        }

        Render();
        RebuildChrome(RemoteReachAllowed(account));
        RefreshInspector();
    }

    /// <summary>
    /// Rebuild the content from the cached fetch. Selection calls this rather
    /// than LoadAsync, so picking a device does not re-read the daemon.
    /// </summary>
    private void Render()
    {
        _root.Children.Clear();
        if (!string.IsNullOrEmpty(_notice))
        {
            _root.Children.Add(Chrome.Banner(_notice, Theme.Accent, Symbol.Contact));
            _notice = null;
        }
        var account = _account;
        if (account is null)
        {
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

        var allowed = RemoteReachAllowed(account);
        if (allowed)
        {
            var pending = PendingPeers();
            if (pending.Count > 0)
            {
                _root.Children.Add(ApprovalCard(pending));
            }
            var machines = account["machines"] as JsonArray;
            if (machines is not null && machines.Count > 0)
            {
                _root.Children.Add(AccountDevicesCard(account, machines));
            }
            else
            {
                _root.Children.Add(EmptyState.View(
                    "No devices yet",
                    "This account has no linked machines.",
                    EmptyArtKind.Devices));
            }
            var unlisted = UnlistedKnown(account);
            if (unlisted.Count > 0)
            {
                _root.Children.Add(OtherApprovedCard(unlisted));
            }
            _root.Children.Add(ThisMachineCard(account, allowed, TunnelOn()));
            // Pairing is only needed for a machine that is not on the account
            // yet, so the paste card stays off the first screenful once a list
            // exists. The toolbar plus opens the same dialog.
            if (machines is null || machines.Count == 0)
            {
                _root.Children.Add(AddDeviceCard());
            }
            _root.Children.Add(EncryptionNote());
        }
        else
        {
            _root.Children.Add(RemoteLockedCard(account));
            var machines = account["machines"] as JsonArray;
            if (machines is not null && machines.Count > 0)
            {
                _root.Children.Add(LockedMachineList(account, machines));
            }
            _root.Children.Add(EncryptionNote());
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

    private bool TunnelOn() => _status?["tunnel"]?.GetValue<bool>() ?? false;

    private string SelfKey() => Format.Text(_identity, "key");

    private List<JsonNode> PendingPeers()
    {
        var self = SelfKey();
        var pending = new List<JsonNode>();
        foreach (var peer in _peers.OfType<JsonNode>())
        {
            if (Format.Text(peer, "trust") == "pending" && Format.Text(peer, "key") != self)
            {
                pending.Add(peer);
            }
        }
        return pending;
    }

    /// <summary>
    /// Approved peers the account list does not already show, matched on
    /// identity only. Dropping a device from here on a weaker match would
    /// leave nowhere to revoke it.
    /// </summary>
    private List<JsonNode> UnlistedKnown(JsonNode account)
    {
        var covered = new HashSet<string>(StringComparer.Ordinal);
        if (account["machines"] is JsonArray machines)
        {
            foreach (var machine in machines.OfType<JsonNode>())
            {
                var identity = Format.Text(machine, "publicIdentity");
                if (!string.IsNullOrEmpty(identity))
                {
                    covered.Add(identity);
                }
            }
        }
        var self = SelfKey();
        var unlisted = new List<JsonNode>();
        foreach (var peer in _peers.OfType<JsonNode>())
        {
            var key = Format.Text(peer, "key");
            if (Format.Text(peer, "trust") != "pending"
                && key != self
                && !covered.Contains(key))
            {
                unlisted.Add(peer);
            }
        }
        return unlisted;
    }

    private JsonNode? PeerForMachine(JsonNode? machine)
    {
        var identity = Format.Text(machine, "publicIdentity");
        if (string.IsNullOrEmpty(identity))
        {
            return null;
        }
        foreach (var peer in _peers.OfType<JsonNode>())
        {
            if (Format.Text(peer, "key") == identity
                || Format.Text(peer, "fingerprint") == identity)
            {
                return peer;
            }
        }
        return null;
    }

    private bool IsSelf(JsonNode? machine)
    {
        var thisId = Format.Text(_account, "thisMachineId");
        var id = MachineId(machine);
        var self = SelfKey();
        return (!string.IsNullOrEmpty(thisId) && id == thisId)
            || (!string.IsNullOrEmpty(self) && Format.Text(machine, "publicIdentity") == self);
    }

    private static string MachineId(JsonNode? machine)
    {
        var id = Format.Text(machine, "id");
        return string.IsNullOrEmpty(id) ? Format.Text(machine, "machineID") : id;
    }

    /// <summary>
    /// The best name this PC has for an account machine. A machine that was
    /// never named on the server would otherwise show only its code, which is
    /// a row of strangers on a screen meant to answer "which one is my other
    /// computer".
    /// </summary>
    private string DeviceTitle(JsonNode? machine)
    {
        var label = Format.Text(machine, "label");
        if (!string.IsNullOrEmpty(label))
        {
            return label;
        }
        if (IsSelf(machine))
        {
            var self = Format.Text(_identity, "label");
            if (!string.IsNullOrEmpty(self))
            {
                return self;
            }
            var status = Format.Text(_status, "label");
            if (!string.IsNullOrEmpty(status))
            {
                return status;
            }
        }
        else
        {
            var peer = PeerForMachine(machine);
            var known = Format.Text(peer, "label");
            if (!string.IsNullOrEmpty(known))
            {
                return known;
            }
        }
        return Format.Text(machine, "kind") == "client" ? "Unnamed device" : "Unnamed computer";
    }

    /// <summary>
    /// Machines asking to be let in. First, because these are the only things
    /// here that are waiting on a person. Everything else can be read at
    /// leisure.
    /// </summary>
    private UIElement ApprovalCard(List<JsonNode> pending)
    {
        var body = new StackPanel { Spacing = Theme.SpaceM };
        foreach (var peer in pending)
        {
            var key = Format.Text(peer, "key");
            var label = Format.Text(peer, "label");
            var row = new StackPanel { Spacing = Theme.SpaceS };
            row.Children.Add(new TextBlock
            {
                Text = string.IsNullOrEmpty(label) ? "Unnamed device" : label,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                TextWrapping = TextWrapping.Wrap,
            });
            var words = Format.Text(peer, "words");
            if (!string.IsNullOrEmpty(words))
            {
                row.Children.Add(new TextBlock
                {
                    Text = words,
                    Opacity = 0.7,
                    FontSize = 12,
                });
            }
            var actions = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = Theme.SpaceS,
            };
            var name = string.IsNullOrEmpty(label) ? "this device" : label;
            actions.Children.Add(Buttons.Primary(
                "Approve", ActionIcon.Approve, async (_, _) => await ApproveAsync(key, name)));
            actions.Children.Add(ActionIconGlyph.Button(
                "Forget", ActionIcon.Delete, async (_, _) => await ConfirmForgetAsync(key, name)));
            row.Children.Add(actions);
            body.Children.Add(row);
        }
        body.Children.Add(new TextBlock
        {
            Text = "Approve only devices you recognize. You can revoke access later.",
            Opacity = 0.7,
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
        });
        return Chrome.Card(
            "Needs your approval",
            body,
            "Nothing can run here until you approve it.");
    }

    /// <summary>
    /// Devices paired with this PC but not on the account. They still need a
    /// row with Revoke and Forget, or there is nowhere to turn one away.
    /// </summary>
    private UIElement OtherApprovedCard(List<JsonNode> peers)
    {
        var body = new StackPanel { Spacing = Theme.SpaceM };
        foreach (var peer in peers)
        {
            var key = Format.Text(peer, "key");
            var label = Format.Text(peer, "label");
            var name = string.IsNullOrEmpty(label) ? "Unnamed device" : label;
            var row = new StackPanel { Spacing = Theme.SpaceS };
            row.Children.Add(new TextBlock
            {
                Text = name,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                TextWrapping = TextWrapping.Wrap,
            });
            var words = Format.Text(peer, "words");
            if (!string.IsNullOrEmpty(words))
            {
                row.Children.Add(new TextBlock
                {
                    Text = words,
                    Opacity = 0.7,
                    FontSize = 12,
                });
            }
            var actions = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = Theme.SpaceS,
            };
            if (Format.Text(peer, "trust") == "approved")
            {
                actions.Children.Add(ActionIconGlyph.Button(
                    "Revoke", ActionIcon.Revoke, async (_, _) => await ConfirmRevokeAsync(key, name)));
            }
            else
            {
                actions.Children.Add(ActionIconGlyph.Button(
                    "Approve", ActionIcon.Approve, async (_, _) => await ApproveAsync(key, name)));
            }
            actions.Children.Add(ActionIconGlyph.Button(
                "Forget", ActionIcon.Delete, async (_, _) => await ConfirmForgetAsync(key, name)));
            row.Children.Add(actions);
            body.Children.Add(row);
        }
        return Chrome.Card(
            "Other approved devices",
            body,
            "Devices that are paired with this PC but not on the account.");
    }

    private UIElement AccountDevicesCard(JsonNode account, JsonArray machines)
    {
        var tier = Format.Text(account, "tier");
        var list = new StackPanel { Spacing = Theme.SpaceM };
        var viewable = 0;
        foreach (var machine in machines.OfType<JsonNode>())
        {
            var id = MachineId(machine);
            if (string.IsNullOrEmpty(id))
            {
                continue;
            }
            list.Children.Add(DeviceRow(machine, id, tier, ref viewable));
        }
        var card = Chrome.Card(
            "Your devices",
            list,
            "Select a device for connection details. Phones and tablets connect to this PC.");
        if (viewable == 0)
        {
            var wrap = new StackPanel { Spacing = Theme.SpaceM };
            wrap.Children.Add(card);
            wrap.Children.Add(Chrome.Banner(
                "No other host to view. Screen share is for another machine on this account.",
                Theme.Accent,
                Symbol.View));
            return wrap;
        }
        return card;
    }

    /// <summary>
    /// Names and presence only. Connect, revoke and forget belong on the plan
    /// that can actually open a tunnel.
    /// </summary>
    private UIElement LockedMachineList(JsonNode account, JsonArray machines)
    {
        var list = new StackPanel { Spacing = Theme.SpaceS };
        foreach (var machine in machines.OfType<JsonNode>())
        {
            var isSelf = IsSelf(machine);
            var row = new StackPanel { Spacing = 2 };
            var head = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
            head.Children.Add(new TextBlock
            {
                Text = DeviceTitle(machine),
                FontWeight = Microsoft.UI.Text.FontWeights.Medium,
                VerticalAlignment = VerticalAlignment.Center,
            });
            if (isSelf)
            {
                head.Children.Add(new TextBlock
                {
                    Text = "THIS PC",
                    Opacity = 0.6,
                    FontSize = 11,
                    VerticalAlignment = VerticalAlignment.Center,
                });
            }
            row.Children.Add(head);
            row.Children.Add(new TextBlock
            {
                Text = HomePage.StatusLine(machine, isSelf),
                Opacity = 0.7,
                FontSize = 12,
            });
            list.Children.Add(row);
        }
        return Chrome.Card(
            "Devices on this account",
            list,
            "Usage from every linked device is already here.");
    }

    private UIElement AddDeviceCard()
    {
        var body = new StackPanel { Spacing = Theme.SpaceM };
        body.Children.Add(Buttons.Primary(
            "Add device", ActionIcon.Create, async (_, _) => await PairAsync()));
        return Chrome.Card(
            "Add a device",
            body,
            "Paste the key from the other machine. Everything goes through the tunnel, so it works from any network.");
    }

    /// <summary>
    /// Identity and remote access for this PC. The name, the two words to
    /// compare with the other end, and the one switch.
    /// </summary>
    private UIElement ThisMachineCard(JsonNode account, bool allowed, bool tunnel)
    {
        var selfName = Format.Text(_identity, "label");
        var words = Format.Text(_identity, "words");
        if (string.IsNullOrEmpty(words))
        {
            words = Format.Text(_status, "words");
        }
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
                _notice = null;
                _root.Children.Insert(0, Chrome.Banner(
                    FriendlyError.Display(ex.Message), Theme.Danger, Symbol.Important));
                return;
            }
            _notice = on
                ? "Remote reach is on. Direct connections are preferred when available."
                : "Remote reach is off.";
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
        var tunnelError = Format.Text(_status, "tunnelError");
        if (tunnel && _status?["tunnelOnline"]?.GetValue<bool>() == false)
        {
            body.Children.Add(Chrome.Banner(
                string.IsNullOrEmpty(tunnelError)
                    ? "Remote reach is on, but the tunnel has not connected yet. It retries automatically."
                    : "Remote reach is on, but the tunnel is not connected: " + tunnelError,
                Theme.Warning,
                Symbol.Important));
        }
        body.Children.Add(ActionIconGlyph.Button(
            "Details", ActionIcon.Reveal, (_, _) =>
            {
                _selectThis = true;
                _selectedId = null;
                Render();
                RefreshInspector();
            }));
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
    /// What protects a connection, with the keys it actually runs on. The
    /// paragraph carries the fingerprints somebody can compare against the
    /// other machine rather than asking them to take the sentence on trust.
    /// </summary>
    private UIElement EncryptionNote()
    {
        var details = new StackPanel { Spacing = Theme.SpaceS };
        details.Children.Add(new TextBlock
        {
            Text = "A connection between two machines carries terminal output, file contents and diffs. "
                + "It is encrypted on one machine and decrypted on the other, with keys that never leave them. "
                + "The tunnel relays the encrypted bytes and cannot read them, and neither can tokenstat. "
                + "Only aggregate counters are ever eligible for sync.",
            Opacity = 0.7,
            TextWrapping = TextWrapping.Wrap,
        });
        if (_identity is not null && !string.IsNullOrEmpty(SelfKey()))
        {
            details.Children.Add(KeyLine(
                "This PC",
                Format.Text(_identity, "words"),
                Format.Text(_identity, "fingerprint")));
        }
        foreach (var peer in _peers.OfType<JsonNode>())
        {
            if (Format.Text(peer, "trust") != "approved")
            {
                continue;
            }
            var label = Format.Text(peer, "label");
            details.Children.Add(KeyLine(
                string.IsNullOrEmpty(label) ? "Approved device" : label,
                Format.Text(peer, "words"),
                Format.Text(peer, "fingerprint")));
        }
        details.Children.Add(new TextBlock
        {
            Text = "Noise XX handshake, X25519 keys, ChaCha20-Poly1305. "
                + "Two machines showing the same words for each other are talking to each other and to nothing in between.",
            Opacity = 0.6,
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
        });
        return new Expander
        {
            Header = "End to end encrypted. Keys are hidden until you choose to view them.",
            Content = details,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
        };
    }

    private static UIElement KeyLine(string title, string words, string fingerprint)
    {
        var row = new StackPanel { Spacing = 2 };
        row.Children.Add(new TextBlock
        {
            Text = title,
            FontWeight = Microsoft.UI.Text.FontWeights.Medium,
        });
        row.Children.Add(new TextBlock
        {
            Text = string.IsNullOrEmpty(words) ? fingerprint : words,
            FontWeight = Microsoft.UI.Text.FontWeights.Medium,
            Foreground = Theme.AccentBrush,
        });
        if (!string.IsNullOrEmpty(fingerprint))
        {
            row.Children.Add(new TextBlock
            {
                Text = fingerprint,
                FontFamily = Fonts.Mono,
                FontSize = 11,
                Opacity = 0.6,
                IsTextSelectionEnabled = true,
            });
        }
        return row;
    }

    /// <summary>
    /// One account device. The title is never the id: the code sits under it
    /// in monospace, where an identifier belongs.
    /// </summary>
    private UIElement DeviceRow(
        JsonNode? machine, string id, string tier, ref int viewable)
    {
        var isSelf = IsSelf(machine);
        var title = DeviceTitle(machine);
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
        var peer = PeerForMachine(machine);
        var words = Format.Text(peer, "words");
        if (!string.IsNullOrEmpty(words))
        {
            body.Children.Add(new TextBlock { Text = words, Opacity = 0.7, FontSize = 12 });
        }
        // Only when the machine has a name, so the id is not printed twice on
        // a row that is already showing it as its title.
        if (!string.IsNullOrEmpty(Format.Text(machine, "label")))
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

        var key = Format.Text(machine, "publicIdentity");
        var isHost = Format.Text(machine, "kind") != "client";
        var actions = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Theme.SpaceS,
        };
        if (isHost && !isSelf)
        {
            viewable++;
            var peerKey = key;
            var deviceName = title;
            actions.Children.Add(ActionIconGlyph.Button("View screen", ActionIcon.Preview, (_, _) =>
            {
                if (string.IsNullOrEmpty(peerKey))
                {
                    _root.Children.Insert(0, Chrome.Banner(
                        "No other host to view. Screen share is for another machine on this account.",
                        Theme.Accent,
                        Symbol.View));
                    return;
                }
                var open = AppServices.OpenScreen;
                if (open is null)
                {
                    _root.Children.Insert(0, Chrome.Banner(
                        "Screen share is not wired in this window.",
                        Theme.Danger,
                        Symbol.Important));
                    return;
                }
                open(peerKey, deviceName);
            }));
            actions.Children.Add(new TextBlock
            {
                Text = Format.IsLegend(tier)
                    ? "End-to-end encrypted from this device."
                    : "Requires Legend",
                Opacity = 0.7,
                FontSize = 12,
                VerticalAlignment = VerticalAlignment.Center,
            });
        }
        actions.Children.Add(ActionIconGlyph.Button("Rename", ActionIcon.Edit, async (_, _) =>
        {
            await RenameAsync(id, Format.Text(machine, "label"), isSelf);
        }));
        if (!isSelf)
        {
            actions.Children.Add(ActionIconGlyph.Button("Unlink", ActionIcon.Disconnect, async (_, _) =>
            {
                await UnlinkAsync(id, title);
            }));
        }
        actions.Children.Add(ActionIconGlyph.Button("Details", ActionIcon.Reveal, (_, _) =>
        {
            _selectThis = false;
            _selectedId = id;
            Render();
            RefreshInspector();
        }));
        body.Children.Add(actions);

        var selected = !_selectThis && _selectedId == id;
        return new Border
        {
            Child = body,
            Padding = new Thickness(Theme.SpaceS),
            CornerRadius = new CornerRadius(8),
            Background = selected ? Theme.AccentSoftBrush : Theme.Brush(Microsoft.UI.Colors.Transparent),
            BorderBrush = selected ? Theme.AccentBrush : Theme.BorderBrush,
            BorderThickness = new Thickness(1),
        };
    }

    private void RefreshInspector()
    {
        _inspectorRoot.Children.Clear();
        _inspectorRoot.Children.Add(new TextBlock
        {
            Text = "Device",
            FontSize = 15,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        if (_selectThis && _identity is not null)
        {
            ThisMachineInspector();
            return;
        }
        var machine = FindMachine(_selectedId);
        if (machine is null)
        {
            _inspectorRoot.Children.Add(Chrome.Empty(
                "Pick a device",
                "Reachability and pairing actions open here.",
                ActionIcon.Device));
            return;
        }
        AccountMachineInspector(machine);
    }

    private JsonNode? FindMachine(string? id)
    {
        if (string.IsNullOrEmpty(id) || _account?["machines"] is not JsonArray machines)
        {
            return null;
        }
        foreach (var machine in machines.OfType<JsonNode>())
        {
            if (MachineId(machine) == id)
            {
                return machine;
            }
        }
        return null;
    }

    private void ThisMachineInspector()
    {
        var body = new StackPanel { Spacing = Theme.SpaceM };
        var name = Format.Text(_identity, "label");
        body.Children.Add(new TextBlock
        {
            Text = string.IsNullOrEmpty(name) ? "This PC" : name,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
        });
        var words = Format.Text(_identity, "words");
        if (string.IsNullOrEmpty(words))
        {
            words = Format.Text(_status, "words");
        }
        if (!string.IsNullOrEmpty(words))
        {
            body.Children.Add(Labeled("Known as", words));
        }
        body.Children.Add(Buttons.Primary(
            "Copy invite", ActionIcon.Copy, (_, _) => CopyInvite()));
        body.Children.Add(new TextBlock
        {
            Text = "Paste this in the other machine's Add device box.",
            Opacity = 0.7,
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
        });
        body.Children.Add(Labeled(
            "Reachability",
            _status?["tunnelOnline"]?.GetValue<bool>() == true
                ? "Tunnel up"
                : "Not reachable from elsewhere"));
        _inspectorRoot.Children.Add(body);
    }

    private void AccountMachineInspector(JsonNode machine)
    {
        var id = MachineId(machine);
        var isSelf = IsSelf(machine);
        var title = DeviceTitle(machine);
        var body = new StackPanel { Spacing = Theme.SpaceM };
        body.Children.Add(new TextBlock
        {
            Text = title,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
        });
        body.Children.Add(Labeled("Code", id));
        var platform = Format.Text(machine, "platform");
        if (!string.IsNullOrEmpty(platform))
        {
            body.Children.Add(Labeled("Platform", platform));
        }
        body.Children.Add(Labeled("Status", HomePage.StatusLine(machine, isSelf)));
        var words = Format.Text(PeerForMachine(machine), "words");
        if (!string.IsNullOrEmpty(words))
        {
            body.Children.Add(Labeled("Known as", words));
        }
        var actions = new StackPanel { Spacing = Theme.SpaceS };
        var isHost = Format.Text(machine, "kind") != "client";
        if (isHost && !isSelf)
        {
            var peerKey = Format.Text(machine, "publicIdentity");
            var deviceName = title;
            actions.Children.Add(Buttons.Primary(
                "View screen", ActionIcon.Preview, (_, _) =>
                {
                    var open = AppServices.OpenScreen;
                    if (string.IsNullOrEmpty(peerKey) || open is null)
                    {
                        return;
                    }
                    open(peerKey, deviceName);
                }));
        }
        actions.Children.Add(ActionIconGlyph.Button(
            "Rename", ActionIcon.Edit, async (_, _) =>
            {
                await RenameAsync(id, Format.Text(machine, "label"), isSelf);
            }));
        if (!isSelf)
        {
            actions.Children.Add(ActionIconGlyph.Button(
                "Remove from account", ActionIcon.Delete, async (_, _) =>
                {
                    await UnlinkAsync(id, title);
                }));
        }
        body.Children.Add(actions);
        _inspectorRoot.Children.Add(body);
    }

    private static UIElement Labeled(string title, string value)
    {
        var stack = new StackPanel { Spacing = 2 };
        stack.Children.Add(new TextBlock
        {
            Text = title,
            FontSize = 12,
            Opacity = 0.6,
        });
        stack.Children.Add(new TextBlock
        {
            Text = value,
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
        });
        return stack;
    }

    /// <summary>
    /// Copy this PC's connection invite to the clipboard. Nobody has to read
    /// the invite: it contains the public key and, while a listener is live, a
    /// LAN address hint that is accepted only after Noise proves the key.
    /// </summary>
    private void CopyInvite()
    {
        var key = SelfKey();
        if (string.IsNullOrEmpty(key))
        {
            return;
        }
        var code = key;
        if (_status?["directCandidates"] is JsonArray candidates)
        {
            string? best = null;
            long priority = long.MinValue;
            foreach (var candidate in candidates.OfType<JsonNode>())
            {
                if (Format.Text(candidate, "kind") != "lan")
                {
                    continue;
                }
                var rank = Format.Long(candidate, "priority");
                if (best is null || rank > priority)
                {
                    best = Format.Text(candidate, "address");
                    priority = rank;
                }
            }
            if (!string.IsNullOrEmpty(best))
            {
                code = key + "@" + best;
            }
        }
        try
        {
            var package = new DataPackage { RequestedOperation = DataPackageOperation.Copy };
            package.SetText(code);
            Clipboard.SetContent(package);
        }
        catch
        {
            _root.Children.Insert(0, Chrome.Banner(
                "The invite could not reach the clipboard.",
                Theme.Warning,
                Symbol.Important));
            return;
        }
        _notice = "Invite copied. On the other device, choose Add device and paste it there.";
        Render();
    }

    /// <summary>
    /// Pair a machine that is not on the account yet. The paste is the whole
    /// form: a key, a name for the list, and an optional address hint.
    /// </summary>
    private async Task PairAsync()
    {
        var keyBox = new TextBox { PlaceholderText = "Key from the other machine" };
        var labelBox = new TextBox { PlaceholderText = "Name for the list" };
        var addressBox = new TextBox { PlaceholderText = "Address (optional)" };
        var form = new StackPanel { Spacing = Theme.SpaceS };
        form.Children.Add(keyBox);
        form.Children.Add(labelBox);
        form.Children.Add(addressBox);
        var dialog = new ContentDialog
        {
            Title = "Add a device",
            Content = form,
            PrimaryButtonText = "Pair",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await Chrome.ShowDialog(this, dialog) != ContentDialogResult.Primary)
        {
            return;
        }
        var key = keyBox.Text.Trim();
        if (key == SelfKey())
        {
            _root.Children.Insert(0, Chrome.Banner(
                "That is this device. It is already here and does not need to be added.",
                Theme.Warning,
                Symbol.Important));
            return;
        }
        try
        {
            var peer = await AppServices.Host.CallAsync(
                "machine.pair",
                new JsonObject
                {
                    ["key"] = key,
                    ["label"] = labelBox.Text.Trim(),
                    ["address"] = addressBox.Text.Trim(),
                });
            var name = Format.Text(peer, "label");
            _notice = string.IsNullOrEmpty(name)
                ? "Paired. It will not answer until somebody approves this machine over there too."
                : $"Paired with {name}. It will not answer until somebody approves this machine over there too.";
        }
        catch (Exception ex)
        {
            _root.Children.Insert(0, Chrome.Banner(
                FriendlyError.Display(ex.Message), Theme.Danger, Symbol.Important));
            return;
        }
        await LoadAsync();
    }

    private async Task ApproveAsync(string key, string name)
    {
        try
        {
            await AppServices.Host.CallAsync("machine.approve", new JsonObject { ["key"] = key });
            _notice = $"{name} may now reach this device.";
        }
        catch (Exception ex)
        {
            _root.Children.Insert(0, Chrome.Banner(
                FriendlyError.Display(ex.Message), Theme.Danger, Symbol.Important));
            return;
        }
        await LoadAsync();
    }

    private async Task ConfirmRevokeAsync(string key, string name)
    {
        var dialog = new ContentDialog
        {
            Title = "Revoke access?",
            Content = new TextBlock
            {
                Text = "That device can no longer reach this machine until you approve it again.",
                TextWrapping = TextWrapping.Wrap,
            },
            PrimaryButtonText = "Revoke",
            CloseButtonText = "Keep access",
            DefaultButton = ContentDialogButton.Close,
        };
        if (await Chrome.ShowDialog(this, dialog) != ContentDialogResult.Primary)
        {
            return;
        }
        try
        {
            await AppServices.Host.CallAsync("machine.revoke", new JsonObject { ["key"] = key });
            _notice = $"{name} can no longer reach this device.";
        }
        catch (Exception ex)
        {
            _root.Children.Insert(0, Chrome.Banner(
                FriendlyError.Display(ex.Message), Theme.Danger, Symbol.Important));
            return;
        }
        await LoadAsync();
    }

    private async Task ConfirmForgetAsync(string key, string name)
    {
        var dialog = new ContentDialog
        {
            Title = "Forget this device?",
            Content = new TextBlock
            {
                Text = "It is removed from this machine's peer list. You can approve it again later if it connects.",
                TextWrapping = TextWrapping.Wrap,
            },
            PrimaryButtonText = "Forget",
            CloseButtonText = "Keep it",
            DefaultButton = ContentDialogButton.Close,
        };
        if (await Chrome.ShowDialog(this, dialog) != ContentDialogResult.Primary)
        {
            return;
        }
        try
        {
            await AppServices.Host.CallAsync("machine.forget", new JsonObject { ["key"] = key });
            _notice = $"{name} is forgotten. It will arrive as a stranger next time.";
        }
        catch (Exception ex)
        {
            _root.Children.Insert(0, Chrome.Banner(
                FriendlyError.Display(ex.Message), Theme.Danger, Symbol.Important));
            return;
        }
        await LoadAsync();
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
        var renamed = box.Text.Trim();
        try
        {
            await AppServices.Host.CallAsync(
                "machine.rename",
                new JsonObject { ["name"] = renamed });
        }
        catch (Exception ex)
        {
            _root.Children.Insert(0, Chrome.Banner(
                FriendlyError.Display(ex.Message), Theme.Danger, Symbol.Important));
            return;
        }
        _notice = renamed.Length == 0
            ? "Back to the name this computer already had."
            : $"Other devices will see this one as {renamed}.";
        await LoadAsync();
    }

    /// <summary>
    /// Call another device on this account something. Renames the account row,
    /// not that machine's own file: the point is that a headless server nobody
    /// can log into is still nameable from here.
    /// </summary>
    private async Task RenameAsync(string id, string current, bool isSelf)
    {
        var box = new TextBox { Text = current, PlaceholderText = "Device name" };
        var dialog = new ContentDialog
        {
            Title = isSelf ? "Rename this PC" : "Rename device",
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
            if (isSelf)
            {
                // This computer names itself: that writes the local label, so
                // the two agree. Renaming only the account row would leave this
                // PC calling itself one thing and the website another.
                await AppServices.Host.CallAsync(
                    "machine.rename",
                    new JsonObject { ["name"] = name });
            }
            else
            {
                await AppServices.Host.CallAsync(
                    "account.renameMachine",
                    new JsonObject { ["id"] = id, ["name"] = name });
            }
        }
        catch (Exception ex)
        {
            _root.Children.Insert(0, Chrome.Banner(
                FriendlyError.Display(ex.Message), Theme.Danger, Symbol.Important));
            return;
        }
        _notice = name.Length == 0
            ? "Back to the name that device gives itself."
            : $"Every screen on this account calls it {name} now.";
        await LoadAsync();
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
            _root.Children.Insert(0, Chrome.Banner(
                FriendlyError.Display(ex.Message), Theme.Danger, Symbol.Important));
            return;
        }
        if (_selectedId == id)
        {
            _selectedId = null;
        }
        _notice = $"{name} removed from the account.";
        await LoadAsync();
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
