// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Tokenstat.Navigation;

namespace Tokenstat.Pages;

/// <summary>A viewer of the project's one terminal tree, beside chat or in Terminals.</summary>
internal sealed class WorkspaceTerminalPane : Page, IInspectorContent, IToolbarItems
{
    private readonly WorkspaceTerminalController _controller;
    internal WorkspaceTerminalPane(WorkspaceTerminalController controller)
    {
        _controller = controller;
        Loaded += (_, _) => _controller.Activate(this);
        Unloaded += (_, _) => _controller.Deactivate(this);
        _controller.Changed += () => ToolbarChanged?.Invoke();
    }
    public UIElement? Inspector => (_controller.ActivePage as IInspectorContent)?.Inspector;
    public UIElement? ToolbarScope => (_controller.ActivePage as IToolbarItems)?.ToolbarScope;
    public IList<UIElement> ToolbarActions() => _controller.ToolbarActions();
    public event Action? ToolbarChanged;
}

/// <summary>CLI and SSH share positions and one emulator per session across both viewers.</summary>
internal sealed class WorkspaceTerminalController
{
    private sealed record Entry(Page Page, Func<string> Title);
    private readonly string _workspaceId;
    private readonly Dictionary<string, Entry> _entries = new();
    private readonly TerminalPaneSelection _selection = new();
    private readonly Grid _root = new();
    private readonly Grid _body = new();
    private readonly StackPanel _tabs = new() { Orientation = Orientation.Horizontal, Spacing = 6 };
    private readonly SharedTerminalTree _tree;
    private string _layout = "single";
    private double _fraction = 0.5;
    private bool _restored;
    private bool _startingShell;
    private bool _released;
    private Window? _window;
    public event Action? Changed;
    private string[] IDs => _entries.Keys.ToArray();
    public Page? ActivePage => _selection.Active(IDs) is string id && _entries.TryGetValue(id, out var entry) ? entry.Page : null;

