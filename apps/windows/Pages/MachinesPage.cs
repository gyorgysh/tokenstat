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
/// screen: approvals first, then this PC's connection settings and account
/// devices, then the encryption note. Ordered by what somebody
/// came here to do: decide about a machine that is knocking, then read this
/// PC's own two words to compare with the other end, then add something new.
/// </summary>
internal sealed class MachinesPage : Page, IInspectorContent, IInspectorRequest, IToolbarItems
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
    private enum DevicePage { Devices, Access }
    private DevicePage _devicePage;
    private readonly TextBox _deviceSearch = new() { PlaceholderText = L10n.Text("windows.machinespage.search_devices.3aebaefc"), MinHeight = 36 };
    private readonly StackPanel _deviceInventory = new() { Spacing = Theme.SpaceM };
    private ScrollViewer? _scroll;
    private readonly StackPanel _signSlot = new() { Spacing = Theme.SpaceM, Visibility = Visibility.Collapsed };

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
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_deviceSearch, L10n.Text("windows.machinespage.search_devices.3aebaefc"));
        _deviceSearch.TextChanged += (_, _) => RenderDeviceInventory();
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
        var previousStatus = _status;
        var previousPeers = _peers;
        var previousAccount = _account;
        var previousRequests = _requests;
        var previousWorkspaceAllowed = _workspaceAllowed;
        var previousScreenPermissions = _screenPermissions;
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
                _account = await AppServices.Host.CallAsync("account.status");
                if (!(_account?["signedIn"]?.GetValue<bool>() ?? false))
                {
                    _selectedId = null;
                    _selectedPeer = null;
                    _selectThis = false;
                }
            }
            catch
            {
            }
            await LoadRequestsAsync();
            await LoadPermissionsAsync();
            var changed = !JsonNode.DeepEquals(DevicePresentation.ConnectionState(previousStatus),
                    DevicePresentation.ConnectionState(_status))
                || !JsonNode.DeepEquals(previousPeers, _peers)
                || !JsonNode.DeepEquals(previousAccount, _account)
                || !previousWorkspaceAllowed.SetEquals(_workspaceAllowed)
                || previousScreenPermissions.Count != _screenPermissions.Count
                || previousScreenPermissions.Any(pair => !_screenPermissions.TryGetValue(pair.Key, out var current)
                    || current != pair.Value)
                || previousRequests.Count != _requests.Count
                || previousRequests.Where((row, index) => index < _requests.Count
                    && (row.Screen != _requests[index].Screen || !JsonNode.DeepEquals(row.Row, _requests[index].Row))).Any();
            if (changed)
            {
                Render();
                _pairAllowed = RemoteReachAllowed(_account);
                RaiseToolbarChanged();
                RefreshInspector();
            }
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
    public event Action? DetailsRequested;

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
                L10n.Text("windows.machinespage.re_read_this_pc_and_its_devices.baa9a7c3"),
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
                L10n.Text("windows.machinespage.paste_a_key_from_another_device_to_pair_it.1a851164"),
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
        var searchFocus = _deviceSearch.FocusState;
        var searchStart = _deviceSearch.SelectionStart;
        var searchLength = _deviceSearch.SelectionLength;
        void Restore() => DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, () =>
        {
            if (searchFocus != FocusState.Unfocused && _devicePage == DevicePage.Devices && _deviceSearch.IsLoaded)
            {
                _deviceSearch.Focus(searchFocus);
                _deviceSearch.Select(searchStart, searchLength);
            }
            _scroll?.ChangeView(offsetX, offsetY, null, true);
        });
        _root.Children.Clear();
        if (!string.IsNullOrEmpty(_notice))
        {
            _root.Children.Add(Chrome.Banner(_notice, Theme.Accent, Symbol.Contact));
            _notice = null;
        }
        // Keep an active sign-in visible across device tabs and refreshes.
        _root.Children.Add(_signSlot);
        var account = _account;
        if (account is null)
        {
            Restore();
            return;
        }
        if (!(account["signedIn"]?.GetValue<bool>() ?? false))
        {
            _root.Children.Add(Chrome.Empty(
                L10n.Text("windows.machinespage.sign_in_to_see_devices.5e009c71"),
                L10n.Text("windows.machinespage.devices_live_on_the_account_so_a_closed_la.2f29b3f0"),
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
            var navigation = new Grid { ColumnSpacing = Theme.SpaceM };
            navigation.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            navigation.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var sections = Chrome.Segmented(
                [(nameof(DevicePage.Devices), L10n.Text("common.devices")),
                    (nameof(DevicePage.Access), L10n.Text("windows.machinespage.access_tab"))],
                _devicePage.ToString(), section =>
                {
                    _devicePage = Enum.Parse<DevicePage>(section);
                    Render();
                    return Task.CompletedTask;
                });
            navigation.Children.Add(sections);
            var add = Buttons.Primary(L10n.Text("common.add_device"), ActionIcon.Create, async (_, _) => await PairAsync());
            Grid.SetColumn(add, 1);
            navigation.Children.Add(add);
            _root.Children.Add(navigation);

            switch (_devicePage)
            {
                case DevicePage.Devices:
                    _root.Children.Add(ThisMachineCard(account, allowed, TunnelOn()));
                    _root.Children.Add(AlwaysOnHostCard());
                    _root.Children.Add(_deviceSearch);
                    _root.Children.Add(_deviceInventory);
                    RenderDeviceInventory();
                    break;
                case DevicePage.Access:
                    _root.Children.Add(new TextBlock { Text = L10n.Text("windows.machinespage.choose_what_connected_devices_can_do_on_th.3b0521a4"),
                        TextWrapping = TextWrapping.Wrap, Opacity = 0.7 });
                    var approved = ApprovedPeers();
                    if (approved.Count > 0)
                        _root.Children.Add(DevicePermissionsCard(approved));
                    else
                        _root.Children.Add(EmptyState.View(L10n.Text("windows.machinespage.no_access_granted.a6972918"),
                            L10n.Text("windows.machinespage.pair_a_device_first_its_access_controls_wi.3d1f4240"), EmptyArtKind.Devices));
                    _root.Children.Add(EncryptionNote());
                    break;
            }
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

    /// Search rebuilds only inventory rows, preserving the native editor,
    /// caret and top-level management actions while the person types.
    private void RenderDeviceInventory()
    {
        _deviceInventory.Children.Clear();
        if (_account is not { } account || _devicePage != DevicePage.Devices) return;
        var machines = (account["machines"] as JsonArray)?.OfType<JsonNode>().ToList() ?? new();
        var peers = UnlistedKnown(account);
        var query = (_deviceSearch.Text ?? "").Trim();
        bool Matches(params string[] fields) => query.Length == 0
            || fields.Any(field => field.Contains(query, StringComparison.OrdinalIgnoreCase));
        var shownMachines = machines.Where(machine => Matches(DeviceTitle(machine), MachineId(machine),
            Format.Text(machine, "platform"), Format.Text(machine, "kind") == "client" ? L10n.Text("windows.machinespage.phone_tablet.e6922f86") : L10n.Text("windows.machinespage.computer.76ed42d2"),
            StatusLine(machine, IsSelf(machine)))).ToList();
        var shownPeers = peers.Where(peer => Matches(Format.Text(peer, "label"), Format.Text(peer, "words"),
            Format.Text(peer, "platform"), Format.Text(peer, "trust"),
            Format.Text(peer, "trust") == "approved" ? L10n.Text("windows.machinespage.access_allowed.f5058646") : L10n.Text("windows.machinespage.access_removed.dcdce51f"))).ToList();
        var total = machines.Count + peers.Count;
        var shown = shownMachines.Count + shownPeers.Count;
        if (query.Length > 0)
            _deviceInventory.Children.Add(new TextBlock { Text = L10n.Text("windows.machinespage.0_of_1_devices.bd266bff", $"{shown}", $"{total}"), Opacity = 0.7 });
        if (shownMachines.Count > 0)
            _deviceInventory.Children.Add(AccountDevicesCard(account, shownMachines, showScreenHint: query.Length == 0));
        if (shownPeers.Count > 0)
            _deviceInventory.Children.Add(OtherApprovedCard(shownPeers));
        if (shown == 0)
            _deviceInventory.Children.Add(EmptyState.View(
                total == 0 ? L10n.Text("windows.machinespage.no_devices_yet.a149f2bd") : L10n.Text("windows.machinespage.no_matching_devices.7bad272d"),
                total == 0 ? L10n.Text("windows.machinespage.add_a_device_to_connect_to_its_projects_an.511b0e32")
                    : L10n.Text("windows.machinespage.search_by_device_name_platform_status_or_c.6a59cb34"),
                EmptyArtKind.Devices));
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
        return Format.Text(machine, "kind") == "client" ? L10n.Text("windows.machinespage.unnamed_device.6aba593f") : L10n.Text("windows.machinespage.unnamed_computer.810da0c7");
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
                Text = string.IsNullOrEmpty(label) ? L10n.Text("windows.machinespage.unnamed_device.6aba593f") : label,
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
            var name = string.IsNullOrEmpty(label) ? L10n.Text("windows.machinespage.this_device.cf3cc23e") : label;
            actions.Children.Add(Buttons.Primary(
                L10n.Text("windows.machinespage.approve.6007acbe"), ActionIcon.Approve, async (_, _) => await ApproveAsync(key, name)));
            actions.Children.Add(ActionIconGlyph.Button(
                L10n.Text("windows.machinespage.forget.a6bd489d"), ActionIcon.Delete, async (_, _) => await ConfirmForgetAsync(key, name)));
            actions.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.machinespage.details.45989de4"), ActionIcon.Reveal, (_, _) =>
            {
                _selectThis = false;
                _selectedId = null;
                _selectedPeer = key;
                Render();
                RefreshInspector();
                DetailsRequested?.Invoke();
            }));
            row.Children.Add(actions);
            body.Children.Add(row);
        }
        body.Children.Add(new TextBlock
        {
            Text = L10n.Text("windows.machinespage.approve_only_devices_you_recognize_you_can.e599993b"),
            Opacity = 0.7,
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
        });
        return Chrome.Card(
            L10n.Text("windows.machinespage.needs_your_approval.635ea5c1"),
            body,
            L10n.Text("windows.machinespage.nothing_can_run_here_until_you_approve_it.1dbb95eb"));
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
                    ? L10n.Text("windows.machinespage.device_0.625b47c6", $"{peerId[..Math.Min(8, peerId.Length)]}")
                    : L10n.Text("windows.machinespage.an_unknown_device.767525fc");
            var control = Format.Flag(row, "control");
            var line = new StackPanel { Spacing = Theme.SpaceS };
            line.Children.Add(new TextBlock
            {
                Text = screen ? L10n.Text("windows.machinespage.0_wants_to_see_this_screen.a07f03f2", $"{name}") : L10n.Text("windows.machinespage.0_wants_to_open_your_work.24c50659", $"{name}"),
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                TextWrapping = TextWrapping.Wrap,
            });
            line.Children.Add(new TextBlock
            {
                Text = screen
                    ? control
                        ? L10n.Text("windows.machinespage.it_asked_for_the_picture_and_for_mouse_and.d24fdc88")
                        : L10n.Text("windows.machinespage.it_asked_for_the_picture_only.b6be05b5")
                    : L10n.Text("windows.machinespage.folders_files_terminals_and_the_agents_run.5abdd984"),
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
                    L10n.Text("windows.machinespage.view_only.9b4c6c85"), ActionIcon.Preview, async (_, _) =>
                        await AnswerRequestAsync(captured, true, true, false, name)));
                actions.Children.Add(Buttons.Primary(
                    L10n.Text("windows.machinespage.full_access.f19611c6"), ActionIcon.Approve, async (_, _) =>
                        await AnswerRequestAsync(captured, true, true, true, name)));
            }
            else
            {
                actions.Children.Add(Buttons.Primary(
                    L10n.Text("windows.machinespage.allow.e213c161"), ActionIcon.Approve, async (_, _) =>
                        await AnswerRequestAsync(captured, false, true, false, name)));
            }
            actions.Children.Add(Buttons.Destructive(
                L10n.Text("windows.machinespage.deny.05a2d733"), ActionIcon.Revoke, async (_, _) =>
                    await AnswerRequestAsync(captured, screen, false, false, name)));
            line.Children.Add(actions);
            body.Children.Add(line);
        }
        return Chrome.Card(
            L10n.Text("windows.machinespage.waiting_for_you.9f760ab2"),
            body,
            L10n.Text("windows.machinespage.approve_only_a_device_you_recognise_you_ca.69c0725e"));
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
                ? L10n.Text("windows.machinespage.0_was_not_let_in.5acb6aae", $"{name}")
                : screen
                    ? control ? L10n.Text("windows.machinespage.0_can_see_this_screen_and_drive_it.4ab9505f", $"{name}") : L10n.Text("windows.machinespage.0_can_see_this_screen.3ec8249b", $"{name}")
                    : L10n.Text("windows.machinespage.0_may_now_open_your_work.36fad4b9", $"{name}");
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
                Text = L10n.Text("windows.machinespage.the_host_helper_has_not_answered_yet.ed11e9fb"),
                Opacity = 0.7,
                TextWrapping = TextWrapping.Wrap,
            });
        }
        else
        {
            var alwaysOn = Format.Flag(_hostPolicy, "alwaysOn");
            var battery = Format.Flag(_hostPolicy, "hasInternalBattery");
            body.Children.Add(Chrome.SettingSwitch(L10n.Text("windows.machinespage.keep_this_pc_reachable.34cbc0f8"), alwaysOn, async on =>
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
                    ? L10n.Text("windows.machinespage.the_host_helper_stays_up_after_you_quit.6db32069")
                    : L10n.Text("windows.machinespage.the_host_helper_stops_when_you_quit.be7c7ee9");
                await LoadAsync();
            }));
            body.Children.Add(new TextBlock
            {
                Text = alwaysOn
                    ? L10n.Text("windows.machinespage.the_host_helper_keeps_running_after_you_qu.a283800a")
                    : L10n.Text("windows.machinespage.the_host_helper_stops_when_you_quit_tokens.d6e04c9b"),
                Opacity = 0.7,
                FontSize = 12,
                TextWrapping = TextWrapping.Wrap,
            });
            if (alwaysOn && battery)
            {
                body.Children.Add(new TextBlock
                {
                    Text = L10n.Text("windows.machinespage.uses_more_power.a24adb34"),
                    Opacity = 0.7,
                    FontSize = 12,
                });
            }
            if (!alwaysOn)
            {
                body.Children.Add(new TextBlock
                {
                    Text = L10n.Text("windows.machinespage.automations_run_only_while_tokenstat_is_op.72980d54"),
                    Opacity = 0.7,
                    FontSize = 12,
                });
            }
        }
        return Chrome.Card(
            L10n.Text("windows.machinespage.always_on_host.f7990642"),
            body,
            L10n.Text("windows.machinespage.whether_the_host_helper_stays_up_after_you.dd1619f2"));
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
            var name = string.IsNullOrEmpty(label) ? L10n.Text("windows.machinespage.approved_device.3170ef88") : label;
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
                L10n.Text("common.projects"), _workspaceAllowed.Contains(key), async on =>
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
            var viewSwitch = PermissionSwitch(L10n.Text("windows.machinespage.view.dcc839a4"), screen.View, async on =>
            {
                var control = on && _screenPermissions.TryGetValue(captured, out var current) && current.Control;
                await AppServices.Host.CallAsync(
                    "screen.policy.set",
                    new JsonObject { ["peerId"] = captured, ["view"] = on, ["control"] = control });
                _screenPermissions[captured] = (on, control);
            });
            switches.Children.Add(viewSwitch);
            var controlSwitch = PermissionSwitch(L10n.Text("windows.machinespage.control.32d7e820"), screen.Control, async on =>
            {
                await AppServices.Host.CallAsync(
                    "screen.policy.set",
                    new JsonObject { ["peerId"] = captured, ["view"] = true, ["control"] = on });
                _screenPermissions[captured] = (true, on);
            });
            controlSwitch.IsEnabled = screen.View;
            ToolTipService.SetToolTip(controlSwitch, L10n.Text("windows.machinespage.control_requires_screen_viewing_access.bf319cd9"));
            switches.Children.Add(controlSwitch);
            row.Children.Add(switches);
            body.Children.Add(row);
        }
        body.Children.Add(new TextBlock
        {
            Text = L10n.Text("windows.machinespage.control_requires_view_devices_can_also_req.b5c3c672"),
            Opacity = 0.7,
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
        });
        return Chrome.Card(
            L10n.Text("windows.machinespage.device_permissions.8b91be20"),
            body,
            L10n.Text("windows.machinespage.choose_what_each_approved_device_can_acces.1fdcbc41"));
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
            var name = string.IsNullOrEmpty(label) ? L10n.Text("windows.machinespage.unnamed_device.6aba593f") : label;
            var row = new StackPanel { Spacing = Theme.SpaceS };
            row.Children.Add(new TextBlock
            {
                Text = name,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                TextWrapping = TextWrapping.Wrap,
            });
            row.Children.Add(new TextBlock
            {
                Text = Format.Text(peer, "trust") == "approved" ? L10n.Text("windows.machinespage.access_allowed.f5058646") : L10n.Text("windows.machinespage.access_removed.dcdce51f"),
                Opacity = 0.7, FontSize = 12,
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
            actions.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.machinespage.details.45989de4"), ActionIcon.Reveal, (_, _) =>
            {
                _selectThis = false;
                _selectedId = null;
                _selectedPeer = key;
                Render();
                RefreshInspector();
                DetailsRequested?.Invoke();
            }));
            // Access changes are rarer than a look, so they wait in one menu.
            var manage = new MenuFlyout();
            if (Format.Text(peer, "trust") == "approved")
            {
                ContextMenus.AddAsync(manage, L10n.Text("windows.machinespage.revoke_access.ab292ddb"), () => ConfirmRevokeAsync(key, name));
            }
            else
            {
                ContextMenus.AddAsync(manage, L10n.Text("windows.machinespage.approve.6007acbe"), () => ApproveAsync(key, name));
            }
            ContextMenus.AddAsync(manage, L10n.Text("windows.machinespage.forget.a6bd489d"), () => ConfirmForgetAsync(key, name));
            actions.Children.Add(ActionIconGlyph.MoreButton(L10n.Text("windows.machinespage.manage_0.d77d63f8", $"{name}"), manage));
            row.Children.Add(actions);
            body.Children.Add(row);
        }
        return Chrome.Card(
            L10n.Text("windows.machinespage.other_devices.4e027dbb"),
            body,
            L10n.Text("windows.machinespage.devices_known_to_this_pc_outside_your_acco.ca54a043"));
    }

    private UIElement AccountDevicesCard(JsonNode account, IEnumerable<JsonNode> machines, bool showScreenHint = true)
    {
        var tier = Format.Text(account, "tier");
        var list = new StackPanel { Spacing = Theme.SpaceS };
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
            L10n.Text("windows.machinespage.your_devices.555eaa22"),
            list,
            L10n.Text("windows.machinespage.select_a_device_for_connection_details_pho.274a6b8e"));
        if (viewable == 0 && showScreenHint)
        {
            var wrap = new StackPanel { Spacing = Theme.SpaceM };
            wrap.Children.Add(card);
            wrap.Children.Add(Chrome.Banner(
                L10n.Text("windows.machinespage.no_other_computer_to_view_screen_share_is.1dbff049"),
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
                    Text = L10n.Text("windows.machinespage.this_pc.66f5aa0b"),
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
            L10n.Text("windows.machinespage.devices_on_this_account.50d8cf5c"),
            list,
            L10n.Text("windows.machinespage.usage_from_every_linked_device_is_already.9f16ae77"));
    }

    private UIElement AddDeviceCard()
    {
        var body = new StackPanel { Spacing = Theme.SpaceM };
        body.Children.Add(Buttons.Primary(
            L10n.Text("common.add_device"), ActionIcon.Create, async (_, _) => await PairAsync()));
        return Chrome.Card(
            L10n.Text("windows.machinespage.add_a_device.5469d968"),
            body,
            L10n.Text("windows.machinespage.paste_the_key_from_the_other_machine_every.75ebefc4"));
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
        nameRow.Children.Add(new TextBlock { Text = L10n.Text("windows.machinespage.name.dcd1d522"), Opacity = 0.7, VerticalAlignment = VerticalAlignment.Center });
        nameRow.Children.Add(new TextBlock
        {
            Text = string.IsNullOrEmpty(selfName) ? L10n.Text("windows.machinespage.this_pc.638a348b") : selfName,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
        });
        nameRow.Children.Add(ActionIconGlyph.Button(
            L10n.Text("common.rename"), ActionIcon.Edit, async (_, _) => await RenameSelfAsync(selfName)));
        body.Children.Add(nameRow);
        if (!string.IsNullOrEmpty(words))
        {
            // The comparison a person actually performs. The words are derived
            // from a public key: there is nothing private in them, so they are
            // shown plain and selectable.
            var knownRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
            knownRow.Children.Add(new TextBlock { Text = L10n.Text("windows.machinespage.known_as.9076e6ab"), Opacity = 0.7, VerticalAlignment = VerticalAlignment.Center });
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
        var remoteSwitch = Chrome.SettingSwitch(L10n.Text("windows.machinespage.enable_remote_access.d4c2690c"), allowed && tunnel, async on =>
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
                ? L10n.Text("windows.machinespage.remote_reach_is_on_direct_connections_are.f9aa785a")
                : L10n.Text("windows.machinespage.remote_reach_is_off.701869a6");
            await LoadAsync();
        });
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(remoteSwitch, "devices.remoteAccess");
        body.Children.Add(remoteSwitch);
        body.Children.Add(new TextBlock
        {
            Text = allowed && tunnel
                ? L10n.Text("windows.machinespage.remote_access_is_on_this_pc_will_be_reacha.df3d16b9")
                : L10n.Text("windows.machinespage.turn_this_on_to_make_this_pc_reachable_fro.2b497e83"),
            Opacity = 0.7,
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
        });
        body.Children.Add(new TextBlock
        {
            Text = L10n.Text("windows.machinespage.connections_are_end_to_end_encrypted_scree.fca19521"),
            Opacity = 0.6,
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
        });
        if (!allowed)
        {
            body.Children.Add(new TextBlock
            {
                Text = (account["signedIn"]?.GetValue<bool>() ?? false)
                    ? L10n.Text("windows.machinespage.this_computer_and_another_device_already_s.c3dc1438")
                    : L10n.Text("windows.machinespage.remote_reach_needs_a_signed_in_patron_acco.7f190960"),
                FontWeight = Microsoft.UI.Text.FontWeights.Medium,
                TextWrapping = TextWrapping.Wrap,
            });
            body.Children.Add(new TextBlock
            {
                Text = (account["signedIn"]?.GetValue<bool>() ?? false)
                    ? L10n.Text("windows.machinespage.free_and_supporter_add_up_usage_from_every.ede332b0")
                    : L10n.Text("windows.machinespage.sign_in_with_an_account_that_includes_it_t.3e4fb59e"),
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
                    ? L10n.Text("windows.machinespage.remote_reach_is_on_but_the_tunnel_has_not.024544f1")
                    : FriendlyError.Display(tunnelError),
                Theme.Warning,
                Symbol.Important));
            if (FriendlyError.From(tunnelError).RequiresSignIn)
                body.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.friendlyerror.sign_in_again.51fbe1dc"), ActionIcon.SignIn,
                    async (_, _) => await SignInFlow.RunAsync(this, _signSlot, async () =>
                    {
                        await AppServices.Host.CallAsync("remote.reconsiderPlan");
                        await LoadAsync();
                    })));
        }
        body.Children.Add(ActionIconGlyph.Button(
            L10n.Text("windows.machinespage.details.45989de4"), ActionIcon.Reveal, (_, _) =>
            {
                _selectThis = true;
                _selectedId = null;
                _selectedPeer = null;
                Render();
                RefreshInspector();
                DetailsRequested?.Invoke();
            }));
        return Chrome.Card(
            L10n.Text("windows.machinespage.connection_settings.b4ddb3c1"),
            body,
            L10n.Text("windows.machinespage.identity_and_remote_access_for_this_pc.0dd7ca7d"));
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
                ? L10n.Text("windows.machinespage.this_pc_already_shares_the_account_and_see.5269c899")
                : L10n.Text("windows.machinespage.sign_in_with_a_patron_or_legend_account_to.daf3326f"),
            Opacity = 0.7,
            TextWrapping = TextWrapping.Wrap,
        });
        body.Children.Add(ActionIconGlyph.Button(
            L10n.Text("windows.machinespage.see_plans.d9898933"), ActionIcon.Plans, (_, _) => Open("https://tokenstat.ai/pricing")));
        return Chrome.Card(L10n.Text("windows.machinespage.remote_is_on_patron.d25dea13"), body);
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
            Text = L10n.Text("windows.machinespage.a_connection_between_two_machines_carries.aa0d4220"),
            Opacity = 0.7,
            TextWrapping = TextWrapping.Wrap,
        });
        if (_identity is not null && !string.IsNullOrEmpty(SelfKey()))
        {
            details.Children.Add(KeyLine(
                L10n.Text("windows.machinespage.this_pc.638a348b"),
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
                string.IsNullOrEmpty(label) ? L10n.Text("windows.machinespage.approved_device.3170ef88") : label,
                Format.Text(peer, "words"),
                Format.Text(peer, "fingerprint")));
        }
        details.Children.Add(new TextBlock
        {
            Text = L10n.Text("windows.machinespage.noise_xx_handshake_x25519_keys_chacha20_po.8025c019"),
            Opacity = 0.6,
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
        });
        return new Expander
        {
            Header = L10n.Text("windows.machinespage.end_to_end_encrypted_keys_are_hidden_until.f84da3d6"),
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
            return L10n.Text("windows.machinespage.this_device.d052579c");
        }
        var isHost = Format.Text(machine, "kind") != "client";
        if (!isHost)
        {
            // A phone holds the tunnel only while somebody is using it, so
            // "offline" here means "not in the app right now", not "broken".
            if (MachineOnline(machine) == true)
            {
                return L10n.Text("windows.machinespage.phone_in_the_app_now.49897ae2");
            }
            var used = RelativeOrNull(Format.Text(machine, "lastSeenAt"));
            if (used is not null)
            {
                return L10n.Text("windows.machinespage.phone_last_used_0.555b7a23", $"{used}");
            }
            return L10n.Text("windows.machinespage.phone_signed_in_on_this_account.58d549b8");
        }
        if (string.IsNullOrEmpty(Format.Text(machine, "publicIdentity")))
        {
            return L10n.Text("windows.machinespage.no_connection_key_yet.86015bb4");
        }
        if (MachineOnline(machine) == false)
        {
            var seen = RelativeOrNull(Format.Text(machine, "lastSeenAt"));
            return seen is null ? L10n.Text("common.offline") : L10n.Text("windows.machinespage.offline_last_seen_0.52d14c6d", $"{seen}");
        }
        var peer = PeerForMachine(machine);
        if (peer is not null && RemoteWorkspaces.IsConnected(Format.Text(peer, "key")))
        {
            return L10n.Text("windows.machinespage.connected_workspaces_in_sidebar.51252e72");
        }
        var lastSeen = RelativeOrNull(Format.Text(machine, "lastSeenAt"));
        if (lastSeen is not null)
        {
            return L10n.Text("windows.machinespage.seen_0.522e2767", $"{lastSeen}");
        }
        var synced = RelativeOrNull(Format.Text(machine, "lastSyncAt"));
        if (synced is not null)
        {
            return L10n.Text("windows.machinespage.last_synced_0.789aa5cd", $"{synced}");
        }
        return L10n.Text("windows.machinespage.no_sync_recorded.e74abceb");
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
    /// One account device. Technical identifiers and permissions stay in details.
    /// </summary>
    private UIElement DeviceRow(
        JsonNode? machine, string id, string tier, ref int viewable)
    {
        var isSelf = IsSelf(machine);
        var title = DeviceTitle(machine);
        var body = new StackPanel { Spacing = Theme.SpaceS };
        var head = new Grid { ColumnSpacing = Theme.SpaceS };
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        head.Children.Add(Marks.Device(Format.Text(machine, "platform"), Format.Text(machine, "kind") == "client"));
        var presence = PresenceDot(MachineOnline(machine), isSelf, _status?["tunnelOnline"]?.GetValue<bool>() ?? false);
        Grid.SetColumn(presence, 1);
        head.Children.Add(presence);
        var label = new TextBlock { Text = title, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextTrimming = TextTrimming.CharacterEllipsis, MaxLines = 1, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(label, 2);
        head.Children.Add(label);
        if (isSelf)
        {
            var here = new TextBlock { Text = L10n.Text("windows.machinespage.this_pc.638a348b"), Opacity = 0.6, FontSize = 11, VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(here, 3);
            head.Children.Add(here);
        }
        body.Children.Add(head);
        var platform = Format.Text(machine, "platform");
        if (!string.IsNullOrEmpty(platform))
        {
            body.Children.Add(new TextBlock { Text = platform, Opacity = 0.7, FontSize = 12 });
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
            actions.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.machinespage.view_screen.56dea3b5"), ActionIcon.Preview, (_, _) =>
            {
                if (string.IsNullOrEmpty(peerKey))
                {
                    _root.Children.Insert(0, Chrome.Banner(
                        L10n.Text("windows.machinespage.no_other_computer_to_view_screen_share_is.1dbff049"),
                        Theme.Accent,
                        Symbol.View));
                    return;
                }
                var open = AppServices.OpenScreen;
                if (open is null)
                {
                    _root.Children.Insert(0, Chrome.Banner(
                        L10n.Text("windows.machinespage.screen_share_is_not_wired_in_this_window.d1b86e44"),
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
                    ? L10n.Text("windows.machinespage.end_to_end_encrypted_from_this_device.54caee7b")
                    : L10n.Text("windows.machinespage.requires_legend.a630be5b"),
                Opacity = 0.7,
                FontSize = 12,
                VerticalAlignment = VerticalAlignment.Center,
            });
        }
        actions.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.machinespage.details.45989de4"), ActionIcon.Reveal, (_, _) =>
        {
            _selectThis = false;
            _selectedPeer = null;
            _selectedId = id;
            Render();
            RefreshInspector();
            DetailsRequested?.Invoke();
        }));
        // Rename and Unlink are rare, so they share one menu instead of two
        // buttons on every row.
        var manage = new MenuFlyout();
        ContextMenus.AddAsync(manage, L10n.Text("common.rename"), () => RenameAsync(id, Format.Text(machine, "label"), isSelf));
        if (!isSelf)
        {
            ContextMenus.AddAsync(manage, L10n.Text("windows.machinespage.remove_from_account.6bfa319e"), () => UnlinkAsync(id, title));
        }
        actions.Children.Add(ActionIconGlyph.MoreButton(L10n.Text("windows.machinespage.manage_0.d77d63f8", $"{title}"), manage));
        var row = new Grid { ColumnSpacing = Theme.SpaceM, RowSpacing = Theme.SpaceS };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        row.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        body.VerticalAlignment = VerticalAlignment.Center;
        actions.MaxWidth = 420;
        actions.VerticalAlignment = VerticalAlignment.Center;
        row.Children.Add(body);
        Grid.SetRow(actions, 1);
        row.Children.Add(actions);
        row.SizeChanged += (_, e) =>
        {
            bool wide = e.NewSize.Width >= 760;
            Grid.SetColumn(actions, wide ? 1 : 0);
            Grid.SetRow(actions, wide ? 0 : 1);
        };

        var selected = !_selectThis && _selectedPeer is null && _selectedId == id;
        var card = new Border
        {
            Child = row,
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
                    L10n.Text("common.disconnect"), ActionIcon.Disconnect, async (_, _) =>
                        await DisconnectPeerAsync(peerKey, name)));
                return;
            }
            switch (Format.Text(peer, "trust"))
            {
                case "pending":
                    actions.Children.Add(Buttons.Primary(
                        L10n.Text("windows.machinespage.approve.6007acbe"), ActionIcon.Approve, async (_, _) =>
                            await ApproveAsync(peerKey, name)));
                    break;
                case "approved":
                    if (CanConnect(machine))
                    {
                        actions.Children.Add(Buttons.Primary(
                            L10n.Text("common.connect"), ActionIcon.Connect, async (_, _) =>
                                await ConnectPeerAsync(peerKey, name, MachineOnline(machine))));
                    }
                    actions.Children.Add(ActionIconGlyph.Button(
                        L10n.Text("windows.machinespage.revoke.87e6d00b"), ActionIcon.Revoke, async (_, _) =>
                            await ConfirmRevokeAsync(peerKey, name)));
                    break;
                default:
                    actions.Children.Add(ActionIconGlyph.Button(
                        L10n.Text("windows.machinespage.approve.6007acbe"), ActionIcon.Approve, async (_, _) =>
                            await ApproveAsync(peerKey, name)));
                    break;
            }
            return;
        }
        if (!string.IsNullOrEmpty(key) && CanConnect(machine))
        {
            var captured = machine;
            actions.Children.Add(Buttons.Primary(
                L10n.Text("common.connect"), ActionIcon.Connect, async (_, _) =>
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
            Text = L10n.Text("windows.machinespage.auto_connect.45b6d201"),
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
        ToolTipService.SetToolTip(toggle, L10n.Text("windows.machinespage.auto_connect_0.3bbf847e", $"{Format.Text(peer, "label", "this device")}"));
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
                L10n.Text("windows.machinespage.0_has_no_connection_key_on_this_account_re.9e4e975a", $"{title}"),
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
        _notice = L10n.Text("windows.machinespage.disconnected_from_0_its_workspaces_are_no.3ecfb24d", $"{name}");
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
            DevicePresentation.ConnectionState(_status)?.ToJsonString() ?? "",
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
            Text = L10n.Text("windows.machinespage.device.6ba0bdec"),
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
                L10n.Text("windows.machinespage.device.6ba0bdec"), L10n.Text("windows.machinespage.pick_a_device.de6694f3"), L10n.Text("windows.machinespage.connection_details_and_actions_appear_here.2f1411a1")));
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
            Text = string.IsNullOrEmpty(name) ? L10n.Text("windows.machinespage.this_pc.638a348b") : name,
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
            body.Children.Add(Labeled(L10n.Text("windows.machinespage.known_as.9076e6ab"), words));
        }
        body.Children.Add(Buttons.Primary(
            L10n.Text("windows.machinespage.copy_invite.953ed058"), ActionIcon.Copy, (_, _) => CopyInvite()));
        body.Children.Add(new TextBlock
        {
            Text = L10n.Text("windows.machinespage.paste_this_in_the_other_machine_s_add_devi.014fee4c"),
            Opacity = 0.7,
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
        });
        body.Children.Add(Labeled(
            L10n.Text("windows.machinespage.reachability.66f0f432"),
            _status?["tunnelOnline"]?.GetValue<bool>() == true
                ? L10n.Text("windows.machinespage.tunnel_up.77a2eaee")
                : L10n.Text("windows.machinespage.not_reachable_from_elsewhere.1f54e85a")));
        body.Children.Add(HostStatsCard(null));
        body.Children.Add(HostUpdateCard(null, local: true));
        _inspectorRoot.Children.Add(body);
    }

    private void PeerInspector(JsonNode peer)
    {
        var key = Format.Text(peer, "key");
        var label = Format.Text(peer, "label");
        var name = string.IsNullOrEmpty(label) ? L10n.Text("windows.machinespage.unnamed_device.6aba593f") : label;
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
            body.Children.Add(Labeled(L10n.Text("windows.machinespage.known_as.9076e6ab"), words));
        }
        body.Children.Add(Labeled(L10n.Text("windows.machinespage.trust.ade9248e"), TrustLabel(Format.Text(peer, "trust"))));
        var connected = RemoteWorkspaces.IsConnected(key);
        if (connected)
        {
            body.Children.Add(new TextBlock
            {
                Text = L10n.Text("windows.machinespage.projects_from_this_device_are_in_the_sideb.a1c36b35"),
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
                    L10n.Text("common.disconnect"), ActionIcon.Disconnect, async (_, _) =>
                        await DisconnectPeerAsync(key, name)));
            }
            else
            {
                actions.Children.Add(Buttons.Primary(
                    L10n.Text("common.connect"), ActionIcon.Connect, async (_, _) =>
                        await ConnectPeerAsync(key, name, online: null)));
            }
            actions.Children.Add(AutoConnectRow(peer, machine: null));
            actions.Children.Add(ActionIconGlyph.Button(
                L10n.Text("windows.machinespage.revoke.87e6d00b"), ActionIcon.Revoke, async (_, _) =>
                    await ConfirmRevokeAsync(key, name)));
        }
        else
        {
            actions.Children.Add(Buttons.Primary(
                L10n.Text("windows.machinespage.approve.6007acbe"), ActionIcon.Approve, async (_, _) =>
                    await ApproveAsync(key, name)));
        }
        actions.Children.Add(ActionIconGlyph.Button(
            L10n.Text("windows.machinespage.forget.a6bd489d"), ActionIcon.Delete, async (_, _) =>
                await ConfirmForgetAsync(key, name)));
        body.Children.Add(actions);
        _inspectorRoot.Children.Add(body);
    }

    private static string TrustLabel(string trust) => trust switch
    {
        "pending" => L10n.Text("windows.machinespage.waiting_for_approval.10c5739b"),
        "approved" => L10n.Text("windows.machinespage.approved.87b42e40"),
        "revoked" => L10n.Text("windows.machinespage.revoked.f6f738d0"),
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
        body.Children.Add(Labeled(L10n.Text("windows.machinespage.code.340f4630"), id));
        var platform = Format.Text(machine, "platform");
        if (!string.IsNullOrEmpty(platform))
        {
            body.Children.Add(Labeled(L10n.Text("windows.machinespage.platform.c78ffe19"), platform));
        }
        body.Children.Add(Labeled(L10n.Text("windows.machinespage.status.920e413c"), StatusLine(machine, isSelf)));
        var words = Format.Text(PeerForMachine(machine), "words");
        if (!string.IsNullOrEmpty(words))
        {
            body.Children.Add(Labeled(L10n.Text("windows.machinespage.known_as.9076e6ab"), words));
        }
        var actions = new StackPanel { Spacing = Theme.SpaceS };
        var isHost = Format.Text(machine, "kind") != "client";
        var peerKey = Format.Text(machine, "publicIdentity");
        if (isSelf)
        {
            body.Children.Add(new TextBlock
            {
                Text = L10n.Text("windows.machinespage.this_device.3b5031a9"),
                Opacity = 0.7,
                TextWrapping = TextWrapping.Wrap,
            });
            body.Children.Add(HostStatsCard(null));
            body.Children.Add(HostUpdateCard(null, local: true));
        }
        else if (!isHost)
        {
            body.Children.Add(new TextBlock
            {
                Text = L10n.Text("windows.machinespage.this_phone_or_tablet_connects_to_your_comp.c99a1b87"),
                Opacity = 0.7, TextWrapping = TextWrapping.Wrap,
            });
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
                    L10n.Text("common.disconnect"), ActionIcon.Disconnect, async (_, _) =>
                        await DisconnectPeerAsync(linkedKey, name)));
            }
            else
            {
                actions.Children.Add(Buttons.Primary(
                    L10n.Text("common.connect"), ActionIcon.Connect, async (_, _) =>
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
                L10n.Text("common.connect"), ActionIcon.Connect, async (_, _) =>
                    await ConnectMachineAsync(machine)));
        }
        if (isHost && !isSelf)
        {
            var deviceName = title;
            actions.Children.Add(ActionIconGlyph.Button(
                L10n.Text("windows.machinespage.view_screen.56dea3b5"), ActionIcon.Preview, (_, _) =>
                {
                    var open = AppServices.OpenScreen;
                    if (string.IsNullOrEmpty(peerKey) || open is null)
                    {
                        _notice = L10n.Text("windows.machinespage.open_devices_on_that_computer_so_it_regist.9f7244ac");
                        _ = LoadAsync();
                        return;
                    }
                    open(peerKey, deviceName);
                }));
        }
        actions.Children.Add(ActionIconGlyph.Button(
            L10n.Text("common.rename"), ActionIcon.Edit, async (_, _) =>
            {
                await RenameAsync(id, Format.Text(machine, "label"), isSelf);
            }));
        if (!isSelf)
        {
            actions.Children.Add(ActionIconGlyph.Button(
                L10n.Text("windows.machinespage.remove_from_account.6bfa319e"), ActionIcon.Delete, async (_, _) =>
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
            row.Children.Add(Chrome.InspectorField(L10n.Text("windows.machinespage.power.848e9656"), "n/a"));
            row.Children.Add(Chrome.InspectorField(L10n.Text("windows.machinespage.cpu.db9a4c7d"), L10n.Text("windows.machinespage.n_a.a683c5c5")));
            return;
        }
        row.Children.Add(Chrome.InspectorField(L10n.Text("windows.machinespage.power.848e9656"), PowerLabel(stats)));
        if (stats["cpu"] is not null)
        {
            row.Children.Add(Chrome.InspectorField(L10n.Text("windows.machinespage.cpu.db9a4c7d"), CpuLabel(Format.Number(stats, "cpu"))));
        }
        if (stats["ramTotalBytes"] is not null)
        {
            row.Children.Add(Chrome.InspectorField(
                L10n.Text("windows.machinespage.memory.c3963aed"),
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
            return L10n.Text("windows.machinespage.plugged_in.edefc1f9");
        }
        if (percent.HasValue)
        {
            return $"{percent}%";
        }
        if (Format.Text(stats, "power") == "battery")
        {
            return L10n.Text("windows.machinespage.on_battery.51d53044");
        }
        if (Format.Text(stats, "power") == "ac")
        {
            return L10n.Text("windows.machinespage.plugged_in.edefc1f9");
        }
        return L10n.Text("windows.machinespage.n_a.a683c5c5");
    }

    private static string CpuLabel(double cpu) => $"{(int)Math.Round(cpu * 100)}%";

    private static string RamLabel(long used, long total)
    {
        const double g = 1024d * 1024 * 1024;
        var u = used / g;
        var t = total / g;
        return t >= 10 ? L10n.Text("windows.machinespage.0_1_gb.12e92d23", $"{u:0}", $"{t:0}") : L10n.Text("windows.machinespage.0_1_gb.12e92d23", $"{u:0.0}", $"{t:0.0}");
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
            Text = L10n.Text("windows.machinespage.software.9b3289a3"),
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
            Text = L10n.Text("windows.machinespage.looking_for_a_newer_release.7e1ada06"),
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
                L10n.Text("windows.machinespage.check_again.fb7099ad"), ActionIcon.Refresh, async (_, _) =>
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
                ? L10n.Text("windows.machinespage.running_0.015ef2e2", $"{version}")
                : newer ? $"{version} → {latest}" : version,
            FontFamily = Fonts.Mono,
            FontSize = 12,
        });
        if (restartPending)
        {
            state.Children.Add(UpdateNote(
                local ? L10n.Text("windows.machinespage.installed_restart_the_helper_to_use_it.f04732fb") : L10n.Text("windows.machinespage.installed_restart_it_there_to_use_it.54cbadd3")));
        }
        else if (newer)
        {
            state.Children.Add(UpdateNote(L10n.Text("windows.machinespage.version_0_is_available.874abce6", $"{latest}")));
        }
        else
        {
            state.Children.Add(UpdateNote(L10n.Text("windows.machinespage.up_to_date.50620fd9")));
        }
        if (appManaged)
        {
            state.Children.Add(UpdateNote(
                local
                    ? L10n.Text("windows.machinespage.the_tokenstat_application_owns_this_helper.d5e8bbb9")
                    : L10n.Text("windows.machinespage.the_tokenstat_application_there_owns_its_h.c214574e")));
        }
        else
        {
            if (newer && !canRestart)
            {
                state.Children.Add(UpdateNote(
                    L10n.Text("windows.machinespage.it_installs_but_cannot_restart_itself_so_i.f14f8d70")));
            }
            if (autoApply)
            {
                state.Children.Add(UpdateNote(L10n.Text("windows.machinespage.checks_daily_on_its_own.bfd7c539")));
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
                    L10n.Text("windows.machinespage.restart.6b983a81"), ActionIcon.Refresh, async (_, _) =>
                        await ApplyHostUpdateAsync(state, peerKey, local, restartNow: true)));
            }
        }
        else if (newer && !appManaged)
        {
            actions.Children.Add(Buttons.Primary(
                L10n.Text("windows.machinespage.install.569ca49f"), ActionIcon.Download, async (_, _) =>
                    await ApplyHostUpdateAsync(state, peerKey, local, restartNow: false)));
        }
        else if (appManaged && newer)
        {
            actions.Children.Add(Buttons.Primary(
                local ? L10n.Text("windows.machinespage.download.d6eafe82") : L10n.Text("windows.machinespage.fetch.cd7d61bf"), ActionIcon.Download, async (_, _) =>
                    await ApplyHostUpdateAsync(state, peerKey, local, restartNow: false)));
        }
        actions.Children.Add(ActionIconGlyph.Button(
            L10n.Text("windows.machinespage.check_again.fb7099ad"), ActionIcon.Refresh, async (_, _) =>
                await FillHostUpdateAsync(state, peerKey, local)));
        state.Children.Add(actions);
    }

    private static async Task ApplyHostUpdateAsync(
        StackPanel state, string? peerKey, bool local, bool restartNow)
    {
        state.Children.Clear();
        state.Children.Add(new TextBlock
        {
            Text = L10n.Text("windows.machinespage.downloading_checking_and_installing_this_t.c0e97360"),
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
                L10n.Text("windows.machinespage.check_again.fb7099ad"), ActionIcon.Refresh, async (_, _) =>
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
                L10n.Text("windows.machinespage.installed_0_restarting_on_it_now_so_this_m.4a3fb7f6", $"{to}")));
        }
        else if (!string.IsNullOrEmpty(Format.Text(applied, "appImage"))
            && Format.Flag(applied, "appManaged"))
        {
            state.Children.Add(UpdateNote(L10n.Text("windows.machinespage.the_application_s_download_is_ready_on_tha.bc948717")));
        }
        else
        {
            state.Children.Add(UpdateNote(
                local ? L10n.Text("windows.machinespage.installed_restart_the_helper_to_use_it.f04732fb") : L10n.Text("windows.machinespage.installed_restart_it_there_to_use_it.54cbadd3")));
        }
        if (Format.Flag(applied, "restartPending") && Format.Flag(applied, "canRestart"))
        {
            state.Children.Add(Buttons.Primary(
                L10n.Text("windows.machinespage.restart.6b983a81"), ActionIcon.Refresh, async (_, _) =>
                    await ApplyHostUpdateAsync(state, peerKey, local, restartNow: true)));
        }
        state.Children.Add(ActionIconGlyph.Button(
            L10n.Text("windows.machinespage.check_again.fb7099ad"), ActionIcon.Refresh, async (_, _) =>
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
                L10n.Text("windows.machinespage.the_invite_could_not_reach_the_clipboard.4a53dacd"),
                Theme.Warning,
                Symbol.Important));
            return;
        }
        _notice = L10n.Text("windows.machinespage.invite_copied_on_the_other_device_choose_a.ff13a35e");
        Render();
    }

    /// <summary>
    /// Pair a machine that is not on the account yet. The paste is the whole
    /// form: a key, a name for the list, and an optional address hint.
    /// </summary>
    private async Task PairAsync()
    {
        var keyBox = new TextBox { PlaceholderText = L10n.Text("windows.machinespage.key_from_the_other_machine.4a191927") };
        var labelBox = new TextBox { PlaceholderText = L10n.Text("windows.machinespage.name_for_the_list.5df29eeb") };
        var addressBox = new TextBox { PlaceholderText = L10n.Text("windows.machinespage.address_optional.8cb13162") };
        var form = new StackPanel { Spacing = Theme.SpaceS };
        form.Children.Add(keyBox);
        form.Children.Add(labelBox);
        form.Children.Add(addressBox);
        var dialog = new ContentDialog
        {
            Title = L10n.Text("windows.machinespage.add_a_device.5469d968"),
            Content = form,
            PrimaryButtonText = L10n.Text("windows.machinespage.pair.989da04b"),
            CloseButtonText = L10n.Text("common.cancel"),
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
                L10n.Text("windows.machinespage.that_is_this_device_it_is_already_here_and.6ca9f067"),
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
                ? L10n.Text("windows.machinespage.paired_it_will_not_answer_until_somebody_a.9fa23091")
                : L10n.Text("windows.machinespage.paired_with_0_it_will_not_answer_until_som.653a0611", $"{name}");
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
            _notice = L10n.Text("windows.machinespage.0_may_now_reach_this_device.cef66588", $"{name}");
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
            Title = L10n.Text("windows.machinespage.revoke_access.8138e6ff"),
            Content = new TextBlock
            {
                Text = L10n.Text("windows.machinespage.that_device_can_no_longer_reach_this_machi.e0406f8e"),
                TextWrapping = TextWrapping.Wrap,
            },
            PrimaryButtonText = L10n.Text("windows.machinespage.revoke.87e6d00b"),
            CloseButtonText = L10n.Text("windows.machinespage.keep_access.68cfc92d"),
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
            _notice = L10n.Text("windows.machinespage.0_can_no_longer_reach_this_device.e6993257", $"{name}");
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
            Title = L10n.Text("windows.machinespage.forget_this_device.6bddebb5"),
            Content = new TextBlock
            {
                Text = L10n.Text("windows.machinespage.it_is_removed_from_this_machine_s_peer_lis.0fe4b5c8"),
                TextWrapping = TextWrapping.Wrap,
            },
            PrimaryButtonText = L10n.Text("windows.machinespage.forget.a6bd489d"),
            CloseButtonText = L10n.Text("windows.machinespage.keep_it.fdce5da2"),
            DefaultButton = ContentDialogButton.Close,
        };
        if (await Chrome.ShowDialog(this, dialog) != ContentDialogResult.Primary)
        {
            return;
        }
        try
        {
            await AppServices.Host.CallAsync("machine.forget", new JsonObject { ["key"] = key });
            _notice = L10n.Text("windows.machinespage.0_is_forgotten_it_will_arrive_as_a_strange.c48a4600", $"{name}");
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
        var box = new TextBox { Text = current, PlaceholderText = L10n.Text("windows.machinespage.device_name.155106be") };
        var dialog = new ContentDialog
        {
            Title = L10n.Text("windows.machinespage.rename_this_pc.60611f8e"),
            Content = box,
            PrimaryButtonText = L10n.Text("common.save"),
            CloseButtonText = L10n.Text("common.cancel"),
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
            ? L10n.Text("windows.machinespage.back_to_the_name_this_computer_already_had.574b11b2")
            : L10n.Text("windows.machinespage.other_devices_will_see_this_one_as_0.e25cb345", $"{renamed}");
        await LoadAsync();
    }

    /// <summary>
    /// Call another device on this account something. Renames the account row,
    /// not that machine's own file: the point is that a headless server nobody
    /// can log into is still nameable from here.
    /// </summary>
    private async Task RenameAsync(string id, string current, bool isSelf)
    {
        var box = new TextBox { Text = current, PlaceholderText = L10n.Text("windows.machinespage.device_name.155106be") };
        var dialog = new ContentDialog
        {
            Title = isSelf ? L10n.Text("windows.machinespage.rename_this_pc.60611f8e") : L10n.Text("windows.machinespage.rename_device.e378076e"),
            Content = box,
            PrimaryButtonText = L10n.Text("common.save"),
            CloseButtonText = L10n.Text("common.cancel"),
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
            ? L10n.Text("windows.machinespage.back_to_the_name_that_device_gives_itself.ef51c3b6")
            : L10n.Text("windows.machinespage.every_screen_on_this_account_calls_it_0_no.d72bed77", $"{name}");
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
            Title = L10n.Text("windows.machinespage.remove_from_account.a3010e43"),
            Content = new TextBlock
            {
                Text = L10n.Text("windows.machinespage.0_will_be_removed_from_this_account_and_it.d003b06e", $"{name}"),
                TextWrapping = TextWrapping.Wrap,
            },
            PrimaryButtonText = L10n.Text("common.remove"),
            CloseButtonText = L10n.Text("common.cancel"),
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
        _notice = L10n.Text("windows.machinespage.0_removed_from_the_account.008c6cc8", $"{name}");
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
