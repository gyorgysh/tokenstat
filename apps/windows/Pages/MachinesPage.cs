// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Diagnostics;
using System.Linq;
using System.Text.Json.Nodes;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Tokenstat.Navigation;
using Windows.ApplicationModel.DataTransfer;

namespace Tokenstat.Pages;

/// <summary>
/// This PC, who may reach it, and who it can reach. Mirrors the Mac Devices
/// screen: approvals first, then the account devices, then this PC's own
/// connection settings, then the encryption note. Ordered by what somebody
/// came here to do: decide about a machine that is knocking, then read this
/// PC's own two words to compare with the other end, then add something new.
/// </summary>
internal sealed class MachinesPage : Page, IInspectorContent, IToolbarItems
{
    private readonly StackPanel _root = new() { Spacing = Theme.SpaceL };
    private readonly StackPanel _inspectorRoot = new()
    {
        Spacing = Theme.SpaceM,
        Padding = new Thickness(Theme.SpaceM),
    };

    private JsonNode? _account;
    private JsonNode? _identity;
    private JsonNode? _status;
    private JsonNode? _hostPolicy;
    private JsonArray _peers = new();
    private string? _notice;

    /// <summary>
    /// Devices asking this PC for something, both grants in arrival order.
    /// Each row carries its kind, from the method that answered, so neither
    /// host policy has to know the other exists.
    /// </summary>
    private List<(JsonNode Row, bool Screen)> _requests = new();
    private HashSet<string> _workspaceAllowed = new(StringComparer.Ordinal);
    private Dictionary<string, (bool View, bool Control)> _screenPermissions =
        new(StringComparer.Ordinal);
    private DispatcherQueueTimer? _poll;
    private bool _refreshing;
    private ScrollViewer? _scroll;

    /// <summary>
    /// What the inspector is showing. Keys only, so a refresh cannot pin a
    /// stale device value. Null means nothing is picked yet.
    /// </summary>
    private string? _selectedId;
    private string? _selectedPeer;
    private bool _selectThis;

    public MachinesPage(string? selectedId = null)
    {
        _selectedId = selectedId;
        _scroll = new ScrollViewer
        {
            Padding = new Thickness(Theme.SpaceM),
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            HorizontalScrollMode = ScrollMode.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Content = _root,
        };
        Content = _scroll;
        RefreshInspector();
        Loaded += async (_, _) =>
        {
            StartPoll();
            RemoteWorkspaces.Changed += OnRemoteChanged;
            await LoadAsync();
        };
        Unloaded += (_, _) =>
        {
            StopPoll();
            RemoteWorkspaces.Changed -= OnRemoteChanged;
        };
    }

