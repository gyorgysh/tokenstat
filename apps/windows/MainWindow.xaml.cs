// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Text.Json.Nodes;
using System.Runtime.InteropServices;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Tokenstat.Design;
using Tokenstat.Navigation;
using Tokenstat.Pages;
using Windows.Graphics;
using WinRT.Interop;

namespace Tokenstat;

public sealed partial class MainWindow : Window
{
    private static bool _windowMotionSuspended;
    internal static bool ColumnsResizing { get; set; }
    internal static bool MotionSuspended => _windowMotionSuspended || ColumnsResizing;
    private bool _windowActive = true;
    private bool _resizing;

    private readonly NavigationView _nav = new();
    private const double RailWidth = 56;
    private readonly ResizeHandle _paneResize = new();
    private readonly Border _railFooter = new() { Margin = new Thickness(4, 8, 4, 8) };
    private bool _nativeBackdrop;
    private readonly Dictionary<string, Button> _pinnedNavigation = new();
    private readonly Dictionary<string, bool> _chatGroupExpansion = new();
    private readonly Frame _frame = new();
    /// <summary>
    /// The content area behind the frame. Opaque Background tone, so the
    /// NavigationView content grid never shows its default grey through.
    /// </summary>
    private readonly Border _contentHost = new();
    /// <summary>
    /// The content body: the global toolbar above, the inspector host below.
    /// One toolbar for the window rather than one per page, mirroring the Mac
    /// detail chrome, which carries the same search and inspector marks.
    /// </summary>
    private readonly Grid _bodyGrid = new();
    /// <summary>The slot the toolbar rebuilds into on navigation and theme change.</summary>
    private readonly Border _toolbarSlot = new();
    private readonly InspectorHost _inspectorHost = new();
    /// <summary>
    /// What the toolbar scope picker asks reports to count. Every device by
    /// default, like the Mac and the Home page: a person with two machines
    /// wants their year, not one PC's share of it.
    /// </summary>
    private DeviceScope _scope = DeviceScopeNames.Restore();
    // One brush instance per flat surface, shared by every element showing
    // that tone. A theme change mutates the color in place, which reaches the
    // NavigationView template too: a StaticResource lookup would keep a
    // replaced brush, but it cannot keep a mutated one.
    private readonly SolidColorBrush _chromeBackground = new(Theme.Background);
    private readonly SolidColorBrush _chromeSidebar = new(Theme.Sidebar);
    private readonly SolidColorBrush _chromeBorder = new(Theme.Border);
    private Windows.UI.ViewManagement.UISettings? _chromeSettings;
    private Windows.UI.ViewManagement.AccessibilitySettings? _accessibilitySettings;
    private readonly NavigationViewItemHeader _globalHeader = new()
    {
        Content = "GLOBAL",
    };
    private readonly NavigationViewItemHeader _workspacesHeader = new()
    {
        Content = "WORKSPACES",
    };
    private UIElement? _hostSplash;
    /// <summary>
    /// Folders whose sidebar chat list is showing ten instead of five, like
    /// the Mac expanded chat histories.
    /// </summary>
    private readonly HashSet<string> _liveChatExpanded = new(StringComparer.Ordinal);
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? _sidebarPoll;
    private int _sidebarTick;
    private bool _sidebarRefreshing;
    private bool _sidebarSlowRefreshPending;
    private bool _suppressNav;
    private string? _lastNavTag;
    private JsonArray _liveSessions = new();
    private JsonArray _liveChats = new();
    private Dictionary<string, JsonNode> _liveSummaries = new(StringComparer.Ordinal);
    private JsonNode? _liveAccount;
    private string _liveFooterKey = "";

    private readonly HashSet<string> _compactExpanded = new(StringComparer.Ordinal);

    private void PaneStateChanged()
    {
        SyncPaneChrome();
        // Do not mutate IsExpanded inside the IsPaneOpen callback.
        DispatcherQueue.TryEnqueue(ApplyCompactExpansion);
    }

    private void ApplyCompactExpansion()
    {
        if (!_nav.IsPaneOpen)
        {
            foreach (var row in NavItems(_nav.MenuItems))
            {
                if (row.IsExpanded && row.Tag is string tag) _compactExpanded.Add(tag);
                if (row.Tag is string) row.IsExpanded = false;
            }
        }
        else
        {
            foreach (var row in NavItems(_nav.MenuItems))
                if (row.Tag is string tag && _compactExpanded.Contains(tag)) row.IsExpanded = true;
            _compactExpanded.Clear();
        }
        SyncPaneChrome();
    }