    internal WorkspaceTerminalController(string workspaceId)
    {
        _workspaceId = workspaceId;
        _tree = new(_root);
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _root.Children.Add(new ScrollViewer { Content = _tabs, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled, Padding = new Thickness(8) });
        Grid.SetRow(_body, 1); _root.Children.Add(_body);
        _window = App.CurrentWindow;
        if (_window is not null) _window.Closed += WindowClosed;
        WorkspaceSshTabs.Changed += AssociationsChanged;
    }
    private void AssociationsChanged()
    {
        if (_released) return;
        var associated = WorkspaceSshTabs.In(_workspaceId);
        var stale = _entries.Keys.Where(id => id.StartsWith("ssh:", StringComparison.Ordinal) && !associated.Contains(id[4..])).ToArray();
        // Removal can notify other project controllers. Finish this snapshot
        // without publishing another association event or rendering midway.
        foreach (var id in stale) Remove(id, forgetAssociation: false, render: false);
        if (stale.Length > 0) Render();
    }
    private void WindowClosed(object sender, WindowEventArgs args) => Release();
    private void Release()
    {
        if (_released) return;
        _released = true;
        if (_window is not null) { _window.Closed -= WindowClosed; _window = null; }
        WorkspaceSshTabs.Changed -= AssociationsChanged;
        foreach (var entry in _entries.Values)
        {
            if (entry.Page is TerminalPage local) local.Release();
            if (entry.Page is SshPage remote) remote.ReleaseViewer();
        }
        _entries.Clear();
        _body.Children.Clear();
    }
    internal void Activate(WorkspaceTerminalPane owner)
    {
        if (_released) return;
        // An empty wrapper claims the tree after loading, so switching from
        // chat to the main tab never attaches a native page to two parents.
        _tree.Attach(owner);
        Render();
        _ = RestoreAsync();
    }
    internal void Deactivate(WorkspaceTerminalPane owner)
    {
        _tree.Detach(owner);
    }
    private async Task RestoreAsync()
    {
        if (_released || _restored) return;
        _restored = true;
        try
        {
            var locals = Format.Items(await AppServices.Host.CallAsync("pty.list")) ?? new JsonArray();
            if (_released) return;
            foreach (var local in locals.Where(item => Format.Text(item, "workspaceId") == _workspaceId && !Format.Flag(item, "hidden")))
            {
                var id = Format.Text(local, "id");
                if (id.Length > 0) AddLocal(id, select: false);
            }
            var remotes = Format.Items(await AppServices.Host.CallAsync("ssh.session.list")) ?? new JsonArray();
            if (_released) return;
            foreach (var remote in remotes.Where(item => Format.Flag(item, "alive") && WorkspaceSshTabs.In(_workspaceId).Contains(Format.Text(item, "id"))).OfType<JsonNode>())
                AddSSH(remote, select: false);
        }
        catch { _restored = false; /* The launcher remains available on a missed read. */ }
        Render();
    }
    public void AddLocal(string id, bool select = true)
    {
        if (_released) return;
        // Sidebar reads can discover a respawned host ID before the old
        // page's queued metadata notification arrives.
        var retained = _entries.FirstOrDefault(pair => pair.Value.Page is TerminalPage page && page.SessionId == id);
        if (retained.Key is not null && retained.Key != id) RenameLocal(retained.Key, id, (TerminalPage)retained.Value.Page);
        if (!_entries.ContainsKey(id))
        {
            var page = new TerminalPage(_workspaceId, id) { ShouldFocus = false, RetainOnUnload = true };
            Register(id, page, () => page.TabTitle);
            page.ToolbarChanged += () => LocalChanged(page);
        }
        if (select) Select(id);
    }
    private void LocalChanged(TerminalPage page)
    {
        if (_released) return;
        var key = _entries.FirstOrDefault(pair => ReferenceEquals(pair.Value.Page, page)).Key;
        if (key is null) return; // A late metadata read cannot revive a closed tab.
        if (page.SessionId.Length > 0 && key != page.SessionId)
        {
            RenameLocal(key, page.SessionId, page);
            Render();
        }
        else { RenderTabs(); Changed?.Invoke(); }
    }
    private void RenameLocal(string oldId, string id, TerminalPage page)
    {
        if (!_entries.TryGetValue(oldId, out var entry) || !ReferenceEquals(entry.Page, page)) return;
        if (_entries.Remove(id, out var duplicate))
        {
            _body.Children.Remove(duplicate.Page);
            if (duplicate.Page is TerminalPage other)
                other.Release(detachSession: !other.SharesSessionWith(page));
        }
        _entries.Remove(oldId);
        _entries[id] = entry;
        _selection.Rename(oldId, id);
        if (_selection.Leading is not null && _selection.Leading == _selection.Trailing)
        {
            _layout = "single";
            _selection.SetSplit(false, IDs);
        }
    }
    private void Register(string id, Page page, Func<string> title)
    {
        _entries.Add(id, new(page, title));
        page.GotFocus += (_, _) =>
        {
            var key = _entries.FirstOrDefault(pair => ReferenceEquals(pair.Value.Page, page)).Key;
            if (key is not null && _selection.Active(IDs) != key) Select(key, focus: false);
        };
    }
    public async Task StartShellAsync()
    {
        if (_startingShell) return;
        _startingShell = true;
        try
        {
            var catalog = RemoteWorkspaces.TrySplit(_workspaceId, out var peer, out _)
                ? await RemoteWorkspaces.CallOnPeerAsync(peer, "launcher.catalog") : await AppServices.Host.CallAsync("launcher.catalog");
            var shell = Format.Items(catalog)?.FirstOrDefault(item => Format.Text(item, "id") == "shell")
                ?? throw new InvalidOperationException(L10n.Text("windows.terminalsession.the_host_did_not_advertise_an_available_sh.9e1e6520"));
            var opened = await AppServices.Host.CallAsync("pty.spawn", new JsonObject { ["workspaceId"] = _workspaceId,
                ["command"] = Format.Text(shell, "command"), ["args"] = shell?["args"]?.DeepClone() ?? new JsonArray(), ["rows"] = 30, ["cols"] = 100, ["dark"] = Theme.IsDark });
            var id = Format.Text(opened, "id");
            if (id.Length == 0) throw new InvalidOperationException(L10n.Text("windows.workspacepage.the_host_did_not_return_a_session.8a4eda9a"));
            AddLocal(id);
        }
        catch (Exception ex) { Banner(ex.Message); }
        finally { _startingShell = false; }
    }
    public void OpenInSplit(string id)
    {
        if (!_entries.ContainsKey(id)) return;
        if (_layout == "single") { _layout = "side"; _selection.SetSplit(true, IDs); }
        _selection.SendToOtherHalf(id, IDs);
        Render();
    }
    public async Task OpenSSHAsync(string id, bool inSplit = false)
    {
        if (_entries.ContainsKey("ssh:" + id)) { if (inSplit) OpenInSplit("ssh:" + id); else Select("ssh:" + id); return; }
        try
        {
            var sessions = Format.Items(await AppServices.Host.CallAsync("ssh.session.list"));
            var session = sessions?.FirstOrDefault(item => Format.Text(item, "id") == id && Format.Flag(item, "alive"));
            if (session is not null) { AddSSH(session, select: !inSplit); if (inSplit) OpenInSplit("ssh:" + id); }
        }
        catch (Exception ex) { Banner(ex.Message); }
    }
    private void AddSSH(JsonNode session, bool select = true)
    {
        if (_released) return;
        var id = Format.Text(session, "id");
        var key = "ssh:" + id;
        if (!_entries.ContainsKey(key))
        {
            var title = SshHostPlatform.SessionLabel(session);
            var page = new SshPage(SSHSection.Hosts, id, terminalOnly: true) { ShouldFocus = false, RetainOnUnload = true };
            Register(key, page, () => title);
            page.ConnectionCancelled += () => Remove(key);
        }
        WorkspaceSshTabs.Attach(_workspaceId, id);
        if (select) Select(key);
    }
    public async Task OpenServerAsync(JsonNode host)
    {
        if (_released) return;
        var sessions = Format.Items(await AppServices.Host.CallAsync("ssh.session.list"));
        if (_released) return;
        var live = sessions?.FirstOrDefault(item => Format.Flag(item, "alive") && Format.Text(item, "hostId") == Format.Text(host, "id"));
        if (live is not null) { AddSSH(live); return; }
        var key = "connecting:" + Guid.NewGuid();
        var title = ServerLauncher.Name(host);
        var page = new SshPage(SSHSection.Hosts, connectHost: host, terminalOnly: true) { ShouldFocus = false, RetainOnUnload = true };
        Register(key, page, () => title);
        page.ConnectionOpened += id =>
        {
            var next = "ssh:" + id;
            if (!_entries.TryGetValue(key, out var entry)) return;
            _entries.Remove(key); _entries[next] = entry;
            _selection.Rename(key, next);
            key = next;
            WorkspaceSshTabs.Attach(_workspaceId, id);
            Render();
        };
        page.ConnectionCancelled += () => Remove(key);
        Select(key);
    }
    private void Select(string id, bool focus = true)
    {
        _selection.Select(id, IDs, _layout != "single");
        Render(focus);
    }
    private void Remove(string id, bool forgetAssociation = true, bool render = true)
    {
        if (!_entries.Remove(id, out var entry)) return;
        if (forgetAssociation && id.StartsWith("ssh:", StringComparison.Ordinal)) WorkspaceSshTabs.Remove(id[4..]);
        _body.Children.Remove(entry.Page);
        if (entry.Page is TerminalPage local) local.Release();
        if (entry.Page is SshPage remote) remote.ReleaseViewer();
        if (_selection.Reconcile(IDs)) _layout = "single";
        if (render) Render();
    }
    private async Task CloseAsync(string id)
    {
        if (!_entries.TryGetValue(id, out var entry)) return;
        if (entry.Page is TerminalPage { IsSessionClosed: true }) { Remove(id); return; }
        if (id.StartsWith("connecting:", StringComparison.Ordinal)) { Remove(id); return; }
        var confirm = new ContentDialog
        {
            Title = L10n.Text("windows.sidebarlive.stop_this_session.5efe50c8"),
            Content = L10n.Text("windows.mainwindow_xaml.the_shell_will_stop.9beb2839"),
            PrimaryButtonText = L10n.Text("windows.mainwindow_xaml.close_session.e503367c"),
            CloseButtonText = L10n.Text("windows.mainwindow_xaml.keep_running.154949db"),
            DefaultButton = ContentDialogButton.Close,
        };
        if (await Chrome.ShowDialog(_root, confirm) != ContentDialogResult.Primary) return;
        var remote = id.StartsWith("ssh:", StringComparison.Ordinal);
        await AppServices.Host.CallAsync(remote ? "ssh.session.close" : "pty.close", new JsonObject { ["id"] = remote ? id[4..] : id });
        Remove(id);
    }
    private void Render(bool focus = true)
    {
        if (_released) return;
        var panes = _selection.Panes(IDs, _layout != "single");
        var visible = new[] { panes.Leading, panes.Trailing }.Where(id => id is not null).ToHashSet();
        foreach (var child in _body.Children.OfType<Page>().ToArray())
        {
            child.Visibility = _entries.Any(pair => visible.Contains(pair.Key) && ReferenceEquals(pair.Value.Page, child))
                ? Visibility.Visible : Visibility.Collapsed;
            if (child.Visibility == Visibility.Collapsed)
            {
                if (child is TerminalPage local) local.ShouldFocus = false;
                if (child is SshPage remote) remote.ShouldFocus = false;
            }
        }
        foreach (var child in _body.Children.Where(child => child is not Page).ToArray()) _body.Children.Remove(child);
        _body.ColumnDefinitions.Clear(); _body.RowDefinitions.Clear();
        var split = _layout != "single";
        var definitions = split && _layout == "side" ? _body.ColumnDefinitions : null;
        if (definitions is not null)
        {
            definitions.Add(new ColumnDefinition { Width = new GridLength(_fraction, GridUnitType.Star) });
            definitions.Add(new ColumnDefinition { Width = new GridLength(6) });
            definitions.Add(new ColumnDefinition { Width = new GridLength(1 - _fraction, GridUnitType.Star) });
        }
        else if (split)
        {
            _body.RowDefinitions.Add(new RowDefinition { Height = new GridLength(_fraction, GridUnitType.Star) });
            _body.RowDefinitions.Add(new RowDefinition { Height = new GridLength(6) });
            _body.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1 - _fraction, GridUnitType.Star) });
        }
        foreach (var (id, position) in new[] { (panes.Leading, 0), (panes.Trailing, 2) })
        {
            if (id is null || !_entries.TryGetValue(id, out var entry)) continue;
            entry.Page.Visibility = Visibility.Visible;
            Grid.SetColumn(entry.Page, split && _layout == "side" ? position : 0);
            Grid.SetRow(entry.Page, split && _layout == "stacked" ? position : 0);
            var focused = id == _selection.Active(IDs);
            if (entry.Page is TerminalPage local) local.ShouldFocus = focused;
            if (entry.Page is SshPage remote) remote.ShouldFocus = focused;
            if (!_body.Children.Contains(entry.Page)) _body.Children.Add(entry.Page);
        }
        if (split)
        {
            var handle = new ResizeHandle(vertical: _layout == "stacked");
            Grid.SetColumn(handle, _layout == "side" ? 1 : 0);
            Grid.SetRow(handle, _layout == "stacked" ? 1 : 0);
            void SetFraction(double fraction)
            {
                _fraction = Math.Clamp(fraction, 0.2, 0.8);
                if (_layout == "side") { _body.ColumnDefinitions[0].Width = new(_fraction, GridUnitType.Star); _body.ColumnDefinitions[2].Width = new(1 - _fraction, GridUnitType.Star); }
                else { _body.RowDefinitions[0].Height = new(_fraction, GridUnitType.Star); _body.RowDefinitions[2].Height = new(1 - _fraction, GridUnitType.Star); }
            }
            handle.DragDelta += (_, e) =>
            {
                var length = _layout == "side" ? _body.ActualWidth : _body.ActualHeight;
                if (length > 0) SetFraction(_fraction + (_layout == "side" ? e.HorizontalChange : e.VerticalChange) / length);
            };
            handle.DoubleTapped += (_, _) => SetFraction(0.5);
            handle.KeyDown += (_, e) =>
            {
                var earlier = _layout == "side" ? Windows.System.VirtualKey.Left : Windows.System.VirtualKey.Up;
                var later = _layout == "side" ? Windows.System.VirtualKey.Right : Windows.System.VirtualKey.Down;
                if (e.Key != earlier && e.Key != later) return;
                SetFraction(_fraction + (e.Key == earlier ? -0.04 : 0.04)); e.Handled = true;
            };
            _body.Children.Add(handle);
        }
        if (_entries.Count == 0) _body.Children.Add(new TextBlock { Text = L10n.Text("windows.terminalpane.choose_terminal"),
            TextWrapping = TextWrapping.Wrap, Opacity = 0.7, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center });
        RenderTabs(); Changed?.Invoke();
        if (focus && _tree.Owner?.IsLoaded == true)
        {
            if (ActivePage is TerminalPage local) local.FocusTerminal();
            if (ActivePage is SshPage remote) remote.FocusTerminal();
        }
    }
    private void RenderTabs()
    {
        _tabs.Children.Clear();
        var panes = _selection.Panes(IDs, _layout != "single");
        foreach (var (id, entry) in _entries)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
            row.Children.Add(new FontIcon { Glyph = id.StartsWith("ssh:") || id.StartsWith("connecting:") ? "\uE968" : "\uE756", FontSize = 14 });
            row.Children.Add(new TextBlock { Text = entry.Title(), MaxWidth = 180, TextTrimming = TextTrimming.CharacterEllipsis });
            var button = new Button { Content = row, Background = id == _selection.Active(IDs) ? Theme.AccentSoftBrush : Theme.PanelBrush,
                BorderBrush = id == panes.Leading || id == panes.Trailing ? Theme.AccentBrush : Theme.BorderBrush };
            button.Click += (_, _) => Select(id);
            var menu = ContextMenus.Menu(button);
            ContextMenus.Add(menu, L10n.Text("windows.terminalpane.open_in_split"), () =>
            {
                if (_layout == "single") { _layout = "side"; _selection.SetSplit(true, IDs); }
                _selection.SendToOtherHalf(id, IDs); Render();
            });
            ContextMenus.AddAsync(menu, L10n.Text("windows.mainwindow_xaml.close_session.03362c26"), () => CloseAsync(id));
            _tabs.Children.Add(button);
        }
    }
    internal IList<UIElement> ToolbarActions()
    {
        var actions = new List<UIElement>();
        var create = Buttons.ToolbarIcon(ActionIcon.Create, L10n.Text("windows.terminalpane.new_terminal"), (_, _) => { });
        var launches = new MenuFlyout();
        ContextMenus.AddAsync(launches, L10n.Text("windows.terminalpage.shell.a7332854"), StartShellAsync);
        var servers = new MenuFlyoutSubItem { Text = L10n.Text("windows.serverlauncher.servers") };
        launches.Items.Add(servers);
        launches.Opening += async (_, _) =>
        {
            servers.Items.Clear();
            try
            {
                foreach (var host in await ServerLauncher.HostsAsync())
                {
                    var item = new MenuFlyoutItem { Text = ServerLauncher.Name(host) };
                    item.Click += async (_, _) => { try { await OpenServerAsync(host); } catch (Exception ex) { Banner(ex.Message); } };
                    servers.Items.Add(item);
                }
            }
            catch (Exception ex) { Banner(ex.Message); }
            servers.IsEnabled = servers.Items.Count > 0;
        };
        create.Flyout = launches; actions.Add(create);
        var split = Buttons.ToolbarIcon(ActionIcon.Compare, L10n.Text("windows.terminalpane.split"), (_, _) => { });
        var menu = new MenuFlyout();
        foreach (var (kind, label) in new[] { ("single", L10n.Text("windows.terminalpane.single")), ("side", L10n.Text("windows.terminalpane.side_by_side")), ("stacked", L10n.Text("windows.terminalpane.stacked")) })
            ContextMenus.Add(menu, label, () => { _layout = kind; _selection.SetSplit(kind != "single", IDs); Render(); });
        var swap = ContextMenus.Add(menu, _layout == "stacked" ? L10n.Text("windows.terminalpane.swap_top_and_bottom") : L10n.Text("windows.terminalpane.swap_left_and_right"), () => { _selection.Swap(IDs); Render(); },
            () => _layout != "single" && _selection.Panes(IDs, true).Trailing is not null);
        menu.Opening += (_, _) => swap.Text = _layout == "stacked" ? L10n.Text("windows.terminalpane.swap_top_and_bottom") : L10n.Text("windows.terminalpane.swap_left_and_right");
        split.Flyout = menu; actions.Add(split);
        actions.AddRange((ActivePage as IToolbarItems)?.ToolbarActions() ?? new List<UIElement>());
        return actions;
    }
    private void Banner(string message)
    {
        _body.Children.Add(Chrome.Banner(FriendlyError.Display(message), Theme.Danger, Symbol.Important));
    }
}