    private void OnRemoteChanged()
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            Render();
            RefreshInspector();
        });
    }

    /// <summary>
    /// Keep the device list live while the screen is open, like the desktop
    /// Mac five-second refresh. A missed tick keeps the last rows.
    /// </summary>
    private void StartPoll()
    {
        StopPoll();
        _poll = DispatcherQueue.CreateTimer();
        _poll.Interval = TimeSpan.FromSeconds(5);
        _poll.Tick += (_, _) => _ = RefreshAsync();
        _poll.Start();
    }

    private void StopPoll()
    {
        _poll?.Stop();
        _poll = null;
    }

    private async Task RefreshAsync()
    {
        if (_refreshing)
        {
            return;
        }
        _refreshing = true;
        try
        {
            try
            {
                _status = await AppServices.Host.CallAsync("remote.status");
            }
            catch
            {
            }
            try
            {
                _peers = await AppServices.Host.CallAsync("machine.peers") as JsonArray ?? new();
            }
            catch
            {
            }
            try
            {
                var account = await AppServices.Host.CallAsync("account.status");
                if (account["signedIn"]?.GetValue<bool>() ?? false)
                {
                    _account = account;
                }
            }
            catch
            {
            }
            await LoadRequestsAsync();
            Render();
            _pairAllowed = RemoteReachAllowed(_account);
            RaiseToolbarChanged();
            RefreshInspector();
        }
        finally
        {
            _refreshing = false;
        }
    }

    /// <summary>
    /// The inspector column content. Selection and reloads replace its
    /// children, so the column stays live without the shell asking again.
    /// </summary>
    public UIElement? Inspector => _inspectorRoot;

    public event Action? ToolbarChanged;

    /// <summary>Global screen: no folder to name.</summary>
    public UIElement? ToolbarScope => null;

    /// <summary>
    /// The re-read, plus pairing once the account says remote reach is
    /// allowed, like the desktop Mac bar.
    /// </summary>
    public IList<UIElement> ToolbarActions()
    {
        var trailing = new List<UIElement>
        {
            Buttons.ToolbarIcon(
                ActionIcon.Refresh,
                "Re-read this PC and its devices",
                async (_, _) =>
                {
                    LogoRefresh.Began();
                    await LoadAsync();
                }),
        };
        if (_pairAllowed)
        {
            trailing.Add(Buttons.ToolbarIcon(
                ActionIcon.Create,
                "Paste a key from another device to pair it",
                async (_, _) => await PairAsync()));
        }
        return trailing;
    }

    private bool _pairAllowed;

    private void RaiseToolbarChanged() => ToolbarChanged?.Invoke();

    private async Task LoadAsync()
    {
        if (_root.Children.Count == 0)
        {
            _root.Children.Add(Motion.SkeletonCard());
        }
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
            _pairAllowed = false;
            RaiseToolbarChanged();
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
        try
        {
            _hostPolicy = await AppServices.Host.CallAsync("host.policy");
        }
        catch
        {
            _hostPolicy = null;
        }
        await LoadRequestsAsync();
        await LoadPermissionsAsync();

        Render();
        _pairAllowed = RemoteReachAllowed(account);
        RaiseToolbarChanged();
        RefreshInspector();
    }

    /// <summary>
    /// Both kinds of standing request, in one pass, so the queue is ordered
    /// by when somebody asked rather than by which policy answered first.
    /// </summary>
    private async Task LoadRequestsAsync()
    {
        var requests = new List<(JsonNode Row, bool Screen)>();
        try
        {
            var screen = await AppServices.Host.CallAsync("screen.access.pending") as JsonArray;
            if (screen is not null)
            {
                foreach (var row in screen.OfType<JsonNode>())
                {
                    requests.Add((row, true));
                }
            }
        }
        catch
        {
        }
        try
        {
            var workspace = await AppServices.Host.CallAsync("workspace.access.pending") as JsonArray;
            if (workspace is not null)
            {
                foreach (var row in workspace.OfType<JsonNode>())
                {
                    requests.Add((row, false));
                }
            }
        }
        catch
        {
        }
        requests.Sort((a, b) => Format.Long(a.Row, "askedAt").CompareTo(Format.Long(b.Row, "askedAt")));
        _requests = requests;
    }

    private async Task LoadPermissionsAsync()
    {
        try
        {
            var allowed = await AppServices.Host.CallAsync("workspace.access.list") as JsonArray;
            _workspaceAllowed = new HashSet<string>(StringComparer.Ordinal);
            if (allowed is not null)
            {
                foreach (var key in allowed)
                {
                    var peer = key?.GetValue<string>();
                    if (!string.IsNullOrEmpty(peer))
                    {
                        _workspaceAllowed.Add(peer);
                    }
                }
            }
        }
        catch
        {
        }
        try
        {
            var permissions = await AppServices.Host.CallAsync("screen.policy.list") as JsonArray;
            _screenPermissions = new(StringComparer.Ordinal);
            if (permissions is not null)
            {
                foreach (var row in permissions.OfType<JsonNode>())
                {
                    var peer = Format.Text(row, "peerId");
                    if (!string.IsNullOrEmpty(peer))
                    {
                        _screenPermissions[peer] = (Format.Flag(row, "view"), Format.Flag(row, "control"));
                    }
                }
            }
        }
        catch
        {
        }
    }

    /// <summary>
    /// Rebuild the content from the cached fetch. Selection calls this rather
    /// than LoadAsync, so picking a device does not re-read the daemon.
    /// </summary>
    private void Render()
    {
        // The five-second poll rebuilds these rows. Hold the scroll position
        // across the rebuild so the list does not jump back to the top.
        var offsetX = _scroll?.HorizontalOffset ?? 0;
        var offsetY = _scroll?.VerticalOffset ?? 0;
        void Restore() => DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low,
            () => _scroll?.ChangeView(offsetX, offsetY, null, true));
        _root.Children.Clear();
        if (!string.IsNullOrEmpty(_notice))
        {
            _root.Children.Add(Chrome.Banner(_notice, Theme.Accent, Symbol.Contact));
            _notice = null;
        }
        var account = _account;
        if (account is null)
        {
            Restore();
            return;
        }
        if (!(account["signedIn"]?.GetValue<bool>() ?? false))
        {
            _root.Children.Add(Chrome.Empty(
                "Sign in to see devices",
                "Devices live on the account, so a closed laptop still counts. Open Account in the sidebar to link this machine.",
                ActionIcon.Device));
            Restore();
            return;
        }

        var allowed = RemoteReachAllowed(account);
        if (allowed)
        {
            // Above pairing, because a device asking for either grant is
            // already paired: it got far enough to ask.
            if (_requests.Count > 0)
            {
                _root.Children.Add(WaitingForYouCard());
            }
            var pending = PendingPeers();
            if (pending.Count > 0)
            {
                _root.Children.Add(ApprovalCard(pending));
            }
            var reach = new FlowPanel { MinimumItemWidth = 340, Spacing = Theme.SpaceS };
            reach.Children.Add(ThisMachineCard(account, allowed, TunnelOn()));
            reach.Children.Add(AlwaysOnHostCard());
            _root.Children.Add(reach);
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
            var approved = ApprovedPeers();
            if (approved.Count > 0)
            {
                _root.Children.Add(DevicePermissionsCard(approved));
            }
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
            _root.Children.Add(AlwaysOnHostCard());
            var machines = account["machines"] as JsonArray;
            if (machines is not null && machines.Count > 0)
            {
                _root.Children.Add(LockedMachineList(account, machines));
            }
            _root.Children.Add(EncryptionNote());
        }
        Restore();
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
            actions.Children.Add(ActionIconGlyph.Button("Details", ActionIcon.Reveal, (_, _) =>
            {
                _selectThis = false;
                _selectedId = null;
                _selectedPeer = key;
                Render();
                RefreshInspector();
            }));
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

    private List<JsonNode> ApprovedPeers()
    {
        var self = SelfKey();
        var approved = new List<JsonNode>();
        foreach (var peer in _peers.OfType<JsonNode>())
        {
            if (Format.Text(peer, "trust") == "approved" && Format.Text(peer, "key") != self)
            {
                approved.Add(peer);
            }
        }
        return approved;
    }

    /// <summary>
    /// Devices that have asked for something and are still waiting. The same
    /// answers the desktop Mac offers, where somebody would go looking after
    /// a notification has gone. Being approved is not being let in: each of
    /// these is a separate yes from whoever is at this PC.
    /// </summary>
    private UIElement WaitingForYouCard()
    {
        var body = new StackPanel { Spacing = Theme.SpaceM };
        foreach (var (row, screen) in _requests)
        {
            var peerId = Format.Text(row, "peerId");
            var label = Format.Text(row, "label");
            var name = !string.IsNullOrEmpty(label)
                ? label
                : peerId.Length > 0
                    ? "Device " + peerId[..Math.Min(8, peerId.Length)]
                    : "An unknown device";
            var control = Format.Flag(row, "control");
            var line = new StackPanel { Spacing = Theme.SpaceS };
            line.Children.Add(new TextBlock
            {
                Text = screen ? $"{name} wants to see this screen" : $"{name} wants to open your work",
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                TextWrapping = TextWrapping.Wrap,
            });
            line.Children.Add(new TextBlock
            {
                Text = screen
                    ? control
                        ? "It asked for the picture, and for mouse and keyboard."
                        : "It asked for the picture only."
                    : "Folders, files, terminals and the agents running in them.",
                Opacity = 0.7,
                FontSize = 12,
                TextWrapping = TextWrapping.Wrap,
            });
            var actions = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = Theme.SpaceS,
            };
            var captured = row;
            if (screen)
            {
                // Both answers, always, for a screen. Offering only what the
                // device happened to ask for left no way to hand over the
                // mouse without making somebody go back to their phone.
                actions.Children.Add(ActionIconGlyph.Button(
                    "View only", ActionIcon.Preview, async (_, _) =>
                        await AnswerRequestAsync(captured, true, true, false, name)));
                actions.Children.Add(Buttons.Primary(
                    "Full access", ActionIcon.Approve, async (_, _) =>
                        await AnswerRequestAsync(captured, true, true, true, name)));
            }
            else
            {
                actions.Children.Add(Buttons.Primary(
                    "Allow", ActionIcon.Approve, async (_, _) =>
                        await AnswerRequestAsync(captured, false, true, false, name)));
            }
            actions.Children.Add(Buttons.Destructive(
                "Deny", ActionIcon.Revoke, async (_, _) =>
                    await AnswerRequestAsync(captured, screen, false, false, name)));
            line.Children.Add(actions);
            body.Children.Add(line);
        }
        return Chrome.Card(
            "Waiting for you",
            body,
            "Approve only a device you recognise. You can take it back below.");
    }

    private async Task AnswerRequestAsync(JsonNode row, bool screen, bool view, bool control, string name)
    {
        var peerId = Format.Text(row, "peerId");
        try
        {
            if (screen)
            {
                await AppServices.Host.CallAsync(
                    "screen.access.answer",
                    new JsonObject { ["peerId"] = peerId, ["view"] = view, ["control"] = control });
            }
            else
            {
                await AppServices.Host.CallAsync(
                    "workspace.access.set",
                    new JsonObject { ["peerId"] = peerId, ["allow"] = view });
            }
            _notice = !view
                ? $"{name} was not let in."
                : screen
                    ? control ? $"{name} can see this screen and drive it." : $"{name} can see this screen."
                    : $"{name} may now open your work.";
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
    /// Whether this PC stays a host after the app quits. Mirrors the Account
    /// screen's setting so it sits where somebody is deciding whether other
    /// devices may reach this PC.
    /// </summary>
    private UIElement AlwaysOnHostCard()
    {
        var body = new StackPanel { Spacing = Theme.SpaceM };
        if (_hostPolicy is null)
        {
            body.Children.Add(new TextBlock
            {
                Text = "The host helper has not answered yet.",
                Opacity = 0.7,
                TextWrapping = TextWrapping.Wrap,
            });
        }
        else
        {
            var alwaysOn = Format.Flag(_hostPolicy, "alwaysOn");
            var battery = Format.Flag(_hostPolicy, "hasInternalBattery");
            body.Children.Add(Chrome.SettingSwitch("Keep this PC reachable", alwaysOn, async on =>
            {
                try
                {
                    await AppServices.ApplyHostPolicyAsync(on);
                }
                catch (Exception ex)
                {
                    await LoadAsync();
                    _root.Children.Insert(0, Chrome.Banner(
                        FriendlyError.Display(ex.Message), Theme.Danger, Symbol.Important));
                    return;
                }
                _notice = on
                    ? "The host helper stays up after you quit."
                    : "The host helper stops when you quit.";
                await LoadAsync();
            }));
            body.Children.Add(new TextBlock
            {
                Text = alwaysOn
                    ? "The host helper keeps running after you quit tokenstat, so other devices can reach this PC. This PC will not idle-sleep. A laptop still sleeps when you close the lid."
                    : "The host helper stops when you quit tokenstat, so this PC can sleep. Other devices cannot open folders or terminals here until you open the app again.",
                Opacity = 0.7,
                FontSize = 12,
                TextWrapping = TextWrapping.Wrap,
            });
            if (alwaysOn && battery)
            {
                body.Children.Add(new TextBlock
                {
                    Text = "Uses more power.",
                    Opacity = 0.7,
                    FontSize = 12,
                });
            }
            if (!alwaysOn)
            {
                body.Children.Add(new TextBlock
                {
                    Text = "Automations run only while tokenstat is open.",
                    Opacity = 0.7,
                    FontSize = 12,
                });
            }
        }
        return Chrome.Card(
            "Always-on host",
            body,
            "Whether the host helper stays up after you quit");
    }

    /// <summary>
    /// What each paired device is allowed to do here. Being approved is not
    /// being let in, so reaching the work on this PC is its own switch, and
    /// it is first because it is the broadest of the three.
    /// </summary>
    private UIElement DevicePermissionsCard(List<JsonNode> peers)
    {
        var body = new StackPanel { Spacing = Theme.SpaceM };
        foreach (var peer in peers)
        {
            var key = Format.Text(peer, "key");
            var label = Format.Text(peer, "label");
            var name = string.IsNullOrEmpty(label) ? "Approved device" : label;
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
            var switches = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = Theme.SpaceM,
            };
            var captured = key;
            var screen = _screenPermissions.TryGetValue(key, out var held)
                ? held : (View: false, Control: false);
            switches.Children.Add(PermissionSwitch(
                "Workspaces", _workspaceAllowed.Contains(key), async on =>
                {
                    await AppServices.Host.CallAsync(
                        "workspace.access.set",
                        new JsonObject { ["peerId"] = captured, ["allow"] = on });
                    if (on)
                    {
                        _workspaceAllowed.Add(captured);
                    }
                    else
                    {
                        _workspaceAllowed.Remove(captured);
                    }
                }));
            var viewSwitch = PermissionSwitch("View", screen.View, async on =>
            {
                var control = on && _screenPermissions.TryGetValue(captured, out var current) && current.Control;
                await AppServices.Host.CallAsync(
                    "screen.policy.set",
                    new JsonObject { ["peerId"] = captured, ["view"] = on, ["control"] = control });
                _screenPermissions[captured] = (on, control);
            });
            switches.Children.Add(viewSwitch);
            var controlSwitch = PermissionSwitch("Control", screen.Control, async on =>
            {
                await AppServices.Host.CallAsync(
                    "screen.policy.set",
                    new JsonObject { ["peerId"] = captured, ["view"] = true, ["control"] = on });
                _screenPermissions[captured] = (true, on);
            });
            controlSwitch.IsEnabled = screen.View;
            ToolTipService.SetToolTip(controlSwitch, "Control requires screen viewing access");
            switches.Children.Add(controlSwitch);
            row.Children.Add(switches);
            body.Children.Add(row);
        }
        body.Children.Add(new TextBlock
        {
            Text = "Control requires View. Devices can also request access; pending requests appear at the top of this page.",
            Opacity = 0.7,
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
        });
        return Chrome.Card(
            "Device permissions",
            body,
            "Choose what each approved device can access on this PC");
    }

    private ToggleSwitch PermissionSwitch(string title, bool isOn, Func<bool, Task> set)
    {
        var toggle = new ToggleSwitch
        {
            Header = title,
            IsOn = isOn,
            OnContent = "",
            OffContent = "",
        };
        var reverting = false;
        toggle.Toggled += async (_, _) =>
        {
            if (reverting)
            {
                return;
            }
            try
            {
                await set(toggle.IsOn);
            }
            catch (Exception ex)
            {
                reverting = true;
                toggle.IsOn = !toggle.IsOn;
                reverting = false;
                _root.Children.Insert(0, Chrome.Banner(
                    FriendlyError.Display(ex.Message), Theme.Danger, Symbol.Important));
                return;
            }
            Render();
            RefreshInspector();
        };
        return toggle;
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
            actions.Children.Add(ActionIconGlyph.Button("Details", ActionIcon.Reveal, (_, _) =>
            {
                _selectThis = false;
                _selectedId = null;
                _selectedPeer = key;
                Render();
                RefreshInspector();
            }));
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
        var list = new FlowPanel { Spacing = Theme.SpaceM, MinimumItemWidth = 280 };
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
                Text = StatusLine(machine, isSelf),
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
        body.Children.Add(Chrome.SettingSwitch("Enable remote access", allowed && tunnel, async on =>
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
                await LoadAsync();
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
                _selectedPeer = null;
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
    /// One caption line under a machine's name. The presence light is the
    /// quick read; this carries the detail, and the two never collide.
    /// Matches the desktop Mac wording.
    /// </summary>
    private string StatusLine(JsonNode? machine, bool isSelf)
    {
        if (isSelf)
        {
            return "This device";
        }
        var isHost = Format.Text(machine, "kind") != "client";
        if (!isHost)
        {
            // A phone holds the tunnel only while somebody is using it, so
            // "offline" here means "not in the app right now", not "broken".
            if (MachineOnline(machine) == true)
            {
                return "Phone · in the app now";
            }
            var used = RelativeOrNull(Format.Text(machine, "lastSeenAt"));
            if (used is not null)
            {
                return "Phone · last used " + used;
            }
            return "Phone · signed in on this account";
        }
        if (string.IsNullOrEmpty(Format.Text(machine, "publicIdentity")))
        {
            return "No connection key yet";
        }
        if (MachineOnline(machine) == false)
        {
            var seen = RelativeOrNull(Format.Text(machine, "lastSeenAt"));
            return seen is null ? "Offline" : "Offline · last seen " + seen;
        }
        var peer = PeerForMachine(machine);
        if (peer is not null && RemoteWorkspaces.IsConnected(Format.Text(peer, "key")))
        {
            return "Connected · workspaces in sidebar";
        }
        var lastSeen = RelativeOrNull(Format.Text(machine, "lastSeenAt"));
        if (lastSeen is not null)
        {
            return "Seen " + lastSeen;
        }
        var synced = RelativeOrNull(Format.Text(machine, "lastSyncAt"));
        if (synced is not null)
        {
            return "Last synced " + synced;
        }
        return "No sync recorded";
    }

    private static bool? MachineOnline(JsonNode? machine)
    {
        try
        {
            return machine?["online"]?.GetValue<bool?>();
        }
        catch
        {
            return null;
        }
    }

    private static string? RelativeOrNull(string value) =>
        string.IsNullOrEmpty(value) ? null : Format.Relative(value);

    /// <summary>
    /// Keep Connect available for other computers. Presence can lag behind
    /// wake or sign-in; an explicit attempt reports the actual result.
    /// </summary>
    private bool CanConnect(JsonNode? machine)
    {
        var thisId = Format.Text(_account, "thisMachineId");
        if (!string.IsNullOrEmpty(thisId) && MachineId(machine) == thisId)
        {
            return false;
        }
        if (!string.IsNullOrEmpty(SelfKey()) && Format.Text(machine, "publicIdentity") == SelfKey())
        {
            return false;
        }
        // Presence can lag after wake/sign-in. Keep the explicit action
        // available; the connection result explains any unmet prerequisite.
        return Format.Text(machine, "kind") != "client";
    }

    /// <summary>
    /// The presence light before a machine's name: solid when reachable,
    /// grey when offline, amber while its state is not confirmed yet.
    /// </summary>
    private static Border PresenceDot(bool? online, bool isSelf, bool tunnelUp)
    {
        var color = isSelf
            ? tunnelUp ? Theme.Success : Theme.StateIdle
            : online == true ? Theme.Success : online == false ? Theme.StateIdle : Theme.Warning;
        return new Border
        {
            Width = 8,
            Height = 8,
            CornerRadius = new CornerRadius(4),
            Background = Theme.Brush(color),
            VerticalAlignment = VerticalAlignment.Center,
        };
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
        head.Children.Add(Marks.Device(Format.Text(machine, "platform"), Format.Text(machine, "kind") == "client"));
        head.Children.Add(PresenceDot(
            MachineOnline(machine), isSelf, _status?["tunnelOnline"]?.GetValue<bool>() ?? false));
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
            Text = StatusLine(machine, isSelf),
            Opacity = 0.7,
            FontSize = 12,
        });

        var key = Format.Text(machine, "publicIdentity");
        var isHost = Format.Text(machine, "kind") != "client";
        var linked = PeerForMachine(machine);
        if (isHost && !isSelf && linked is not null)
        {
            body.Children.Add(AutoConnectRow(linked, machine));
        }
        var actions = new FlowPanel
        {
            Spacing = Theme.SpaceS,
        };
        if (isHost && !isSelf)
        {
            AddConnectionActions(actions, machine, linked, title);
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
            body.Children.Add(new TextBlock
            {
                TextWrapping = TextWrapping.Wrap,
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
            _selectedPeer = null;
            _selectedId = id;
            Render();
            RefreshInspector();
        }));
        body.Children.Add(actions);

        var selected = !_selectThis && _selectedPeer is null && _selectedId == id;
        var card = new Border
        {
            Child = body,
            Padding = new Thickness(Theme.SpaceS),
            CornerRadius = new CornerRadius(8),
            Background = selected ? Theme.AccentSoftBrush : Theme.Brush(Microsoft.UI.Colors.Transparent),
            BorderBrush = selected ? Theme.AccentBrush : Theme.BorderBrush,
            BorderThickness = new Thickness(1),
        };
        card.Tapped += (_, e) =>
        {
            for (var source = e.OriginalSource as DependencyObject; source is not null && source != card;
                 source = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(source))
                if (source is Microsoft.UI.Xaml.Controls.Primitives.ButtonBase or ToggleSwitch) return;
            _selectThis = false;
            _selectedPeer = null;
            _selectedId = id;
            Render();
            RefreshInspector();
        };
        return card;
    }

    /// <summary>
    /// Connect, or the peer trust action the row needs first. Phones are
    /// shown but never dialled: a client reaches a host, not the reverse.
    /// </summary>
    private void AddConnectionActions(
        Panel actions, JsonNode? machine, JsonNode? peer, string title)
    {
        var key = Format.Text(machine, "publicIdentity");
        if (peer is not null)
        {
            var peerKey = Format.Text(peer, "key");
            var peerLabel = Format.Text(peer, "label");
            var name = string.IsNullOrEmpty(peerLabel) ? title : peerLabel;
            if (RemoteWorkspaces.IsConnected(peerKey))
            {
                actions.Children.Add(ActionIconGlyph.Button(
                    "Disconnect", ActionIcon.Disconnect, async (_, _) =>
                        await DisconnectPeerAsync(peerKey, name)));
                return;
            }
            switch (Format.Text(peer, "trust"))
            {
                case "pending":
                    actions.Children.Add(Buttons.Primary(
                        "Approve", ActionIcon.Approve, async (_, _) =>
                            await ApproveAsync(peerKey, name)));
                    break;
                case "approved":
                    if (CanConnect(machine))
                    {
                        actions.Children.Add(Buttons.Primary(
                            "Connect", ActionIcon.Connect, async (_, _) =>
                                await ConnectPeerAsync(peerKey, name, MachineOnline(machine))));
                    }
                    actions.Children.Add(ActionIconGlyph.Button(
                        "Revoke", ActionIcon.Revoke, async (_, _) =>
                            await ConfirmRevokeAsync(peerKey, name)));
                    break;
                default:
                    actions.Children.Add(ActionIconGlyph.Button(
                        "Approve", ActionIcon.Approve, async (_, _) =>
                            await ApproveAsync(peerKey, name)));
                    break;
            }
            return;
        }
        if (!string.IsNullOrEmpty(key) && CanConnect(machine))
        {
            var captured = machine;
            actions.Children.Add(Buttons.Primary(
                "Connect", ActionIcon.Connect, async (_, _) =>
                    await ConnectMachineAsync(captured)));
        }
    }

    /// <summary>
    /// Whether the sweep dials this machine on its own, beside the connection
    /// itself. Off stops the dialling and leaves a live connection alone;
    /// only Disconnect drops it.
    /// </summary>
    private UIElement AutoConnectRow(JsonNode peer, JsonNode? machine)
    {
        var peerKey = Format.Text(peer, "key");
        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Theme.SpaceS,
        };
        row.Children.Add(new TextBlock
        {
            Text = "Auto-connect",
            FontSize = 12,
            Opacity = 0.7,
            VerticalAlignment = VerticalAlignment.Center,
        });
        var toggle = new ToggleSwitch
        {
            IsOn = RemoteWorkspaces.IsAutoConnectEnabled(peerKey),
            OnContent = "",
            OffContent = "",
            VerticalAlignment = VerticalAlignment.Center,
        };
        ToolTipService.SetToolTip(toggle, "Auto-connect " + Format.Text(peer, "label", "this device"));
        toggle.Toggled += (_, _) => SetAutoConnect(toggle.IsOn, peerKey, machine);
        row.Children.Add(toggle);
        return row;
    }

    private async Task ConnectPeerAsync(string peerKey, string name, bool? online)
    {
        var result = await RemoteWorkspaces.ConnectAsync(peerKey, name, TunnelOn(), online);
        if (result.IsNotice || result.Connected)
        {
            _notice = result.Message;
        }
        else
        {
            _root.Children.Insert(0, Chrome.Banner(
                result.Message, Theme.Danger, Symbol.Important));
            return;
        }
        await LoadAsync();
    }

    /// <summary>
    /// Connect to a machine that belongs to this account. The account record
    /// carries the public key, so this pins the identity and dials without
    /// anybody copying or comparing anything.
    /// </summary>
    private async Task ConnectMachineAsync(JsonNode? machine)
    {
        var key = Format.Text(machine, "publicIdentity");
        var title = DeviceTitle(machine);
        if (string.IsNullOrEmpty(key))
        {
            _root.Children.Insert(0, Chrome.Banner(
                $"{title} has no connection key on this account record yet. Open the Devices screen on that device so it registers one, then try again.",
                Theme.Warning,
                Symbol.Important));
            return;
        }
        if (key == SelfKey())
        {
            return;
        }
        try
        {
            await AppServices.Host.CallAsync(
                "machine.pair",
                new JsonObject { ["key"] = key, ["label"] = title });
            _peers = await AppServices.Host.CallAsync("machine.peers") as JsonArray ?? new();
        }
        catch (Exception ex)
        {
            _root.Children.Insert(0, Chrome.Banner(
                FriendlyError.Display(ex.Message), Theme.Danger, Symbol.Important));
            return;
        }
        var peer = PeerForMachine(machine);
        var peerKey = peer is null ? key : Format.Text(peer, "key");
        await ConnectPeerAsync(peerKey, title, MachineOnline(machine));
    }

    private async Task DisconnectPeerAsync(string peerKey, string name)
    {
        RemoteWorkspaces.Disconnect(peerKey);
        // Revoke ends trust and any workspace listing for this peer. Leaving
        // Connected set after revoke made the row offer Disconnect for a
        // machine that could no longer answer. Disconnect itself keeps trust:
        // it only drops the folders from the sidebar.
        _notice = $"Disconnected from {name}. Its workspaces are no longer in the sidebar.";
        await LoadAsync();
    }

    private void SetAutoConnect(bool on, string peerKey, JsonNode? machine)
    {
        RemoteWorkspaces.SetAutoConnect(on, peerKey);
        if (on)
        {
            if (machine is not null && !CanConnect(machine))
            {
                // The sweep picks it up when it wakes, which is what the
                // switch promises. Without a machine record there is no
                // reachability to check, so the dial reports honestly.
                Render();
                RefreshInspector();
                return;
            }
            _ = ConnectPeerAsync(peerKey, Format.Text(PeerByKey(peerKey), "label"), null);
            return;
        }
        Render();
        RefreshInspector();
    }

    private JsonNode? PeerByKey(string key)
    {
        foreach (var peer in _peers.OfType<JsonNode>())
        {
            if (Format.Text(peer, "key") == key)
            {
                return peer;
            }
        }
        return null;
    }

    private string _inspectorKey = "";

    /// <summary>
    /// What the inspector shows, fingerprinted: the selection, the fetched
    /// state it reads, and the per-peer connection switches it also reads.
    /// The five-second poll calls RefreshInspector every pass; an unchanged
    /// key skips the rebuild so the column stops flickering.
    /// </summary>
    private string InspectorKey()
    {
        var peerKey = _selectedPeer;
        if (peerKey is null && FindMachine(_selectedId) is JsonNode machine
            && PeerForMachine(machine) is JsonNode linked)
        {
            peerKey = Format.Text(linked, "key");
        }
        var connected = peerKey is not null && RemoteWorkspaces.IsConnected(peerKey);
        var auto = peerKey is null || RemoteWorkspaces.IsAutoConnectEnabled(peerKey);
        return string.Join(
            "|",
            _selectThis,
            _selectedId ?? "",
            _selectedPeer ?? "",
            _identity?.ToJsonString() ?? "",
            _status?.ToJsonString() ?? "",
            _peers.ToJsonString(),
            _account?.ToJsonString() ?? "",
            connected,
            auto);
    }

    private void RefreshInspector()
    {
        var key = InspectorKey();
        if (key == _inspectorKey && _inspectorRoot.Children.Count > 0)
        {
            return;
        }
        _inspectorKey = key;
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
        if (_selectedPeer is not null && PeerByKey(_selectedPeer) is JsonNode peer)
        {
            PeerInspector(peer);
            return;
        }
        var machine = FindMachine(_selectedId);
        if (machine is null)
        {
            _inspectorRoot.Children.Add(Chrome.InspectorField(
                "Device", "Pick a device", "Connection details and actions appear here."));
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
        body.Children.Add(HostStatsCard(null));
        body.Children.Add(HostUpdateCard(null, local: true));
        _inspectorRoot.Children.Add(body);
    }

    private void PeerInspector(JsonNode peer)
    {
        var key = Format.Text(peer, "key");
        var label = Format.Text(peer, "label");
        var name = string.IsNullOrEmpty(label) ? "Unnamed device" : label;
        var body = new StackPanel { Spacing = Theme.SpaceM };
        body.Children.Add(new TextBlock
        {
            Text = name,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
        });
        var words = Format.Text(peer, "words");
        if (!string.IsNullOrEmpty(words))
        {
            body.Children.Add(Labeled("Known as", words));
        }
        body.Children.Add(Labeled("Trust", TrustLabel(Format.Text(peer, "trust"))));
        var connected = RemoteWorkspaces.IsConnected(key);
        if (connected)
        {
            body.Children.Add(new TextBlock
            {
                Text = "Workspaces from this device are in the sidebar.",
                Opacity = 0.7,
                FontSize = 12,
                TextWrapping = TextWrapping.Wrap,
            });
            body.Children.Add(HostStatsCard(key));
            body.Children.Add(HostUpdateCard(key, local: false));
        }
        var actions = new StackPanel { Spacing = Theme.SpaceS };
        if (Format.Text(peer, "trust") == "approved")
        {
            if (connected)
            {
                actions.Children.Add(ActionIconGlyph.Button(
                    "Disconnect", ActionIcon.Disconnect, async (_, _) =>
                        await DisconnectPeerAsync(key, name)));
            }
            else
            {
                actions.Children.Add(Buttons.Primary(
                    "Connect", ActionIcon.Connect, async (_, _) =>
                        await ConnectPeerAsync(key, name, online: null)));
            }
            actions.Children.Add(AutoConnectRow(peer, machine: null));
            actions.Children.Add(ActionIconGlyph.Button(
                "Revoke", ActionIcon.Revoke, async (_, _) =>
                    await ConfirmRevokeAsync(key, name)));
        }
        else
        {
            actions.Children.Add(Buttons.Primary(
                "Approve", ActionIcon.Approve, async (_, _) =>
                    await ApproveAsync(key, name)));
        }
        actions.Children.Add(ActionIconGlyph.Button(
            "Forget", ActionIcon.Delete, async (_, _) =>
                await ConfirmForgetAsync(key, name)));
        body.Children.Add(actions);
        _inspectorRoot.Children.Add(body);
    }

    private static string TrustLabel(string trust) => trust switch
    {
        "pending" => "Waiting for approval",
        "approved" => "Approved",
        "revoked" => "Revoked",
        _ => trust,
    };

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
        body.Children.Add(Labeled("Status", StatusLine(machine, isSelf)));
        var words = Format.Text(PeerForMachine(machine), "words");
        if (!string.IsNullOrEmpty(words))
        {
            body.Children.Add(Labeled("Known as", words));
        }
        var actions = new StackPanel { Spacing = Theme.SpaceS };
        var isHost = Format.Text(machine, "kind") != "client";
        var peerKey = Format.Text(machine, "publicIdentity");
        if (isSelf)
        {
            body.Children.Add(new TextBlock
            {
                Text = "This device.",
                Opacity = 0.7,
                TextWrapping = TextWrapping.Wrap,
            });
            body.Children.Add(HostStatsCard(null));
            body.Children.Add(HostUpdateCard(null, local: true));
        }
        else if (PeerForMachine(machine) is JsonNode linked)
        {
            var linkedKey = Format.Text(linked, "key");
            var linkedName = Format.Text(linked, "label");
            var name = string.IsNullOrEmpty(linkedName) ? title : linkedName;
            if (MachineOnline(machine) == true && !string.IsNullOrEmpty(peerKey))
            {
                body.Children.Add(HostStatsCard(peerKey));
                body.Children.Add(HostUpdateCard(peerKey, local: false));
            }
            if (RemoteWorkspaces.IsConnected(linkedKey))
            {
                actions.Children.Add(ActionIconGlyph.Button(
                    "Disconnect", ActionIcon.Disconnect, async (_, _) =>
                        await DisconnectPeerAsync(linkedKey, name)));
            }
            else
            {
                actions.Children.Add(Buttons.Primary(
                    "Connect", ActionIcon.Connect, async (_, _) =>
                        await ConnectPeerAsync(linkedKey, name, MachineOnline(machine))));
            }
            actions.Children.Add(AutoConnectRow(linked, machine));
        }
        else if (CanConnect(machine))
        {
            if (MachineOnline(machine) == true && !string.IsNullOrEmpty(peerKey))
            {
                body.Children.Add(HostStatsCard(peerKey));
            }
            actions.Children.Add(Buttons.Primary(
                "Connect", ActionIcon.Connect, async (_, _) =>
                    await ConnectMachineAsync(machine)));
        }
        if (isHost && !isSelf)
        {
            var deviceName = title;
            actions.Children.Add(ActionIconGlyph.Button(
                "View screen", ActionIcon.Preview, (_, _) =>
                {
                    var open = AppServices.OpenScreen;
                    if (string.IsNullOrEmpty(peerKey) || open is null)
                    {
                        _notice = "Open Devices on that computer so it registers its connection key, then refresh this list.";
                        _ = LoadAsync();
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

    /// <summary>
    /// Compact power, CPU and memory for a machine, filled after the read
    /// lands. Peer set: ask that host. Peer null: this PC. Missing readings
    /// stay off the bar rather than drawing as zero.
    /// </summary>
    private UIElement HostStatsCard(string? peerKey)
    {
        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Theme.SpaceM,
        };
        row.Children.Add(new TextBlock
        {
            Text = "…",
            Opacity = 0.5,
        });
        _ = FillHostStatsAsync(row, peerKey);
        return row;
    }

    private static async Task FillHostStatsAsync(StackPanel row, string? peerKey)
    {
        JsonNode? stats = null;
        try
        {
            stats = peerKey is null
                ? await AppServices.Host.CallAsync("host.stats")
                : await RemoteWorkspaces.CallOnPeerAsync(peerKey, "host.stats");
        }
        catch
        {
        }
        row.Children.Clear();
        if (stats is null)
        {
            row.Children.Add(Chrome.InspectorField("Power", "n/a"));
            row.Children.Add(Chrome.InspectorField("CPU", "n/a"));
            return;
        }
        row.Children.Add(Chrome.InspectorField("Power", PowerLabel(stats)));
        if (stats["cpu"] is not null)
        {
            row.Children.Add(Chrome.InspectorField("CPU", CpuLabel(Format.Number(stats, "cpu"))));
        }
        if (stats["ramTotalBytes"] is not null)
        {
            row.Children.Add(Chrome.InspectorField(
                "Memory",
                RamLabel(Format.Long(stats, "ramUsedBytes"), Format.Long(stats, "ramTotalBytes"))));
        }
    }

    private static string PowerLabel(JsonNode stats)
    {
        var charging = Format.Flag(stats, "charging");
        var percent = stats["percent"] is null ? (long?)null : Format.Long(stats, "percent");
        if (charging && percent.HasValue)
        {
            return $"{percent}%";
        }
        if (Format.Text(stats, "power") == "ac" && !percent.HasValue)
        {
            return "Plugged in";
        }
        if (percent.HasValue)
        {
            return $"{percent}%";
        }
        if (Format.Text(stats, "power") == "battery")
        {
            return "On battery";
        }
        if (Format.Text(stats, "power") == "ac")
        {
            return "Plugged in";
        }
        return "n/a";
    }

    private static string CpuLabel(double cpu) => $"{(int)Math.Round(cpu * 100)}%";

    private static string RamLabel(long used, long total)
    {
        const double g = 1024d * 1024 * 1024;
        var u = used / g;
        var t = total / g;
        return t >= 10 ? $"{u:0} / {t:0} GB" : $"{u:0.0} / {t:0.0} GB";
    }

    /// <summary>
    /// The host release on this PC or on a peer, with Install and Restart
    /// where they do something. Matches the desktop Mac Software card.
    /// </summary>
    private UIElement HostUpdateCard(string? peerKey, bool local)
    {
        var body = new StackPanel { Spacing = Theme.SpaceS };
        body.Children.Add(new TextBlock
        {
            Text = "Software",
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        var state = new StackPanel { Spacing = Theme.SpaceS };
        body.Children.Add(state);
        _ = FillHostUpdateAsync(state, peerKey, local);
        return body;
    }

    private static async Task FillHostUpdateAsync(StackPanel state, string? peerKey, bool local)
    {
        state.Children.Clear();
        state.Children.Add(new TextBlock
        {
            Text = "Looking for a newer release",
            Opacity = 0.7,
            FontSize = 12,
        });
        JsonNode? check = null;
        try
        {
            check = peerKey is null
                ? await AppServices.Host.CallAsync("host.updateCheck")
                : await RemoteWorkspaces.CallOnPeerAsync(peerKey, "host.updateCheck");
        }
        catch (Exception ex)
        {
            state.Children.Clear();
            state.Children.Add(new TextBlock
            {
                Text = FriendlyError.Display(ex.Message),
                Foreground = Theme.Brush(static () => Theme.Danger),
                FontSize = 12,
                TextWrapping = TextWrapping.Wrap,
            });
            state.Children.Add(ActionIconGlyph.Button(
                "Check again", ActionIcon.Refresh, async (_, _) =>
                    await FillHostUpdateAsync(state, peerKey, local)));
            return;
        }
        state.Children.Clear();
        var version = Format.Text(check, "hostVersion");
        var latest = Format.Text(check, "latest");
        var newer = Format.Flag(check, "newer");
        var restartPending = Format.Flag(check, "restartPending");
        var canRestart = Format.Flag(check, "canRestart");
        var appManaged = Format.Flag(check, "appManaged");
        var autoApply = Format.Flag(check, "autoApply");
        state.Children.Add(new TextBlock
        {
            Text = restartPending
                ? $"Running {version}"
                : newer ? $"{version} → {latest}" : version,
            FontFamily = Fonts.Mono,
            FontSize = 12,
        });
        if (restartPending)
        {
            state.Children.Add(UpdateNote(
                local ? "Installed. Restart the helper to use it." : "Installed. Restart it there to use it."));
        }
        else if (newer)
        {
            state.Children.Add(UpdateNote($"Version {latest} is available."));
        }
        else
        {
            state.Children.Add(UpdateNote("Up to date."));
        }
        if (appManaged)
        {
            state.Children.Add(UpdateNote(
                local
                    ? "The tokenstat application owns this helper and replaces it when it updates itself."
                    : "The tokenstat application there owns its helper and replaces it when it updates itself."));
        }
        else
        {
            if (newer && !canRestart)
            {
                state.Children.Add(UpdateNote(
                    "It installs but cannot restart itself, so it keeps running the version it started with until it is restarted."));
            }
            if (autoApply)
            {
                state.Children.Add(UpdateNote("Checks daily on its own."));
            }
        }
        var actions = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Theme.SpaceS,
        };
        if (restartPending)
        {
            // The only thing left is the restart, and it ends whatever that
            // machine is running, so it is never automatic here.
            if (canRestart)
            {
                actions.Children.Add(Buttons.Primary(
                    "Restart", ActionIcon.Refresh, async (_, _) =>
                        await ApplyHostUpdateAsync(state, peerKey, local, restartNow: true)));
            }
        }
        else if (newer && !appManaged)
        {
            actions.Children.Add(Buttons.Primary(
                "Install", ActionIcon.Download, async (_, _) =>
                    await ApplyHostUpdateAsync(state, peerKey, local, restartNow: false)));
        }
        else if (appManaged && newer)
        {
            actions.Children.Add(Buttons.Primary(
                local ? "Download" : "Fetch", ActionIcon.Download, async (_, _) =>
                    await ApplyHostUpdateAsync(state, peerKey, local, restartNow: false)));
        }
        actions.Children.Add(ActionIconGlyph.Button(
            "Check again", ActionIcon.Refresh, async (_, _) =>
                await FillHostUpdateAsync(state, peerKey, local)));
        state.Children.Add(actions);
    }

    private static async Task ApplyHostUpdateAsync(
        StackPanel state, string? peerKey, bool local, bool restartNow)
    {
        state.Children.Clear();
        state.Children.Add(new TextBlock
        {
            Text = "Downloading, checking and installing. This takes a minute.",
            Opacity = 0.7,
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
        });
        JsonNode? applied;
        try
        {
            var parameters = new JsonObject { ["restartNow"] = restartNow };
            applied = peerKey is null
                ? await AppServices.Host.CallAsync("host.updateApply", parameters)
                : await RemoteWorkspaces.CallOnPeerAsync(peerKey, "host.updateApply", parameters);
        }
        catch (Exception ex)
        {
            state.Children.Clear();
            state.Children.Add(new TextBlock
            {
                Text = FriendlyError.Display(ex.Message),
                Foreground = Theme.Brush(static () => Theme.Danger),
                FontSize = 12,
                TextWrapping = TextWrapping.Wrap,
            });
            state.Children.Add(ActionIconGlyph.Button(
                "Check again", ActionIcon.Refresh, async (_, _) =>
                    await FillHostUpdateAsync(state, peerKey, local)));
            return;
        }
        state.Children.Clear();
        var detail = Format.Text(applied, "detail");
        if (!string.IsNullOrEmpty(detail))
        {
            state.Children.Add(UpdateNote(detail));
        }
        else if (Format.Flag(applied, "restarting"))
        {
            var to = Format.Text(applied, "to", "the new version");
            state.Children.Add(UpdateNote(
                $"Installed {to}. Restarting on it now, so this may go quiet for a moment."));
        }
        else if (!string.IsNullOrEmpty(Format.Text(applied, "appImage"))
            && Format.Flag(applied, "appManaged"))
        {
            state.Children.Add(UpdateNote("The application's download is ready on that machine."));
        }
        else
        {
            state.Children.Add(UpdateNote(
                local ? "Installed. Restart the helper to use it." : "Installed. Restart it there to use it."));
        }
        if (Format.Flag(applied, "restartPending") && Format.Flag(applied, "canRestart"))
        {
            state.Children.Add(Buttons.Primary(
                "Restart", ActionIcon.Refresh, async (_, _) =>
                    await ApplyHostUpdateAsync(state, peerKey, local, restartNow: true)));
        }
        state.Children.Add(ActionIconGlyph.Button(
            "Check again", ActionIcon.Refresh, async (_, _) =>
                await FillHostUpdateAsync(state, peerKey, local)));
    }

    private static TextBlock UpdateNote(string text) => new()
    {
        Text = text,
        Opacity = 0.7,
        FontSize = 12,
        TextWrapping = TextWrapping.Wrap,
    };

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
        var address = addressBox.Text.Trim();
        if (string.IsNullOrEmpty(address))
        {
            // A live invite is key@host:port. Split at the last @; a bare
            // key has no address, which is right for a machine that only
            // ever connects to this one.
            var at = key.LastIndexOf('@');
            if (at > 0 && at + 1 < key.Length)
            {
                address = key[(at + 1)..].Trim();
                key = key[..at].Trim();
            }
        }
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
                    ["address"] = address,
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
            // Revoke ends trust and any workspace listing for this peer.
            RemoteWorkspaces.Disconnect(key);
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