    public MainWindow()
    {
        InitializeComponent();
        Title = "tokenstat";
        TryExtendIntoTitleBar();
        TrySize();
        TryIcon();
        var resizeSettled = DispatcherQueue.CreateTimer();
        resizeSettled.Interval = TimeSpan.FromMilliseconds(160);
        resizeSettled.IsRepeating = false;
        resizeSettled.Tick += (_, _) => { _resizing = false; _windowMotionSuspended = !_windowActive; };
        AppWindow.Changed += (_, change) =>
        {
            if (!change.DidSizeChange) return;
            _resizing = true;
            _windowMotionSuspended = true;
            resizeSettled.Stop();
            resizeSettled.Start();
        };
        Activated += (_, change) =>
        {
            _windowActive = change.WindowActivationState != WindowActivationState.Deactivated;
            _windowMotionSuspended = !_windowActive || _resizing;
        };
        Closed += (_, _) => resizeSettled.Stop();

        // Only the project pane exposes the system frost. Content and the
        // navigation rail keep an opaque background.
        try { SystemBackdrop = new DesktopAcrylicBackdrop(); _nativeBackdrop = true; }
        catch { _nativeBackdrop = false; }
        RootGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(RailWidth) });
        RootGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        Grid.SetColumnSpan(AppTitleBar, 2);
        RootGrid.Background = _nativeBackdrop ? new SolidColorBrush(Colors.Transparent) : _chromeBackground;
        TitlePaneSide.Background = _chromeSidebar;
        TitleContentSide.Background = _chromeBackground;
        _contentHost.Background = _chromeBackground;
        _bodyGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _bodyGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        Grid.SetRow(_toolbarSlot, 0);
        _bodyGrid.Children.Add(_toolbarSlot);
        Grid.SetRow(_inspectorHost, 1);
        _bodyGrid.Children.Add(_inspectorHost);
        _inspectorHost.SetContent(_frame);
        _contentHost.Child = _bodyGrid;
        RebuildToolbar();

        // NavigationView's native ContentPresenter does not template-bind
        // content alignment. Without this the entire workbench is measured
        // at its desired height (a WebView has no useful desired height).
        _nav.Loaded += (_, _) => StretchNavigationContent();
        _nav.ActualThemeChanged += (_, _) => StretchNavigationContent();
        _nav.IsSettingsVisible = false;
        _nav.OpenPaneLength = 280;
        _nav.CompactPaneLength = 0;
        _nav.IsPaneToggleButtonVisible = false;
        _nav.PaneDisplayMode = NavigationViewPaneDisplayMode.Left;
        _nav.IsBackButtonVisible = NavigationViewBackButtonVisible.Collapsed;
        _nav.Background = new SolidColorBrush(Colors.Transparent);
        _nav.Resources["NavigationViewDefaultPaneBackground"] = _chromeSidebar;
        _nav.Resources["NavigationViewExpandedPaneBackground"] = _chromeSidebar;
        _nav.Resources["NavigationViewContentBackground"] = _chromeBackground;
        _nav.Resources["NavigationViewContentGridBorderBrush"] = _chromeBorder;

        var pinned = new StackPanel { Spacing = 2, Margin = new Thickness(4, 0, 4, 8) };
        var togglePane = Buttons.ToolbarIcon(ActionIcon.Layout, "Show or hide projects", (_, _) => _nav.IsPaneOpen = !_nav.IsPaneOpen);
        pinned.Children.Add(togglePane);
        foreach (var section in Sections.Standalone.Concat(Sections.Everywhere))
        {
            var item = Item(section);
            item.Visibility = Visibility.Collapsed;
            _nav.MenuItems.Add(item);
            var tag = "global:" + section;
            var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 14 };
            content.Children.Add(GlobalIcon(section));

            var button = new Button { Content = content, HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Left, BorderThickness = new Thickness(0), Padding = new Thickness(12),
                Background = _chromeBackground, MinWidth = 0 };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, section.Label());
            button.Click += (_, _) => { if (ReferenceEquals(_nav.SelectedItem, item)) Show(tag); else _nav.SelectedItem = item; };
            ToolTipService.SetToolTip(button, section.Label());
            _pinnedNavigation[tag] = button;
            pinned.Children.Add(button);
        }
        var railBody = new Grid();
        railBody.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        railBody.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        railBody.Children.Add(new ScrollViewer { Content = pinned,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Hidden });
        Grid.SetRow(_railFooter, 1);
        railBody.Children.Add(_railFooter);
        var rail = new Border { Background = _chromeBackground, Child = railBody };
        Grid.SetRow(rail, 1);
        RootGrid.Children.Add(rail);
        _nav.MenuItems.Add(new NavigationViewItemSeparator());
        _nav.MenuItems.Add(SshGroup());
        _nav.MenuItems.Add(new NavigationViewItemSeparator());
        _nav.MenuItems.Add(_workspacesHeader);
        _nav.MenuItems.Add(new NavigationViewItem
        {
            Content = "All projects",
            Tag = "workspaces:all",
            Icon = new SymbolIcon { Symbol = Symbol.Folder },
        });
        _nav.MenuItems.Add(new NavigationViewItem
        {
            Content = "Add project",
            Tag = "workspaces:add",
            Icon = new SymbolIcon { Symbol = Symbol.Add },
        });

        // Search is a toolbar icon, like the Mac: it opens the search page from
        // anywhere without taking a row. Account and About live in the profile menu.
        RefreshAccountFooter();

        _nav.Content = _contentHost;
        _nav.SelectionChanged += NavOnSelectionChanged;
        Grid.SetRow(_nav, 1);
        Grid.SetColumn(_nav, 1);
        RootGrid.Children.Add(_nav);
        _paneResize.Width = 6;
        _paneResize.HorizontalAlignment = HorizontalAlignment.Left;
        _paneResize.Background = new SolidColorBrush(Colors.Transparent);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_paneResize, "Resize projects panel");
        _paneResize.DragDelta += (_, drag) =>
        {
            _nav.OpenPaneLength = Math.Clamp(_nav.OpenPaneLength + drag.HorizontalChange, 240, 420);
            SyncPaneChrome();
        };
        _paneResize.DoubleTapped += (_, _) => { _nav.OpenPaneLength = 280; SyncPaneChrome(); };
        _paneResize.KeyDown += (_, key) =>
        {
            if (key.Key is not (Windows.System.VirtualKey.Left or Windows.System.VirtualKey.Right)) return;
            _nav.OpenPaneLength = Math.Clamp(_nav.OpenPaneLength + (key.Key == Windows.System.VirtualKey.Right ? 16 : -16), 240, 420);
            SyncPaneChrome();
            key.Handled = true;
        };
        Grid.SetRow(_paneResize, 1);
        Grid.SetColumn(_paneResize, 1);
        RootGrid.Children.Add(_paneResize);
        ApplyChromeColors();
        RootGrid.ActualThemeChanged += (_, _) => ApplyChromeColors();
        try
        {
            _chromeSettings = new Windows.UI.ViewManagement.UISettings();
            _accessibilitySettings = new Windows.UI.ViewManagement.AccessibilitySettings();
            _chromeSettings.AdvancedEffectsEnabledChanged += OnAdvancedEffectsChanged;
            _accessibilitySettings.HighContrastChanged += OnHighContrastChanged;
            Closed += (_, _) =>
            {
                _chromeSettings.AdvancedEffectsEnabledChanged -= OnAdvancedEffectsChanged;
                _accessibilitySettings.HighContrastChanged -= OnHighContrastChanged;
            };
        }
        catch { /* Older systems keep the opaque fallback. */ }
        _contentHost.SizeChanged += (_, _) => SyncInspectorFit();
        // Keep the titlebar split on the pane edge when the pane collapses to
        // its compact width. The display mode itself is fixed at Left.
        _nav.RegisterPropertyChangedCallback(
            NavigationView.IsPaneOpenProperty,
            (_, _) => PaneStateChanged());

        AppServices.OpenTerminal = (workspaceId, sessionId) =>
        {
            DispatcherQueue.TryEnqueue(() =>
            {
                var workbench = WorkspaceTabs(workspaceId);
                workbench.OpenTerminal(sessionId);
                SetContent(workbench);
                if (sessionId is not null)
                    RestoreSelection(LiveRoute.Join(SidebarLive.SessionPrefix, workspaceId, sessionId));
                _lastNavTag = (_nav.SelectedItem as NavigationViewItem)?.Tag as string;
            });
        };
        AppServices.OpenBrowser = (url, host, port, unlisten, peer) =>
        {
            DispatcherQueue.TryEnqueue(() =>
            {
                if (_frame.Content is WorkspaceTabsPage workbench)
                    workbench.OpenBrowser(url, host, port, unlisten, peer);
                else SetContent(new BrowserPage(url, host, port, unlisten, peer));
            });
        };
        AppServices.OpenScreen = (peer, name) =>
        {
            DispatcherQueue.TryEnqueue(() =>
            {
                SetContent(new ScreenPage(peer, name));
            });
        };
        AppServices.OpenOnboarding = () =>
        {
            DispatcherQueue.TryEnqueue(() => ShowOnboarding(firstRun: false));
        };
        AppServices.OpenMachine = id => DispatcherQueue.TryEnqueue(() =>
        {
            NavigateTo("global:Machines");
            SetContent(new MachinesPage(id));
        });
        AppServices.OpenWorkspace = (workspaceId, section) =>
        {
            DispatcherQueue.TryEnqueue(() =>
            {
                NavigateTo("ws:" + workspaceId + ":" + section);
            });
        };
        AppServices.OpenConversation = (workspaceId, chatId) =>
        {
            DispatcherQueue.TryEnqueue(() =>
            {
                var workbench = WorkspaceTabs(workspaceId);
                workbench.Open(WorkspaceSection.Chat);
                SetContent(workbench);
                if (workbench.ActivePage is ChatPage page) _ = page.RevealAsync(chatId);
            });
        };
        AppServices.OpenInsightsDay = (date) =>
        {
            DispatcherQueue.TryEnqueue(() =>
            {
                // A day is a local-archive query, so the scope goes to This
                // device first: the account cuts cannot show one day. Then
                // through the sidebar row, so the pane and the content agree,
                // and the day pins onto the mounted page like the Mac
                // heatmap tap.
                SetScope("local");
                const string tag = "global:Insights";
                if (FindNavItem(tag) is NavigationViewItem row)
                {
                    _nav.SelectedItem = row;
                    if (_frame.Content is InsightsPage page)
                    {
                        _ = page.FocusDayAsync(date);
                    }
                }
                else
                {
                    SetContent(new InsightsPage(date));
                }
            });
        };

        if (_nav.MenuItems[0] is NavigationViewItem first)
        {
            _nav.SelectedItem = first;
        }

        // First frame is the brand on paper, before the helper has answered.
        ShowHostSplash(null);
        _ = BootAsync();
        // Live sidebar rows, like the Mac watcher: sessions and chats every
        // ten seconds, counts and the account footer every minute.
        _sidebarPoll = DispatcherQueue.CreateTimer();
        _sidebarPoll.Interval = TimeSpan.FromSeconds(10);
        _sidebarPoll.Tick += (_, _) =>
        {
            _sidebarTick++;
            _ = RefreshSidebarLiveAsync(slow: _sidebarTick % 6 == 0);
        };
        _sidebarPoll.Start();
        RemoteWorkspaces.Changed += () => DispatcherQueue.TryEnqueue(() =>
        {
            RebuildFolderItems();
            RebuildSidebarLive();
        });
        AppServices.AccountChanged += () => DispatcherQueue.TryEnqueue(() => _ = RefreshSidebarLiveAsync(slow: true));
        AppServices.Update.Changed += () => DispatcherQueue.TryEnqueue(RefreshUpdateBadge);
    }

    private static IconElement GlobalIcon(GlobalSection section) => section switch
    {
        GlobalSection.Home => new FontIcon { Glyph = "\uE80A" },
        GlobalSection.Machines => new FontIcon { Glyph = char.ToString((char)0xE770), FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets") },
        GlobalSection.Notes => new SymbolIcon(Symbol.Document),
        GlobalSection.Automations => new FontIcon { Glyph = char.ToString((char)0xE945), FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets") },
        _ => new SymbolIcon(section.Symbol()),
    };

    private static NavigationViewItem Item(GlobalSection section)
    {
        return new NavigationViewItem
        {
            Content = section.Label(),
            Tag = "global:" + section,
            Icon = GlobalIcon(section),
        };
    }

    /// <summary>
    /// The SSH library as an expandable group, one row per section like the
    /// Mac sidebar. The parent carries the Hosts tag so invoking it lands on
    /// the Hosts screen rather than nowhere.
    /// </summary>
    private static NavigationViewItem SshGroup()
    {
        var parent = new NavigationViewItem
        {
            Content = GlobalSection.Ssh.Label(),
            Tag = "ssh:" + SSHSection.Hosts,
            Icon = new SymbolIcon { Symbol = GlobalSection.Ssh.Symbol() },
        };
        foreach (var section in Sections.SshRows)
        {
            parent.MenuItems.Add(new NavigationViewItem
            {
                Content = section.Label(),
                Icon = new FontIcon { Glyph = section switch
                {
                    SSHSection.Hosts => "\uE968",
                    SSHSection.Keys => "\uE8D7",
                    SSHSection.Snippets => "\uE8A9",
                    SSHSection.KnownHosts => "\uEA18",
                    _ => "\uE72E",
                } },
                Tag = "ssh:" + section,
            });
        }
        return parent;
    }

    /// <summary>
    /// Launch in the Mac's beats: splash while the helper comes up, then the
    /// real window, where pages draw wireframes while their own loads land.
    /// Bounded like the Mac host deadline: after eight seconds the app shows
    /// anyway, and the folder rows fill in behind it when the helper answers.
    /// </summary>
    private async Task BootAsync()
    {
        var started = DateTime.UtcNow;
        var deadline = started.AddSeconds(8);
        while (DateTime.UtcNow < deadline)
        {
            try
            {
                // A real method answering, not only a pipe that exists.
                await AppServices.Host.CallAsync("info", patience: TimeSpan.FromSeconds(2));
                break;
            }
            catch (Exception ex)
            {
                var info = FriendlyError.From(ex.Message);
                DispatcherQueue.TryEnqueue(() => ShowHostSplash(info));
                // Try again shortens the wait. One loop only: the button
                // wakes this wait rather than starting a second loop.
                _hostWake = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                await Task.WhenAny(Task.Delay(250), _hostWake.Task);
            }
        }
        DispatcherQueue.TryEnqueue(() =>
        {
            if (ReferenceEquals(_frame.Content, _hostSplash)
                && _nav.SelectedItem is NavigationViewItem selected
                && selected.Tag is string tag)
            {
                Show(tag);
            }
            _hostSplash = null;
            if (!OnboardingState.HasOnboarded)
            {
                ShowOnboarding(firstRun: true);
            }
            _ = RefreshSidebarLiveAsync(slow: true);
        });
        await TryLoadFoldersAsync();
    }

    private readonly SemaphoreSlim _folderLoadGate = new(1, 1);
    private bool _foldersLoaded;
    private JsonArray _localFolders = new();

    /// <summary>
    /// The folder rows under Workspaces. Runs once after boot mounts content,
    /// then again on every slow sidebar poll until it lands, so a helper that
    /// answers late still fills the sidebar in. A miss keeps the old rows.
    /// </summary>
    private async Task TryLoadFoldersAsync(bool refresh = false)
    {
        await _folderLoadGate.WaitAsync();
        try
        {
            if (_foldersLoaded && !refresh)
            {
                return;
            }
            JsonNode listed;
            try
            {
                listed = await AppServices.Host.CallAsync("workspace.list");
            }
            catch
            {
                return;
            }
            var array = listed as JsonArray
                ?? listed["folders"] as JsonArray
                ?? listed["workspaces"] as JsonArray;
            if (array is null)
            {
                return;
            }
            var unchanged = _foldersLoaded && JsonNode.DeepEquals(_localFolders, array);
            _foldersLoaded = true;
            if (unchanged) return;
            _localFolders = array;
            DispatcherQueue.TryEnqueue(() =>
            {
                RebuildFolderItems();
                RebuildSidebarLive();
            });
            _ = RemoteWorkspaces.SweepAsync();
        }
        finally { _folderLoadGate.Release(); }
    }

    /// <summary>
    /// Local folders and every reachable peer's, each with all sections. The
    /// Add workspace row stays last, under whatever folders exist.
    /// </summary>
    private void RebuildFolderItems()
    {
        var selectedTag = (_nav.SelectedItem as NavigationViewItem)?.Tag as string;
        var expanded = NavigationExpansion.Capture(NavItems(_nav.MenuItems));
        foreach (var pair in expanded.Where(pair => pair.Key.StartsWith("ws:") && pair.Key.EndsWith(":Chat")))
            _chatGroupExpansion[pair.Key] = pair.Value;
        var keep = new List<object>();
        foreach (var item in _nav.MenuItems)
        {
            if (item is NavigationViewItem nav
                && ((nav.Tag as string)?.StartsWith("ws:") == true
                    || (nav.Tag as string)?.StartsWith("machine:") == true
                    || (nav.Tag as string) == "workspaces:add"))
            {
                continue;
            }
            keep.Add(item);
        }
        _nav.MenuItems.Clear();
        foreach (var item in keep)
        {
            _nav.MenuItems.Add(item);
        }
        foreach (var folder in _localFolders)
        {
            var id = Format.Text(folder, "id");
            var name = Format.Text(folder, "name", Format.Text(folder, "path", id));
            if (string.IsNullOrEmpty(id))
            {
                continue;
            }
            _nav.MenuItems.Add(FolderParent(id, name, remote: false, Format.Text(folder, "path"), folder?["git"]));
        }
        foreach (var peer in RemoteWorkspaces.CachedFolders().GroupBy(folder => folder.PeerKey))
        {
            var machine = new NavigationViewItem
            {
                Content = peer.First().MachineLabel,
                Tag = "machine:" + peer.Key,
                Icon = new SymbolIcon { Symbol = Symbol.Globe },
                SelectsOnInvoked = false,
                IsExpanded = _nav.IsPaneOpen,
            };
            ToolTipService.SetToolTip(machine, peer.First().MachineLabel);
            foreach (var folder in peer)
                machine.MenuItems.Add(FolderParent(folder.Id, folder.Name, remote: true, folder.Path, folder.Git));
            _nav.MenuItems.Add(machine);
        }
        _nav.MenuItems.Add(new NavigationViewItem
        {
            Content = "Add project",
            Tag = "workspaces:add",
            Icon = new SymbolIcon { Symbol = Symbol.Add },
        });
        foreach (var item in NavItems(_nav.MenuItems))
        {
            if (item.MenuItems.Count > 0 && item.Tag is string tag && expanded.TryGetValue(tag, out var wasExpanded))
            {
                item.IsExpanded = wasExpanded;
            }
        }
        if (selectedTag is not null
            && ((_nav.SelectedItem as NavigationViewItem)?.Tag as string) != selectedTag
            && FindNavItem(selectedTag) is NavigationViewItem back)
        {
            _suppressNav = true;
            _nav.SelectedItem = back;
            _suppressNav = false;
        }
    }

    private NavigationViewItem FolderParent(string id, string name, bool remote, string path, JsonNode? git = null)
    {
        var parent = new NavigationViewItem
        {
            Content = FolderLabel(name, git),
            Tag = "ws:" + id + ":Launcher",
            Icon = new SymbolIcon { Symbol = remote ? Symbol.Globe : Symbol.Folder },
            IsExpanded = _nav.IsPaneOpen,
        };
        if (!string.IsNullOrEmpty(path))
        {
            ToolTipService.SetToolTip(parent, path);
        }
        foreach (var section in Enum.GetValues<WorkspaceSection>().Where(section => section != WorkspaceSection.Launcher))
        {
            parent.MenuItems.Add(new NavigationViewItem
            {
                Content = section.Label(),
                Icon = section.Action().Icon(),
                Tag = "ws:" + id + ":" + section,
            });
        }
        var menu = ContextMenus.Menu(parent);
        ContextMenus.Add(menu, "Open folder", () => NavigateTo("ws:" + id + ":Launcher"));
        ContextMenus.Copy(menu, "Copy path", () => path);
        if (Format.Flag(git, "isRepo"))
            ContextMenus.AddAsync(menu, "Worktrees…", async () =>
            {
                var created = await ProjectWorktreeDialog.ShowAsync(parent, id, name, path);
                if (created is null) return;
                if (remote) await RemoteWorkspaces.SweepAsync();
                await TryLoadFoldersAsync(refresh: true);
                NavigateTo("ws:" + created + ":Launcher");
            });
        if (!remote && !string.IsNullOrEmpty(path))
            ContextMenus.AddAsync(menu, "Reveal in File Explorer", async () =>
            {
                try { await Windows.System.Launcher.LaunchFolderAsync(await Windows.Storage.StorageFolder.GetFolderFromPathAsync(path)); }
                catch (Exception ex) { await Chrome.ShowDialog(parent, new ContentDialog { Title = "Could not open folder", Content = ex.Message, CloseButtonText = "Close" }); }
            });
        if (RemoteWorkspaces.TrySplit(id, out var peer, out _))
            ContextMenus.Add(menu, "Disconnect from this computer", () => RemoteWorkspaces.Disconnect(peer));
        ContextMenus.Add(menu, "Expand / collapse", () => parent.IsExpanded = !parent.IsExpanded);
        ContextMenus.AddAsync(menu, "Remove from tokenstat…", async () =>
        {
            var confirm = new ContentDialog { Title = "Remove this folder?", Content = "The folder and its files stay on disk.", PrimaryButtonText = "Remove", CloseButtonText = "Keep it", DefaultButton = ContentDialogButton.Close };
            if (await Chrome.ShowDialog(parent, confirm) != ContentDialogResult.Primary) return;
            try
            {
                await RemoteWorkspaces.CallWorkspaceAsync(id, "workspace.remove", new JsonObject { ["id"] = id });
                await TryLoadFoldersAsync(refresh: true);
            }
            catch (Exception ex) { await Chrome.ShowDialog(parent, new ContentDialog { Title = "Could not remove folder", Content = ex.Message, CloseButtonText = "Close" }); }
        });
        return parent;
    }

    private static UIElement FolderLabel(string name, JsonNode? git)
    {
        var label = new StackPanel { Spacing = 3 };
        label.Children.Add(new TextBlock { Text = name, FontSize = 13, TextTrimming = TextTrimming.CharacterEllipsis });
        if (git is not null && Format.Flag(git, "isRepo"))
        {
            var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            line.Children.Add(new TextBlock { Text = "⑂ " + Format.Text(git, "branch", "Detached"), FontSize = 11, Opacity = 0.65 });
            var added = Format.Long(git, "added");
            var removed = Format.Long(git, "removed");
            if (added > 0) line.Children.Add(new TextBlock { Text = "+" + added, FontSize = 11, Foreground = Theme.Brush(static () => Theme.DiffAdded) });
            if (removed > 0) line.Children.Add(new TextBlock { Text = "−" + removed, FontSize = 11, Foreground = Theme.Brush(static () => Theme.DiffRemoved) });
            label.Children.Add(line);
        }
        return label;
    }

    private TaskCompletionSource? _hostWake;
    private string _hostSplashKey = "";

    private void ShowHostSplash(FriendlyErrorInfo? error)
    {
        // Dismissed once the helper answered: a late retry must not drag the
        // splash back over the first page.
        if (_hostSplash is not null && !ReferenceEquals(_frame.Content, _hostSplash))
        {
            return;
        }
        var state = error is null
            ? HostSplashState.Starting
            : error.Title == "No connection" ? HostSplashState.Offline : HostSplashState.Error;
        var key = state + "|" + (error?.Title ?? "");
        // Same state already on screen: rebuilding would restart the rise.
        if (_hostSplash is not null && _hostSplashKey == key)
        {
            return;
        }
        _hostSplashKey = key;
        var splash = HostSplash.View(state, error, () => { _hostWake?.TrySetResult(); });
        _hostSplash = splash;
        _frame.Content = splash;
        _inspectorHost.RouteAllowsInspector = false;
        _inspectorHost.SetInspector(null);
        RebuildToolbar();
        Motion.PlayDoor(splash);
    }

    /// <summary>
    /// The first-run tour over the current page. First run marks it seen on
    /// the way in, so any exit, Skip, Get started, or the sidebar, counts.
    /// Re-opened from About it leaves the flag alone.
    /// </summary>
    private void ShowOnboarding(bool firstRun)
    {
        if (firstRun)
        {
            OnboardingState.HasOnboarded = true;
        }
        var returnTag = (_nav.SelectedItem as NavigationViewItem)?.Tag as string ?? "global:Home";
        SetContent(new OnboardingPage(() => NavigateTo(returnTag)));
    }

    private void StretchNavigationContent() => NativeContentLayout.Stretch(_nav, _contentHost);

    /// <summary>
    /// Mount a page with the smooth arrival. Every navigation goes through
    /// here so content lands the same way on every screen.
    /// </summary>
    private void SetContent(Page page, bool preserveSelection = false)
    {
        if (!preserveSelection)
        {
            _lastNavTag = null;
            RestoreSelection(null);
        }
        // Pages sit transparent over the content host, which carries the
        // Background tone. Only when the page did not choose its own surface:
        // the terminal and the screen own a black one, and a local value wins.
        if (page.ReadLocalValue(Control.BackgroundProperty) == DependencyProperty.UnsetValue)
        {
            page.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        }
        if (_toolbarSource is not null)
        {
            _toolbarSource.ToolbarChanged -= OnToolbarChanged;
        }
        if (_deviceDetailsSource is not null) _deviceDetailsSource.DetailsRequested -= OnDeviceDetailsRequested;
        _deviceDetailsSource = page as MachinesPage;
        if (_deviceDetailsSource is not null) _deviceDetailsSource.DetailsRequested += OnDeviceDetailsRequested;
        _toolbarSource = page as IToolbarItems;
        if (_toolbarSource is not null)
        {
            _toolbarSource.ToolbarChanged += OnToolbarChanged;
        }
        _deviceDetailsPopover?.Hide();
        _frame.Content = page;
        _inspectorHost.RouteAllowsInspector = page is not AccountPage;
        if (!_deviceDetailsInPopover)
            _inspectorHost.SetInspector((page as IInspectorContent)?.Inspector, page is WorkspaceTabsPage or HomePage);
        if (page is IScopeAware aware)
        {
            aware.ApplyScope(_scope);
        }
        RebuildToolbar();
        Motion.PlayArrival(page);
    }

    private IToolbarItems? _toolbarSource;
    private MachinesPage? _deviceDetailsSource;
    private bool _deviceDetailsInPopover;
    private Flyout? _deviceDetailsPopover;

    private void OnDeviceDetailsRequested()
    {
        if (_deviceDetailsInPopover || _frame.Content is not MachinesPage page || page.Inspector is not UIElement detail) return;
        _inspectorHost.IsOpen = true;
        if (_inspectorHost.FitsWidth)
        {
            _inspectorHost.Refresh();
            RebuildToolbar();
            return;
        }
        // Keep details reachable on narrow windows. A nonmodal native popover
        // also leaves confirmation dialogs available to the device actions.
        _deviceDetailsInPopover = true;
        _inspectorHost.SetInspector(null);
        var scroll = new ScrollViewer
        {
            Content = detail, Width = Math.Min(360, Math.Max(240, _contentHost.ActualWidth - 64)),
            MaxHeight = Math.Max(160, _contentHost.ActualHeight - 160),
        };
        var body = new StackPanel { Spacing = Theme.SpaceM };
        var popover = new Flyout { Content = body };
        _deviceDetailsPopover = popover;
        body.Children.Add(Buttons.Secondary("Close details", ActionIcon.Back, (_, _) => popover.Hide(), small: true));
        body.Children.Add(scroll);
        void Restore()
        {
            scroll.Content = null;
            _deviceDetailsInPopover = false;
            _deviceDetailsPopover = null;
            _inspectorHost.SetInspector((_frame.Content as IInspectorContent)?.Inspector, _frame.Content is WorkspaceTabsPage or HomePage);
            RebuildToolbar();
        }
        popover.Closed += (_, _) => Restore();
        try { popover.ShowAt(page, new Microsoft.UI.Xaml.Controls.Primitives.FlyoutShowOptions { Placement = Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.Full }); }
        catch { Restore(); throw; }
    }

    private void OnToolbarChanged()
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            if (!_deviceDetailsInPopover)
                _inspectorHost.SetInspector((_frame.Content as IInspectorContent)?.Inspector, _frame.Content is WorkspaceTabsPage or HomePage);
            RebuildToolbar();
        });
    }

    /// <summary>
    /// Rebuild the one top bar for what is on screen, like the Mac contextual
    /// toolbar: the device scope picker on Home and Insights, then the page's
    /// scope chip and actions before the shared search icon, and the inspector
    /// toggle last, nearest the edge it opens. Account never
    /// shows an inspector, so it gets no toggle either.
    /// </summary>
    private void RebuildToolbar()
    {
        var content = _frame.Content;
        List<UIElement>? leading = null;
        if (content is HomePage or InsightsPage)
        {
            leading = new List<UIElement> { ScopePicker() };
        }
        if (content is IToolbarItems scoped && scoped.ToolbarScope is UIElement chip)
        {
            leading ??= new List<UIElement>();
            leading.Add(chip);
        }
        var trailing = new List<UIElement>();
        if (content is IToolbarItems items)
        {
            foreach (var action in items.ToolbarActions())
            {
                trailing.Add(action);
            }
        }
        trailing.Add(Buttons.ToolbarIcon(ActionIcon.Search, "Search work", (_, _) => OpenSearch()));
        if (content is IInspectorContent inspector && inspector.Inspector is not null
            && _inspectorHost.RouteAllowsInspector && _inspectorHost.FitsWidth)
        {
            // Last, nearest the edge it opens, like the Mac: the toggle is the
            // control beside the column it controls.
            bool open = _inspectorHost.IsInspectorVisible;
            trailing.Add(Buttons.ToolbarIcon(
                ActionIcon.Collapse,
                open ? "Hide inspector" : "Show inspector",
                (_, _) => ToggleInspector(),
                open));
        }
        _toolbarSlot.Child = DetailBar.View(leading, null, null, trailing);
    }

    /// <summary>
    /// The This device / All devices switch. Text-only segments like the Home
    /// page's own chips, fixed at the Mac picker's width so the bar never
    /// jitters between selections.
    /// </summary>
    private UIElement ScopePicker()
    {
        var options = new List<(string Value, string Label, ActionIcon? Glyph)>
        {
            ("local", "This device", null),
            ("account", "All devices", null),
        };
        var picker = SegmentedCapsule.View(options, _scope.Wire(), value =>
        {
            SetScope(value);
            return Task.CompletedTask;
        });
        picker.Width = 280;
        return picker;
    }

    private void SetScope(string value)
    {
        var next = DeviceScopeNames.FromWire(value);
        if (next == _scope)
        {
            return;
        }
        _scope = next;
        _scope.Remember();
        if (_frame.Content is IScopeAware aware)
        {
            aware.ApplyScope(_scope);
        }
        RebuildToolbar();
    }

    /// <summary>
    /// Open the search page from the toolbar. No row carries it any more, so
    /// the selection clears: leaving the old row lit would claim the sidebar
    /// and the content agree when they do not, and the lit row would not
    /// navigate back.
    /// </summary>
    private void OpenSearch()
    {
        NavigateTo("global:Search");
    }

    private void ToggleInspector()
    {
        _inspectorHost.IsOpen = !_inspectorHost.IsOpen;
        _inspectorHost.Refresh();
        RebuildToolbar();
    }

    /// <summary>
    /// Hide the inspector on narrow windows without spending the user's choice:
    /// the toggle preference stands, so widening brings the column back.
    /// </summary>
    private void SyncInspectorFit()
    {
        bool fits = _contentHost.ActualWidth <= 0 || _contentHost.ActualWidth >= InspectorHost.FitEdge;
        if (fits == _inspectorHost.FitsWidth)
        {
            return;
        }
        _inspectorHost.FitsWidth = fits;
        _inspectorHost.Refresh();
        RebuildToolbar();
    }

    private void NavOnSelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (_suppressNav)
        {
            return;
        }
        if (args.SelectedItem is not NavigationViewItem item || item.Tag is not string tag)
        {
            return;
        }
        // Live rows under the folder parents, like the Mac sidebar.
        foreach (var pair in _pinnedNavigation)
            pair.Value.Background = pair.Key == tag ? Theme.AccentSoftBrush : _chromeBackground;
        if (tag.StartsWith(SidebarLive.SessionPrefix, StringComparison.Ordinal)
            && SidebarLive.TrySplit(tag, SidebarLive.SessionPrefix, out var termFolder, out var sessionId))
        {
            _lastNavTag = tag;
            AppServices.OpenTerminal?.Invoke(termFolder, sessionId);
            RefreshUpdateBadge();
            return;
        }
        if (tag.StartsWith(SidebarLive.ChatPrefix, StringComparison.Ordinal)
            && SidebarLive.TrySplit(tag, SidebarLive.ChatPrefix, out var chatFolder, out var chatId))
        {
            // Through the conversation opener, which selects the Chat row and
            // reveals the thread once its list loads.
            AppServices.OpenConversation?.Invoke(chatFolder, chatId);
            return;
        }
        if (tag.StartsWith(SidebarLive.ChatMorePrefix, StringComparison.Ordinal))
        {
            var folder = tag[SidebarLive.ChatMorePrefix.Length..];
            if (!_liveChatExpanded.Remove(folder))
            {
                _liveChatExpanded.Add(folder);
            }
            RebuildSidebarLive();
            // An expander changes the list, not the screen: the selection goes
            // back where it was and the content stays put.
            _suppressNav = true;
            if (_lastNavTag is not null && FindNavItem(_lastNavTag) is NavigationViewItem back)
            {
                _nav.SelectedItem = back;
            }
            else if (FindNavItem("ws:" + folder + ":Chat") is NavigationViewItem chatRow)
            {
                _nav.SelectedItem = chatRow;
            }
            _suppressNav = false;
            return;
        }
        if (tag.StartsWith(SidebarLive.ChatAllPrefix, StringComparison.Ordinal))
        {
            var folder = tag[SidebarLive.ChatAllPrefix.Length..];
            var chatTag = "ws:" + folder + ":Chat";
            if (FindNavItem(chatTag) is NavigationViewItem chatRow)
            {
                _suppressNav = true;
                _nav.SelectedItem = chatRow;
                _suppressNav = false;
            }
            _lastNavTag = chatTag;
            Show(chatTag);
            RefreshUpdateBadge();
            return;
        }
        if (tag == "workspaces:add")
        {
            // An action, not a place: the selection goes back where it was
            // once the dialog closes, and the content stays put.
            Show(tag);
            RefreshUpdateBadge();
            return;
        }
        _lastNavTag = tag;
        Show(tag);
        RefreshUpdateBadge();
    }

    private void Show(string tag)
    {
        foreach (var pair in _pinnedNavigation)
            pair.Value.Background = pair.Key == tag ? Theme.AccentSoftBrush : _chromeBackground;
        if (tag.StartsWith("sshterm:", StringComparison.Ordinal))
        {
            SetContent(Ssh(SSHSection.Hosts, tag["sshterm:".Length..]));
            return;
        }
        if (tag.StartsWith("global:", StringComparison.Ordinal))
        {
            if (Enum.TryParse<GlobalSection>(tag["global:".Length..], out var section))
            {
                Page page = section switch
                {
                    GlobalSection.Home => new HomePage(),
                    GlobalSection.Insights => new InsightsPage(),
                    GlobalSection.Machines => new MachinesPage(),
                    GlobalSection.Ssh => Ssh(SSHSection.Hosts),
                    GlobalSection.Search => new WorkSearchPage(),
                    GlobalSection.Todo => new TodoPage(),
                    GlobalSection.Notes => new NotesPage(),
                    GlobalSection.Workflows => new WorkflowsPage(),
                    GlobalSection.Automations => new AutomationsPage(),
                    GlobalSection.Account => new AccountPage(),
                    GlobalSection.About => new AboutPage(),
                    _ => new AboutPage(),
                };
                SetContent(page, preserveSelection: true);
            }
            return;
        }
        if (tag.StartsWith("ssh:", StringComparison.Ordinal))
        {
            if (Enum.TryParse<SSHSection>(tag["ssh:".Length..], out var section))
            {
                SetContent(Ssh(section), preserveSelection: true);
            }
            return;
        }
        if (tag == "workspaces:all")
        {
            SetContent(WorkspacesOverviewPage(), preserveSelection: true);
            return;
        }
        if (tag == "workspaces:add")
        {
            _ = AddWorkspaceAsync();
            return;
        }
        if (tag.StartsWith("ws:", StringComparison.Ordinal))
        {
            var rest = tag["ws:".Length..];
            var i = rest.LastIndexOf(':');
            if (i > 0
                && Enum.TryParse<WorkspaceSection>(rest[(i + 1)..], out var section))
            {
                var id = rest[..i];
                var workbench = WorkspaceTabs(id);
                workbench.Open(section);
                if (section == WorkspaceSection.Files) _inspectorHost.IsOpen = true;
                SetContent(workbench, preserveSelection: true);
            }
        }
    }

    /// <summary>
    /// The page for one folder section. Local folders open the full
    /// workbench. A folder on another machine opens the same dedicated pages,
    /// whose helpers route through the peer, except Notes, which stays local
    /// like the desktop Mac.
    /// </summary>
    private readonly Dictionary<string, WorkspaceTabsPage> _workbenches = new();
    private SshPage? _sshPage;
    private SshPage Ssh(SSHSection section, string? sessionId = null)
    {
        if (_sshPage is null)
        {
            _sshPage = new SshPage(section, sessionId);
            return _sshPage;
        }
        _ = _sshPage.OpenAsync(section, sessionId);
        return _sshPage;
    }

    private WorkspaceTabsPage WorkspaceTabs(string id)
    {
        if (!_workbenches.TryGetValue(id, out var page))
        {
            page = new WorkspaceTabsPage(id, section => WorkspaceSectionPage(id, section));
            _workbenches.Add(id, page);
        }
        return page;
    }

    private Page WorkspaceSectionPage(string id, WorkspaceSection section)
    {
        if (RemoteWorkspaces.IsRemote(id))
        {
            return section switch
            {
                WorkspaceSection.Browser => new BrowserPage("", "127.0.0.1", 0, false,
                    RemoteWorkspaces.TrySplit(id, out var browserPeer, out _) ? browserPeer : null),
                WorkspaceSection.Files => new EditorPage(id),
                WorkspaceSection.History => WorkspaceHistoryPage(id),
                WorkspaceSection.Chat => new ChatPage(id),
                WorkspaceSection.Todo => new TodoPage(id),
                WorkspaceSection.Workflows => new WorkflowsPage(id),
                WorkspaceSection.Automations => new AutomationsPage(id),
                WorkspaceSection.Pulls => new PullsPage(id),
                _ => new WorkspacePage(id, section),
            };
        }
        return section switch
        {
            WorkspaceSection.Browser => new BrowserPage("", "127.0.0.1", 0, false),
            WorkspaceSection.Files => new EditorPage(id),
            WorkspaceSection.Notes => new NotesPage(id),
            WorkspaceSection.Workflows => new WorkflowsPage(id),
            WorkspaceSection.Automations => new AutomationsPage(id),
            WorkspaceSection.Pulls => new PullsPage(id),
            WorkspaceSection.Chat => new ChatPage(id),
            WorkspaceSection.History => WorkspaceHistoryPage(id),
            _ => new WorkspacePage(id, section),
        };
    }

    /// <summary>
    /// The add flow from the sidebar row and the overview button. A new
    /// folder selects itself, so what was just made is what is on screen.
    /// </summary>
    private async Task AddWorkspaceAsync()
    {
        var owner = _frame.Content as UIElement ?? (UIElement)_frame;
        var added = await WorkspaceAddDialog.ShowAsync(owner);
        if (added is null)
        {
            RestoreSelection(_lastNavTag);
            return;
        }
        _foldersLoaded = false;
        await TryLoadFoldersAsync();
        var tag = "ws:" + added + ":Files";
        NavigateTo(tag);
    }

    private void RestoreSelection(string? tag)
    {
        _suppressNav = true;
        _nav.SelectedItem = tag is null ? null : FindNavItem(tag);
        _suppressNav = false;
    }

    private void NavigateTo(string tag)
    {
        RestoreSelection(tag);
        _lastNavTag = tag;
        Show(tag);
        RefreshUpdateBadge();
    }

    /// <summary>
    /// Every registered folder as cards, the first row under Workspaces. Each
    /// card opens that folder, selecting its sidebar row so the pane and the
    /// sidebar agree.
    /// </summary>
    private Page WorkspacesOverviewPage()
    {
        var root = new StackPanel { Spacing = Theme.SpaceL };
        var page = new Page
        {
            Content = new ScrollViewer
            {
                Padding = new Thickness(Theme.SpaceM),
                Content = root,
            },
        };
        page.Loaded += async (_, _) => await FillOverviewAsync(root, page);
        return page;
    }

    private async Task FillOverviewAsync(StackPanel root, Page page)
    {
        root.Children.Clear();
        var head = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Theme.SpaceM,
        };
        head.Children.Add(new TextBlock
        {
            Text = "All projects",
            FontSize = 28,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
        });
        var spacer = new Grid { Width = Theme.SpaceM };
        head.Children.Add(spacer);
        head.Children.Add(Buttons.Primary(
            "Add project", ActionIcon.Create, async (_, _) =>
            {
                await AddWorkspaceAsync();
                if (ReferenceEquals(_frame.Content, page))
                {
                    await FillOverviewAsync(root, page);
                }
            }));
        root.Children.Add(head);
        JsonNode listed;
        try
        {
            listed = await AppServices.Host.CallAsync("workspace.list");
        }
        catch (Exception ex)
        {
            root.Children.Add(Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important));
            return;
        }
        var array = listed as JsonArray
            ?? listed["folders"] as JsonArray
            ?? listed["workspaces"] as JsonArray;
        var remote = RemoteWorkspaces.CachedFolders();
        if ((array is null || array.Count == 0) && remote.Count == 0)
        {
            root.Children.Add(EmptyState.View(
                "No folders yet",
                "Add a project folder and it will appear here.",
                EmptyArtKind.WorkspaceAccess));
            return;
        }
        var filters = new Grid { ColumnSpacing = Theme.SpaceM };
        filters.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        filters.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var search = new TextBox { PlaceholderText = "Search projects", MinWidth = 120 };
        var machine = new ComboBox { MinWidth = 160 };
        machine.Items.Add("All machines"); machine.Items.Add("This PC");
        foreach (var label in remote.Select(folder => folder.MachineLabel).Distinct()) machine.Items.Add(label);
        machine.SelectedIndex = 0;
        Grid.SetColumn(machine, 1); filters.Children.Add(search); filters.Children.Add(machine);
        root.Children.Add(filters);
        var list = new StackPanel { Spacing = Theme.SpaceS };
        var rows = new List<(string Search, string Machine, Func<UIElement> Build)>();
        var summaries = new Dictionary<string, JsonNode>(_liveSummaries);
        void AddFolder(string id, string name, string path, string machineLabel, JsonNode? git)
        {
            rows.Add((name + " " + path + " " + machineLabel, machineLabel, () =>
            {
                summaries.TryGetValue(id, out var summary);
                return OverviewFolderRow(name, path, "ws:" + id + ":Launcher", machineLabel, git, summary);
            }));
        }
        foreach (var folder in array ?? new JsonArray())
        {
            var id = Format.Text(folder, "id");
            if (id.Length > 0) AddFolder(id, Format.Text(folder, "name", id), Format.Text(folder, "path"), "This PC", folder?["git"]);
        }
        foreach (var folder in remote) AddFolder(folder.Id, folder.Name, folder.Path, folder.MachineLabel, folder.Git);
        void Filter()
        {
            list.Children.Clear();
            foreach (var row in rows)
                if ((machine.SelectedIndex == 0 || row.Machine == machine.SelectedItem?.ToString()) &&
                    (string.IsNullOrWhiteSpace(search.Text) || row.Search.Contains(search.Text, StringComparison.OrdinalIgnoreCase))) list.Children.Add(row.Build());
        }
        search.TextChanged += (_, _) => Filter(); machine.SelectionChanged += (_, _) => Filter();
        Filter(); root.Children.Add(list);
        // Folders are immediately openable; a sleeping remote must not delay the list.
        // Bound concurrent reads and reject completion after a reload or navigation.
        using var summarySlots = new SemaphoreSlim(2);
        await Task.WhenAll(remote.Select(folder => folder.PeerKey).Distinct().Select(async peer =>
        {
            await summarySlots.WaitAsync();
            try
            {
                var summaryRows = Format.Items(await RemoteWorkspaces.CallOnPeerAsync(peer, "workspace.summary"));
                if (!ReferenceEquals(_frame.Content, page) || !root.Children.Contains(list)) return;
                foreach (var summary in summaryRows ?? new JsonArray())
                    if (summary is not null) summaries[RemoteWorkspaces.Join(peer, Format.Text(summary, "id"))] = summary;
                Filter();
            }
            catch { /* Counts are optional; the folder remains openable. */ }
            finally { summarySlots.Release(); }
        }));
    }

    private UIElement OverviewFolderRow(string title, string subtitle, string tag, string machine, JsonNode? git, JsonNode? summary)
    {
        var body = new Grid { ColumnSpacing = Theme.SpaceM };
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        body.Children.Add(new SymbolIcon { Symbol = Symbol.Folder, Foreground = Theme.AccentBrush });
        var identity = new StackPanel { Spacing = 4 };
        identity.Children.Add(new TextBlock { Text = title, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextTrimming = TextTrimming.CharacterEllipsis, MaxLines = 1 });
        var path = subtitle.StartsWith(@"\\?\") ? subtitle[4..] : subtitle;
        identity.Children.Add(new TextBlock { Text = machine + " · " + path, FontSize = 12,
            Opacity = 0.7, TextTrimming = TextTrimming.CharacterEllipsis, MaxLines = 1 });
        if (summary is not null)
            identity.Children.Add(new TextBlock { Text = $"{Format.Long(summary, "chats")} chats · {Format.Long(summary, "tasks")} tasks",
                FontSize = 12, Opacity = 0.7 });
        Grid.SetColumn(identity, 1);
        body.Children.Add(identity);
        var arrow = new TextBlock { Text = "›", Opacity = 0.5, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(arrow, 2);
        body.Children.Add(arrow);
        var open = new Button
        {
            HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Background = Theme.PanelBrush, BorderBrush = Theme.BorderBrush, Content = body,
            CornerRadius = new CornerRadius(Theme.CardRadius), Padding = new Thickness(Theme.SpaceM),
        };
        ToolTipService.SetToolTip(open, subtitle);
        open.Click += (_, _) =>
        {
            if (FindNavItem(tag) is NavigationViewItem row)
            {
                _nav.SelectedItem = row;
            }
            else
            {
                Show(tag);
            }
        };
        return open;
    }

    /// <summary>
    /// One folder's commit history, through the shared history card. The diff
    /// opener matches the Changes screen, so a file reads the same from both.
    /// </summary>
    private static Page WorkspaceHistoryPage(string id) => new HistoryPage(id);

    private sealed class HistoryPage : Page, IToolbarItems
    {
        private readonly string _id;
        private int _loadGeneration;
        private readonly StackPanel _root = new() { Spacing = Theme.SpaceL };

        private async Task ShowDiffAsync(string filePath)
        {
            JsonNode? diff;
            try
            {
                diff = await RemoteWorkspaces.CallWorkspaceAsync(
                    _id,
                    "workspace.diff",
                    new JsonObject { ["id"] = _id, ["path"] = filePath });
            }
            catch (Exception ex)
            {
                _root.Children.Add(Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important));
                return;
            }
            await WorkspaceDiff.ShowFileDiffAsync(this, "Diff · " + filePath, diff);
        }

        public event Action? ToolbarChanged { add { } remove { } }

        public HistoryPage(string id)
        {
            _id = id;
            Content = new ScrollViewer
            {
                Padding = new Thickness(Theme.SpaceM),
                Content = _root,
            };
            Loaded += async (_, _) => await LoadAsync();
        }

        public UIElement? ToolbarScope =>
            Chrome.ScopeChip(WorkspaceSection.History.Label());

        public IList<UIElement> ToolbarActions()
        {
            return new List<UIElement>
            {
                Buttons.ToolbarIcon(
                    ActionIcon.Refresh,
                    "Reload history",
                    async (_, _) =>
                    {
                        LogoRefresh.Began();
                        await LoadAsync();
                    }),
            };
        }

        private async Task LoadAsync()
        {
            var generation = ++_loadGeneration;
            _root.Children.Clear();
            _root.Children.Add(new TextBlock
            {
                Text = WorkspaceSection.History.Label(),
                FontSize = 18,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            });
            var skeleton = Motion.SkeletonCard();
            _root.Children.Add(skeleton);
            var remote = RemoteWorkspaces.IsRemote(_id);
            var card = remote
                ? await WorkspaceRemoteHistory.LoadCardAsync(this, _id)
                : await WorkspaceHistory.LoadCardAsync(this, _id);
            if (generation != _loadGeneration)
            {
                return;
            }
            _root.Children.Remove(skeleton);
            if (card is not null)
            {
                _root.Children.Add(card);
            }
        }
    }

    private static IEnumerable<NavigationViewItem> NavItems(IEnumerable<object> items)
    {
        foreach (var row in items.OfType<NavigationViewItem>())
        {
            yield return row;
            foreach (var child in NavItems(row.MenuItems)) yield return child;
        }
    }

    private NavigationViewItem? FindNavItem(string tag) =>
        NavItems(_nav.MenuItems).Concat(NavItems(_nav.FooterMenuItems))
            .FirstOrDefault(row => (row.Tag as string) == tag);

    private void RefreshUpdateBadge()
    {
        _liveFooterKey = "";
        RefreshAccountFooter();
    }

    /// <summary>
    /// Quiet sidebar refresh, like the Mac terminals watcher. Sessions and
    /// chats every tick, counts and the account footer on slow ticks. A
    /// failed call keeps the last rows: a missed poll is not an empty sidebar.
    /// </summary>
    private async Task RefreshSidebarLiveAsync(bool slow = false)
    {
        if (_sidebarRefreshing)
        {
            _sidebarSlowRefreshPending |= slow;
            return;
        }
        _sidebarRefreshing = true;
        try
        {
            var previousSessions = _liveSessions;
            var previousChats = _liveChats;
            var previousSummaries = _liveSummaries;
            var previousAccount = _liveAccount;
            var (sessions, chats) = await SidebarLive.FetchFastAsync();
            try
            {
                var sshSessions = Format.Items(await AppServices.Host.CallAsync("ssh.session.list"));
                var sshGroup = FindNavItem("ssh:" + SSHSection.Hosts);
                if (sshGroup is not null && sshSessions is not null)
                {
                    var wanted = sshSessions.Where(item => Format.Flag(item, "alive")).Select(item => new NavigationViewItem
                    {
                        Tag = "sshterm:" + Format.Text(item, "id"), Content = SshHostPlatform.SessionRow(item),
                    }).ToList();
                    foreach (var row in wanted)
                    {
                        var sessionId = ((string)row.Tag)["sshterm:".Length..];
                        var menu = ContextMenus.Menu(row);
                        ContextMenus.AddAsync(menu, "Close session…", async () =>
                        {
                            var owner = menu.Target ?? row;
                            var confirm = new ContentDialog { Title = "Close this SSH session?", Content = "The shell will stop.", PrimaryButtonText = "Close session", CloseButtonText = "Keep running", DefaultButton = ContentDialogButton.Close };
                            if (await Chrome.ShowDialog(owner, confirm) != ContentDialogResult.Primary) return;
                            try { await AppServices.Host.CallAsync("ssh.session.close", new JsonObject { ["id"] = sessionId }); await RefreshSidebarLiveAsync(); }
                            catch (Exception ex) { await Chrome.ShowDialog(owner, new ContentDialog { Title = "Could not close session", Content = ex.Message, CloseButtonText = "Close" }); }
                        });
                    }
                    NavigationRows.Reconcile(sshGroup.MenuItems, wanted, "sshterm:");
                }
            }
            catch { /* Keep reachable session rows on a transient host failure. */ }
            if (slow)
            {
                await TryLoadFoldersAsync(refresh: true);
                _ = RemoteWorkspaces.SweepAsync();
                var (summaries, account) = await SidebarLive.FetchSlowAsync();
                if (summaries is not null)
                {
                    _liveSummaries = summaries;
                }
                if (account is not null)
                {
                    _liveAccount = account;
                }
            }
            if (sessions is not null)
            {
                _liveSessions = sessions;
            }
            if (chats is not null)
            {
                _liveChats = chats;
            }
            var rowsChanged = !JsonNode.DeepEquals(previousSessions, _liveSessions)
                || !JsonNode.DeepEquals(previousChats, _liveChats)
                || (previousSummaries.Count != _liveSummaries.Count || previousSummaries.Any(pair => !_liveSummaries.TryGetValue(pair.Key, out var value) || !JsonNode.DeepEquals(pair.Value, value)));
            var accountChanged = !JsonNode.DeepEquals(previousAccount, _liveAccount);
            if (rowsChanged || accountChanged) DispatcherQueue.TryEnqueue(() =>
            {
                if (rowsChanged) RebuildSidebarLive();
                if (accountChanged) RefreshAccountFooter();
            });
        }
        finally
        {
            _sidebarRefreshing = false;
            if (_sidebarSlowRefreshPending)
            {
                _sidebarSlowRefreshPending = false;
                _ = RefreshSidebarLiveAsync(slow: true);
            }
        }
    }

    /// <summary>
    /// Rebuild the live rows under every folder parent from the cached poll:
    /// alive sessions after the Sessions row, recent chats after the Chat row,
    /// and count badges on the section rows. Section rows keep their tags and
    /// order; only the live rows come and go.
    /// </summary>
    private void RebuildSidebarLive()
    {
        var selectedTag = (_nav.SelectedItem as NavigationViewItem)?.Tag as string;
        var sessionsByFolder = new Dictionary<string, List<JsonNode>>(StringComparer.Ordinal);
        foreach (var session in _liveSessions)
        {
            if (session is null || Format.Flag(session, "hidden") || !Format.Flag(session, "alive"))
            {
                continue;
            }
            var folder = Format.Text(session, "workspaceId");
            var id = Format.Text(session, "id");
            if (string.IsNullOrEmpty(folder) || string.IsNullOrEmpty(id))
            {
                continue;
            }
            if (!sessionsByFolder.TryGetValue(folder, out var list))
            {
                list = new List<JsonNode>();
                sessionsByFolder[folder] = list;
            }
            list.Add(session);
        }
        var chatsByFolder = new Dictionary<string, List<JsonNode>>(StringComparer.Ordinal);
        string? selectedChatId = null;
        if (selectedTag is not null && LiveRoute.TrySplit(selectedTag, SidebarLive.ChatPrefix, out _, out var litChat))
        {
            selectedChatId = litChat;
        }
        foreach (var chat in _liveChats)
        {
            if (chat is null)
            {
                continue;
            }
            var folder = Format.Text(chat, "workspaceId");
            var id = Format.Text(chat, "id");
            if (string.IsNullOrEmpty(folder) || string.IsNullOrEmpty(id)
                || SidebarLive.IsUntouched(chat, selectedChatId))
            {
                continue;
            }
            if (!chatsByFolder.TryGetValue(folder, out var list))
            {
                list = new List<JsonNode>();
                chatsByFolder[folder] = list;
            }
            list.Add(chat);
        }

        foreach (var item in NavItems(_nav.MenuItems).Where(row => row.MenuItems.Count > 0 && (row.Tag as string)?.StartsWith("ws:") == true && (row.Tag as string)?.EndsWith(":Launcher") == true).ToList())
        {
            if (item is not NavigationViewItem parent)
            {
                continue;
            }
            var parentTag = parent.Tag as string;
            if (parentTag is null || !parentTag.StartsWith("ws:", StringComparison.Ordinal))
            {
                continue;
            }
            var rest = parentTag["ws:".Length..];
            var cut = rest.LastIndexOf(':');
            if (cut <= 0)
            {
                continue;
            }
            var folderId = rest[..cut];
            var desiredSessions = new List<NavigationViewItem>();
            _liveSummaries.TryGetValue(folderId, out var summary);
            foreach (var child in parent.MenuItems)
            {
                if (child is not NavigationViewItem section || section.Tag is not string sectionTag)
                {
                    continue;
                }
                var sectionRest = sectionTag.StartsWith("ws:", StringComparison.Ordinal)
                    ? sectionTag["ws:".Length..]
                    : null;
                var sectionCut = sectionRest?.LastIndexOf(':') ?? -1;
                if (sectionCut <= 0
                    || !Enum.TryParse<WorkspaceSection>(sectionRest?[(sectionCut + 1)..], out var sectionKind))
                {
                    continue;
                }
                var count = SidebarLive.SectionCount(sectionKind, summary);
                if (sectionKind == WorkspaceSection.Chat)
                {
                    if (section.MenuItems.Count > 0) _chatGroupExpansion[sectionTag] = section.IsExpanded;
                    if (chatsByFolder.TryGetValue(folderId, out var recent)) count = Math.Max(count, recent.Count);
                }
                SidebarLive.ApplyCount(section, count);
            }
            if (sessionsByFolder.TryGetValue(folderId, out var sessions) && sessions.Count > 0)
            {
                foreach (var session in sessions)
                {
                    desiredSessions.Add(SidebarLive.SessionItem(folderId, session));
                }
            }
            NavigationRows.Reconcile(parent.MenuItems, desiredSessions, SidebarLive.SessionPrefix, ChildIndex(parent, "ws:" + folderId + ":Sessions") + 1);
            if (chatsByFolder.TryGetValue(folderId, out var chats) && chats.Count > 0)
            {
                var expanded = _liveChatExpanded.Contains(folderId);
                if (!expanded
                    && selectedTag is not null
                    && LiveRoute.TrySplit(selectedTag, SidebarLive.ChatPrefix, out var selectedFolder, out var selectedId)
                    && selectedFolder == folderId)
                {
                    // The lit row must stay drawn: a selection past the first
                    // five opens the list, like the Mac auto-expansion.
                    var selectedIndex = chats.FindIndex(c => Format.Text(c, "id") == selectedId);
                    if (selectedIndex >= SidebarLive.CollapsedChats)
                    {
                        expanded = true;
                        _liveChatExpanded.Add(folderId);
                    }
                }
                var shown = expanded
                    ? Math.Min(chats.Count, SidebarLive.InlineChats)
                    : Math.Min(chats.Count, SidebarLive.CollapsedChats);
                var chatSection = (NavigationViewItem)parent.MenuItems[ChildIndex(parent, "ws:" + folderId + ":Chat")];
                var desiredChats = new List<NavigationViewItem>();
                for (var i = 0; i < shown; i++)
                {
                    desiredChats.Add(SidebarLive.ChatItem(folderId, chats[i]));
                }
                if (chats.Count > SidebarLive.CollapsedChats)
                {
                    var label = expanded
                        ? "Show less"
                        : "Show " + (Math.Min(chats.Count, SidebarLive.InlineChats) - shown) + " more";
                    desiredChats.Add(SidebarLive.ActionItem(
                        SidebarLive.ChatMorePrefix + folderId, label));
                }
                if (chats.Count > SidebarLive.InlineChats)
                {
                    desiredChats.Add(SidebarLive.ActionItem(
                        SidebarLive.ChatAllPrefix + folderId, "See all chats"));
                }
                NavigationRows.Reconcile(chatSection.MenuItems, desiredChats, "wschat", 0);
                var chatTag = "ws:" + folderId + ":Chat";
                chatSection.IsExpanded = _chatGroupExpansion.GetValueOrDefault(chatTag, true)
                    || (selectedTag is not null && LiveRoute.TrySplit(selectedTag, SidebarLive.ChatPrefix, out var selectedFolderId, out _) && selectedFolderId == folderId);
            }
            else if (parent.MenuItems.OfType<NavigationViewItem>().FirstOrDefault(row => Equals(row.Tag, "ws:" + folderId + ":Chat")) is { } emptyChats)
                NavigationRows.Reconcile(emptyChats.MenuItems, Array.Empty<NavigationViewItem>(), "wschat", 0);
        }

        if (selectedTag is not null
            && ((_nav.SelectedItem as NavigationViewItem)?.Tag as string) != selectedTag
            && FindNavItem(selectedTag) is NavigationViewItem back)
        {
            _suppressNav = true;
            _nav.SelectedItem = back;
            _suppressNav = false;
        }
    }

    private static int ChildIndex(NavigationViewItem parent, string tag)
    {
        for (var i = 0; i < parent.MenuItems.Count; i++)
        {
            if (parent.MenuItems[i] is NavigationViewItem child && (child.Tag as string) == tag)
            {
                return i;
            }
        }
        return parent.MenuItems.Count - 1;
    }

    /// <summary>
    /// One profile row with Account and About in its menu. Signed out,
    /// the same row leads with Sign in.
    /// </summary>
    private void RefreshAccountFooter()
    {
        var account = _liveAccount;
        bool signedIn = false;
        try
        {
            signedIn = account?["signedIn"]?.GetValue<bool>() ?? false;
        }
        catch
        {
            signedIn = false;
        }
        var key = !signedIn || account is null
            ? "out"
            : "in|" + Format.Text(account, "displayName")
                + "|" + Format.Text(account, "handle")
                + "|" + Format.Text(account, "tier")
                + "|" + Format.Text(account, "avatar");
        if (key == _liveFooterKey)
        {
            return;
        }
        _liveFooterKey = key;
        if (!signedIn || account is null)
        {
            _railFooter.Child = AccountMenu(new JsonObject { ["displayName"] = "Sign in" });
            return;
        }
        _railFooter.Child = AccountMenu(account);
    }

    private UIElement AccountMenu(JsonNode account)
    {
        var name = Format.Text(account, "displayName", "Account");
        var footer = new Button
        {
            Content = Marks.Avatar(url: Format.Text(account, "avatar"), name: name,
                handle: Format.Text(account, "handle"), size: 28),
            Width = 44, Height = 44, Padding = new Thickness(8),
            Background = new SolidColorBrush(Colors.Transparent), BorderThickness = new Thickness(0),
        };
        var label = AppServices.Update.IsReady || AppServices.Update.IsAvailable ? "Account · Update available" : "Account: " + name;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(footer, label);
        ToolTipService.SetToolTip(footer, label);
        var menu = new MenuFlyout();
        foreach (var section in new[] { GlobalSection.Account, GlobalSection.About })
        {
            var item = new MenuFlyoutItem
            {
                Text = section == GlobalSection.Account && (AppServices.Update.IsReady || AppServices.Update.IsAvailable)
                    ? "Account · Update available" : section.ToString(),
            };
            item.Click += (_, _) =>
            {
                _nav.SelectedItem = null;
                _lastNavTag = "global:" + section;
                Show(_lastNavTag);
            };
            menu.Items.Add(item);
        }
        footer.Flyout = menu;
        return footer;
    }

    private void TrySize()
    {
        try
        {
            var hwnd = WindowNative.GetWindowHandle(this);
            var id = Win32Interop.GetWindowIdFromWindow(hwnd);
            var appWindow = AppWindow.GetFromWindowId(id);
            appWindow.Resize(new SizeInt32(1280, 840));
            appWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "tokenstat.ico"));
        }
        catch
        {
            // Default size is fine.
        }
    }

    private void TryIcon()
    {
        try
        {
            var hwnd = WindowNative.GetWindowHandle(this);
            var id = Win32Interop.GetWindowIdFromWindow(hwnd);
            AppWindow.GetFromWindowId(id).Title = "tokenstat";
        }
        catch
        {
            // Title already set.
        }
    }

    /// <summary>
    /// Extend the content into the caption area and hand the titlebar element
    /// to the OS as the drag region. Code only, never XAML: setting
    /// ExtendsContentIntoTitleBar in XAML is an error. Failure keeps the
    /// system bar, the window still works with a 32px strip above the nav.
    /// </summary>
    private void TryExtendIntoTitleBar()
    {
        try
        {
            ExtendsContentIntoTitleBar = true;
            SetTitleBar(AppTitleBar);
        }
        catch
        {
            // System caption stays. Surfaces still paint from the tokens.
        }
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref uint value, int size);

    private void OnAdvancedEffectsChanged(Windows.UI.ViewManagement.UISettings sender, object args) =>
        DispatcherQueue.TryEnqueue(ApplyChromeColors);

    private void OnHighContrastChanged(Windows.UI.ViewManagement.AccessibilitySettings sender, object args) =>
        DispatcherQueue.TryEnqueue(ApplyChromeColors);

    /// <summary>
    /// Repaint every flat surface from the theme tokens. Runs once at launch
    /// and again whenever the system theme changes, so the window frame never
    /// shows a stale tone. Pages rebuild on navigation and pick the new theme
    /// up there.
    /// </summary>
    private void ApplyChromeColors()
    {
        Theme.WindowTheme = RootGrid.ActualTheme;
        Theme.InstallControlResources();
        _chromeBackground.Color = Theme.Background;
        var sidebar = Theme.Sidebar;
        bool effects = _nativeBackdrop;
        try { effects &= (_chromeSettings ?? new Windows.UI.ViewManagement.UISettings()).AdvancedEffectsEnabled
                && !(_accessibilitySettings ?? new Windows.UI.ViewManagement.AccessibilitySettings()).HighContrast; }
        catch { effects = false; }
        if (effects) sidebar.A = 190;
        _chromeSidebar.Color = sidebar;
        _chromeBorder.Color = Theme.Border;
        _inspectorHost.ApplyTheme();
        // The toolbar bakes its brushes at build time, like the pages do at
        // navigation: rebuild it so a theme change repaints it too.
        RebuildToolbar();
        SyncPaneChrome();
        TryTitleBarColors();
        // Windows 11 otherwise uses the user's accent for the window outline.
        // DWMWA_COLOR_NONE suppresses it; older Windows ignores this attribute.
        var noBorder = 0xfffffffeu;
        _ = DwmSetWindowAttribute(WindowNative.GetWindowHandle(this), 34, ref noBorder, sizeof(uint));
    }

    /// <summary>
    /// Keep the pane chrome on the pane state: the titlebar split follows the
    /// pane edge, and group headers hide while the pane collapses to icons,
    /// where they would otherwise render as clipped stubs like "GLO" or "WOR".
    /// </summary>
    private void SyncPaneChrome()
    {
        SyncTitleBarSplit();
        _paneResize.Visibility = _nav.IsPaneOpen ? Visibility.Visible : Visibility.Collapsed;
        _paneResize.Margin = new Thickness(Math.Max(0, _nav.OpenPaneLength - 3), 0, 0, 0);
        _nav.PaneHeader = _nav.IsPaneOpen ? LogoOpen() : LogoClosed();
        var show = _nav.IsPaneOpen ? Visibility.Visible : Visibility.Collapsed;
        foreach (var button in _pinnedNavigation.Values)
            if (button.Content is StackPanel content)
                foreach (var label in content.Children.OfType<TextBlock>()) label.Visibility = show;
        foreach (var item in _nav.MenuItems)
        {
            if (item is NavigationViewItemHeader header)
            {
                header.Visibility = show;
            }
        }
    }

    /// <summary>
    /// The brand at the top of the sidebar, where the Mac keeps its wordmark.
    /// A static mark, so every LogoRefresh pulse dips the bars once, like the
    /// Mac launch-and-refresh motion. Rebuilt per call: panes and themes move.
    /// </summary>
    private UIElement LogoOpen()
    {
        var content = new StackPanel { Spacing = Theme.SpaceM };
        content.Children.Add(Marks.Wordmark());
        var menu = new MenuFlyout();
        menu.Opening += (_, _) =>
        {
            menu.Items.Clear();
            void AddProject(string id, string name, string machine, string path)
            {
                var item = new MenuFlyoutItem { Text = name + " · " + machine };
                ToolTipService.SetToolTip(item, path);
                item.Click += async (_, _) =>
                {
                    NavigateTo("ws:" + id + ":Chat");
                    var workbench = WorkspaceTabs(id);
                    if (workbench.ActivePage is ChatPage page) await page.BeginNewChatAsync();
                };
                menu.Items.Add(item);
            }
            foreach (var folder in _localFolders)
            {
                var id = Format.Text(folder, "id");
                if (id.Length > 0) AddProject(id, Format.Text(folder, "name"), "This PC", Format.Text(folder, "path"));
            }
            foreach (var folder in RemoteWorkspaces.CachedFolders())
                AddProject(folder.Id, folder.Name, folder.MachineLabel, folder.Path);
            if (menu.Items.Count == 0)
                menu.Items.Add(new MenuFlyoutItem { Text = "Add a project first", IsEnabled = false });
        };
        var create = Buttons.Secondary("New chat…", ActionIcon.Create, (_, _) => { });
        create.Flyout = menu;
        create.HorizontalAlignment = HorizontalAlignment.Stretch;
        ToolTipService.SetToolTip(create, "Choose which project the new chat belongs to");
        content.Children.Add(create);
        return new Border
        {
            Padding = new Thickness(Theme.SpaceM, Theme.SpaceM, Theme.SpaceM, Theme.SpaceM),
            Child = content,
        };
    }

    /// <summary>
    /// The collapsed pane keeps the bars alone, centred in the icon rail.
    /// </summary>
    private static UIElement LogoClosed()
    {
        return new Border
        {
            Padding = new Thickness(0, Theme.SpaceM, 0, Theme.SpaceM),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            Child = new Grid
            {
                HorizontalAlignment = HorizontalAlignment.Center,
                Children = { Marks.LogoMark(18) },
            },
        };
    }

    /// <summary>
    /// Keep the titlebar split on the pane edge: full length while the pane is
    /// open, compact length once it collapses to icons.
    /// </summary>
    private void SyncTitleBarSplit()
    {
        TitlePaneColumn.Width = new GridLength(RailWidth + (_nav.IsPaneOpen ? _nav.OpenPaneLength : _nav.CompactPaneLength));
    }

    /// <summary>
    /// Paint the OS caption buttons from the theme. The buttons sit over the
    /// content half of the titlebar, so their resting tone is Background;
    /// hover is the control seat, pressed a deeper neutral, inactive the idle
    /// grey. All twelve colors are set together, as the OS guidance asks, so a
    /// user accent on title bars cannot leak an unintended combination in.
    /// Where the OS ignores custom colors, the system caption stays correct.
    /// </summary>
    private void TryTitleBarColors()
    {
        try
        {
            var hwnd = WindowNative.GetWindowHandle(this);
            var id = Win32Interop.GetWindowIdFromWindow(hwnd);
            var bar = AppWindow.GetFromWindowId(id).TitleBar;
            if (!AppWindowTitleBar.IsCustomizationSupported())
            {
                return;
            }
            bar.ExtendsContentIntoTitleBar = true;
            bar.IconShowOptions = IconShowOptions.HideIconAndSystemMenu;
            bar.BackgroundColor = Theme.Background;
            bar.ForegroundColor = Theme.DefaultText;
            bar.InactiveBackgroundColor = Theme.Background;
            bar.InactiveForegroundColor = Theme.StateIdle;
            bar.ButtonBackgroundColor = Theme.Background;
            bar.ButtonForegroundColor = Theme.DefaultText;
            bar.ButtonHoverBackgroundColor = Theme.ControlSeat;
            bar.ButtonHoverForegroundColor = Theme.DefaultText;
            bar.ButtonPressedBackgroundColor = Theme.CaptionPressed;
            bar.ButtonPressedForegroundColor = Theme.DefaultText;
            bar.ButtonInactiveBackgroundColor = Theme.Background;
            bar.ButtonInactiveForegroundColor = Theme.StateIdle;
        }
        catch
        {
            // System caption stays. Content still paints from the tokens.
        }
    }
}
