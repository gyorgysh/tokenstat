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
    internal static bool MotionSuspended => _windowMotionSuspended || ColumnResize.InProgress;
    private bool _windowActive = true;
    private bool _resizing;

    private readonly NavigationView _nav = new();
    private const double RailWidth = ShellWidths.Rail;
    private readonly ResizeHandle _paneResize = new();
    private readonly Border _railFooter = new() { Margin = new Thickness(4, 6, 4, 6) };
    private readonly Dictionary<RailPlace, Button> _pinnedNavigation = new();
    private readonly NavigationViewItem _sshGroup = SshGroup();
    private string _automationRoute = "global:Automations";
    private readonly Frame _frame = new();
    /// <summary>
    /// The content area behind the frame. Opaque Background tone, so the
    /// NavigationView content grid never shows its default grey through.
    /// </summary>
    private readonly Border _contentHost = new();
    /// <summary>
    /// The content body: the global toolbar above, the inspector host below.
    /// One toolbar for the window rather than one per page, mirroring the Mac
    /// detail chrome, which carries the sidebar and inspector marks.
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
    private readonly NavigationViewItemHeader _workspacesHeader = new()
    {
        Content = L10n.Text("common.projects"),
        HorizontalContentAlignment = HorizontalAlignment.Stretch,
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
    private bool _sidebarRefreshPending;
    private bool _suppressNav;
    private string? _lastNavTag;
    private JsonArray _liveSessions = new();
    private JsonArray _liveChats = new();
    private Dictionary<string, JsonNode> _liveSummaries = new(StringComparer.Ordinal);
    private JsonNode? _liveAccount;
    private JsonArray _liveSshSessions = new();
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
        Title = L10n.Text("windows.mainwindow_xaml.tokenstat.63d30539");
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

        // Every shell surface uses the same opaque theme on Windows.
        RootGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(RailWidth) });
        RootGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        Grid.SetColumnSpan(AppTitleBar, 2);
        RootGrid.Background = _chromeBackground;
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
        _nav.OpenPaneLength = ShellWidths.Shared.Sidebar;
        _nav.CompactPaneLength = 0;
        _nav.IsPaneToggleButtonVisible = false;
        // The shell already reserves AppTitleBar's caption row.
        _nav.IsTitleBarAutoPaddingEnabled = false;
        _nav.PaneDisplayMode = NavigationViewPaneDisplayMode.Auto;
        _nav.IsBackButtonVisible = NavigationViewBackButtonVisible.Collapsed;
        _nav.Background = new SolidColorBrush(Colors.Transparent);
        _nav.Resources["NavigationViewDefaultPaneBackground"] = _chromeSidebar;
        _nav.Resources["NavigationViewExpandedPaneBackground"] = _chromeSidebar;
        _nav.Resources["NavigationViewContentBackground"] = _chromeBackground;
        _nav.Resources["NavigationViewContentGridBorderBrush"] = _chromeBorder;
        _nav.Resources["NavigationViewPaneContentGridMargin"] = new Thickness(0);
        _nav.Resources["NavigationViewContentGridBorderThickness"] = new Thickness(1, 0, 0, 0);
        _nav.Resources["NavigationViewBorderThickness"] = new Thickness(0);
        _nav.Resources["NavigationViewMinimalContentGridBorderThickness"] = new Thickness(0);
        _nav.Resources["NavigationViewContentGridCornerRadius"] = new CornerRadius(0);
        _nav.Resources["NavigationViewItemOnLeftMinHeight"] = 32d;
        _nav.Resources["NavigationViewItemContentPresenterMargin"] = new Thickness(4, 0, 4, 0);

        var pinned = new StackPanel { Spacing = 4, Margin = new Thickness(0, 2, 0, 8) };
        foreach (var section in Sections.Standalone.Concat(Sections.Everywhere))
        {
            var item = Item(section);
            item.Visibility = Visibility.Collapsed;
            _nav.MenuItems.Add(item);
        }
        foreach (var place in Enum.GetValues<RailPlace>())
        {
            var button = SidebarChrome.RailButton(RailIcon(place), RailLabel(place), (_, _) =>
            {
                // Workflows share the Automations place; returning preserves that choice.
                var tag = place switch
                {
                    RailPlace.Automations => _automationRoute,
                    RailPlace.Ssh => "ssh:" + (_sshPage?.CurrentSection ?? SSHSection.Hosts),
                    _ => place.Route(),
                };
                NavigateTo(tag);
                if (place == RailPlace.Projects) _ = RefreshSidebarLiveAsync(slow: true);
            });
            _pinnedNavigation[place] = button;
            pinned.Children.Add(button);
        }
        var railBody = new Grid();
        railBody.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        railBody.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        railBody.Children.Add(new ScrollViewer { Content = pinned,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Hidden });
        Grid.SetRow(_railFooter, 1);
        railBody.Children.Add(_railFooter);
        var rail = new Border { Background = _chromeSidebar, Child = railBody };
        Grid.SetRow(rail, 1);
        RootGrid.Children.Add(rail);
        _nav.MenuItems.Add(_workspacesHeader);
        _nav.MenuItems.Add(new NavigationViewItem
        {
            Content = L10n.Text("windows.mainwindow_xaml.all_projects.4b87271b"),
            Tag = "workspaces:all",
            Icon = new SymbolIcon { Symbol = Symbol.Folder },
            Visibility = Visibility.Collapsed,
        });
        _nav.MenuItems.Add(new NavigationViewItem
        {
            Content = L10n.Text("common.add_project"),
            Tag = "workspaces:add",
            Icon = new SymbolIcon { Symbol = Symbol.Add },
        });
        _nav.MenuItems.Add(_sshGroup);
        var searchShortcut = new Microsoft.UI.Xaml.Input.KeyboardAccelerator
        {
            Key = Windows.System.VirtualKey.K,
            Modifiers = Windows.System.VirtualKeyModifiers.Control,
        };
        searchShortcut.Invoked += (_, args) => { OpenSearch(); args.Handled = true; };
        RootGrid.KeyboardAccelerators.Add(searchShortcut);
        RefreshAccountFooter();

        _nav.Content = _contentHost;
        _nav.SelectionChanged += NavOnSelectionChanged;
        Grid.SetRow(_nav, 1);
        Grid.SetColumn(_nav, 1);
        RootGrid.Children.Add(_nav);
        _paneResize.Width = 6;
        _paneResize.HorizontalAlignment = HorizontalAlignment.Left;
        _paneResize.Background = new SolidColorBrush(Colors.Transparent);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_paneResize, L10n.Text("windows.mainwindow_xaml.resize_projects_panel.4be39519"));
        _paneResize.DragDelta += (_, drag) =>
        {
            _nav.OpenPaneLength = ShellWidths.BoundSidebar(_nav.OpenPaneLength + drag.HorizontalChange);
            SyncPaneChrome();
        };
        _paneResize.DragCompleted += (_, _) => { ShellWidths.Shared.RememberSidebar(_nav.OpenPaneLength); SyncInspectorFit(); };
        _paneResize.DoubleTapped += (_, _) => { _nav.OpenPaneLength = ShellWidths.Default; ShellWidths.Shared.RememberSidebar(_nav.OpenPaneLength); SyncPaneChrome(); };
        _paneResize.KeyDown += (_, key) =>
        {
            if (key.Key is not (Windows.System.VirtualKey.Left or Windows.System.VirtualKey.Right)) return;
            _nav.OpenPaneLength = ShellWidths.BoundSidebar(_nav.OpenPaneLength + (key.Key == Windows.System.VirtualKey.Right ? 20 : -20));
            ShellWidths.Shared.RememberSidebar(_nav.OpenPaneLength);
            SyncPaneChrome();
            key.Handled = true;
        };
        Grid.SetRow(_paneResize, 1);
        Grid.SetColumn(_paneResize, 1);
        RootGrid.Children.Add(_paneResize);
        ApplyChromeColors();
        RootGrid.ActualThemeChanged += (_, _) => ApplyChromeColors();
        _contentHost.SizeChanged += (_, _) => SyncInspectorFit();
        _inspectorHost.WidthChanged += SyncInspectorFit;
        // Keep the titlebar split on the pane edge when the pane collapses to
        // its compact width. Native adaptive mode floats it on narrow windows.
        _nav.RegisterPropertyChangedCallback(
            NavigationView.IsPaneOpenProperty,
            (_, _) => PaneStateChanged());

        AppServices.OpenTerminal = (workspaceId, sessionId) =>
        {
            DispatcherQueue.TryEnqueue(() =>
            {
                var workbench = WorkspaceTabs(workspaceId);
                workbench.OpenTerminal(sessionId);
                _lastNavTag = "ws:" + workspaceId + ":Sessions";
                RestoreSelection(_lastNavTag);
                SetContent(workbench, preserveSelection: true);
                if (sessionId is not null)
                {
                    var liveTag = LiveRoute.Join(SidebarLive.SessionPrefix, workspaceId, sessionId);
                    if (FindNavItem(liveTag) is not null) { _lastNavTag = liveTag; RestoreSelection(liveTag); }
                }
            });
        };
        AppServices.OpenTerminalSplit = (workspaceId, sessionId) => DispatcherQueue.TryEnqueue(() =>
        {
            var workbench = WorkspaceTabs(workspaceId);
            workbench.OpenTerminalInSplit(sessionId);
            _lastNavTag = "ws:" + workspaceId + ":Sessions";
            RestoreSelection(_lastNavTag);
            SetContent(workbench, preserveSelection: true);
        });
        WorkspaceSshTabs.Changed += () => DispatcherQueue.TryEnqueue(() =>
        {
            RebuildSidebarLive();
            _ = RefreshSidebarLiveAsync();
        });
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
                _lastNavTag = "global:Machines";
                RestoreSelection(_lastNavTag);
                SetContent(new ScreenPage(peer, name), preserveSelection: true);
            });
        };
        AppServices.OpenOnboarding = () =>
        {
            DispatcherQueue.TryEnqueue(() => ShowOnboarding(firstRun: false));
        };
        AppServices.OpenMachine = id => DispatcherQueue.TryEnqueue(() =>
        {
            NavigateTo("global:Machines");
            SetContent(new MachinesPage(id), preserveSelection: true);
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
                NavigateTo("ws:" + workspaceId + ":Chat");
                var workbench = WorkspaceTabs(workspaceId);
                var liveTag = LiveRoute.Join(SidebarLive.ChatPrefix, workspaceId, chatId);
                if (FindNavItem(liveTag) is not null) { _lastNavTag = liveTag; RestoreSelection(liveTag); }
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
        AppServices.ConversationsChanged += () => DispatcherQueue.TryEnqueue(() => _ = RefreshSidebarLiveAsync());
        AppServices.Update.Changed += () => DispatcherQueue.TryEnqueue(RefreshUpdateBadge);
    }

    private static IconElement GlobalIcon(GlobalSection section) => section switch
    {
        GlobalSection.Home => ActionIcon.Home.Icon(),
        GlobalSection.Machines => new FontIcon { Glyph = char.ToString((char)0xE770), FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets") },
        GlobalSection.Notes => new SymbolIcon(Symbol.Document),
        GlobalSection.Automations => new FontIcon { Glyph = char.ToString((char)0xE945), FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets") },
        _ => new SymbolIcon(section.Symbol()),
    };

    private static string RailLabel(RailPlace place) => place switch
    {
        RailPlace.Home => L10n.Text("common.home"),
        RailPlace.Projects => L10n.Text("common.projects"),
        RailPlace.Tasks => L10n.Text("common.tasks"),
        RailPlace.Notes => L10n.Text("common.notes"),
        RailPlace.Automations => L10n.Text("common.automations"),
        RailPlace.Insights => L10n.Text("common.insights"),
        RailPlace.Devices => L10n.Text("common.devices"),
        _ => GlobalSection.Ssh.Label(),
    };

    private static IconElement RailIcon(RailPlace place) => place switch
    {
        RailPlace.Home => ActionIcon.Home.Icon(),
        RailPlace.Projects => ActionIcon.Reveal.Icon(),
        RailPlace.Tasks => ActionIcon.Apply.Icon(),
        RailPlace.Notes => new FontIcon { Glyph = "\uE8A5" }, // All notes
        RailPlace.Automations => GlobalIcon(GlobalSection.Automations),
        RailPlace.Insights => new SymbolIcon(Symbol.FourBars),
        RailPlace.Devices => GlobalIcon(GlobalSection.Machines),
        _ => new FontIcon { Glyph = "\uE756" }, // Command prompt
    };

    private void UpdateRail(string? tag)
    {
        var selected = RailPlaces.Of(tag);
        foreach (var pair in _pinnedNavigation) SidebarChrome.Select(pair.Value, pair.Key == selected);
    }

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
    /// Retained SSH navigation targets plus the live servers group. Library
    /// sections live in the page's tabs; only running sessions show here.
    /// </summary>
    private static NavigationViewItem SshGroup()
    {
        var parent = new NavigationViewItem
        {
            Content = GlobalSection.Ssh.Label(),
            Tag = "ssh:" + SSHSection.Hosts,
            Icon = new SymbolIcon { Symbol = GlobalSection.Ssh.Symbol() },
            Visibility = Visibility.Collapsed,
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
                Visibility = Visibility.Collapsed,
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
    /// Local folders and every reachable peer's, each opening onto its running
    /// terminals and chats (the sections are tabs on the project page). The
    /// Add project row stays under the folders, followed by live SSH servers.
    /// </summary>
    private void RebuildFolderItems()
    {
        var selectedTag = (_nav.SelectedItem as NavigationViewItem)?.Tag as string;
        var expanded = NavigationExpansion.Capture(NavItems(_nav.MenuItems));
        var keep = new List<object>();
        foreach (var item in _nav.MenuItems)
        {
            if (ReferenceEquals(item, _sshGroup)) continue;
            if (item is NavigationViewItem nav
                && ((nav.Tag as string)?.StartsWith("ws:") == true
                    || (nav.Tag as string)?.StartsWith("machine:") == true
                    || (nav.Tag as string) == "workspaces:empty"
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
        if (_localFolders.Count == 0 && RemoteWorkspaces.CachedFolders().Count == 0)
        {
            var add = Buttons.Primary(L10n.Text("common.add_project"), ActionIcon.Create, async (_, _) => await AddWorkspaceAsync());
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(add, "projects.firstAdd");
            _nav.MenuItems.Add(new NavigationViewItem { Content = EmptyState.FirstProject(add, compact: true),
                Tag = "workspaces:empty", SelectsOnInvoked = false, IsTabStop = false });
        }
        else
        {
            var label = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6,
                Children = { new Viewbox { Width = 12, Height = 12, Child = ActionIcon.Create.Icon() },
                    new TextBlock { Text = L10n.Text("common.add_project"), FontSize = 12, Opacity = 0.7 } } };
            _nav.MenuItems.Add(new NavigationViewItem { Content = label, Tag = "workspaces:add" });
        }
        _nav.MenuItems.Add(_sshGroup);
        UpdateProjectsHeader();
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
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Tag = "ws:" + id + ":Launcher",
            IsExpanded = _nav.IsPaneOpen,
        };
        if (!string.IsNullOrEmpty(path))
        {
            ToolTipService.SetToolTip(parent, path);
        }
        var menu = ContextMenus.Menu(parent);
        async Task NewChat()
        {
            // Finish the native row's selection before opening its action.
            await Task.Yield();
            NavigateTo("ws:" + id + ":Chat");
            if (WorkspaceTabs(id).ActivePage is ChatPage chat) await chat.BeginNewChatAsync();
        }
        ContextMenus.AddAsync(menu, L10n.Text("windows.mainwindow_xaml.new_chat.db18382a"), NewChat);
        WorkPinMenu.Add(menu, id, "", name, name);
        ContextMenus.AddAsync(menu, L10n.Text("windows.mainwindow_xaml.rename_folder.4e3bd8cf"), async () =>
        {
            var input = new TextBox { Text = name };
            var dialog = new ContentDialog { Title = L10n.Text("windows.mainwindow_xaml.rename_folder.7249f19c"), Content = input, PrimaryButtonText = L10n.Text("common.save"), CloseButtonText = L10n.Text("common.cancel"), DefaultButton = ContentDialogButton.Primary };
            input.TextChanged += (_, _) => dialog.IsPrimaryButtonEnabled = input.Text.Trim().Length > 0;
            if (await Chrome.ShowDialog(parent, dialog) != ContentDialogResult.Primary || input.Text.Trim().Length == 0) return;
            await RemoteWorkspaces.CallWorkspaceAsync(id, "workspace.rename", new JsonObject { ["id"] = id, ["name"] = input.Text.Trim() });
            var memory = await BrowserProjectMemory.ForAsync(id);
            if (memory is not null) PinnedWorkStore.Shared.Rename(memory.Owner, "", input.Text.Trim());
            if (remote) await RemoteWorkspaces.SweepAsync();
            await TryLoadFoldersAsync(refresh: true);
        });
        ContextMenus.Add(menu, L10n.Text("windows.mainwindow_xaml.open_folder.6a908402"), () => NavigateTo("ws:" + id + ":Launcher"));
        ContextMenus.Copy(menu, L10n.Text("windows.mainwindow_xaml.copy_path.720ff416"), () => path);
        if (Format.Flag(git, "isRepo"))
            ContextMenus.AddAsync(menu, L10n.Text("windows.mainwindow_xaml.worktrees.c336cb52"), async () =>
            {
                var created = await ProjectWorktreeDialog.ShowAsync(parent, id, name, path);
                if (created is null) return;
                if (remote) await RemoteWorkspaces.SweepAsync();
                await TryLoadFoldersAsync(refresh: true);
                NavigateTo("ws:" + created + ":Launcher");
            });
        if (!remote && !string.IsNullOrEmpty(path))
            ContextMenus.AddAsync(menu, L10n.Text("windows.mainwindow_xaml.reveal_in_file_explorer.b46c90d0"), async () =>
            {
                try { await Windows.System.Launcher.LaunchFolderAsync(await Windows.Storage.StorageFolder.GetFolderFromPathAsync(path)); }
                catch (Exception ex) { await Chrome.ShowDialog(parent, new ContentDialog { Title = L10n.Text("windows.mainwindow_xaml.could_not_open_folder.8f6c587f"), Content = ex.Message, CloseButtonText = L10n.Text("common.close") }); }
            });
        if (RemoteWorkspaces.TrySplit(id, out var peer, out _))
            ContextMenus.Add(menu, L10n.Text("windows.mainwindow_xaml.disconnect_from_this_computer.4ce30719"), () => RemoteWorkspaces.Disconnect(peer));
        ContextMenus.Add(menu, L10n.Text("windows.mainwindow_xaml.expand_collapse"), () => parent.IsExpanded = !parent.IsExpanded);
        ContextMenus.AddAsync(menu, L10n.Text("windows.mainwindow_xaml.remove_from_tokenstat.195e6064"), async () =>
        {
            var confirm = new ContentDialog { Title = L10n.Text("windows.mainwindow_xaml.remove_this_folder.5937b581"), Content = L10n.Text("windows.mainwindow_xaml.the_folder_and_its_files_stay_on_disk.c089e1af"), PrimaryButtonText = L10n.Text("common.remove"), CloseButtonText = L10n.Text("windows.mainwindow_xaml.keep_it.fdce5da2"), DefaultButton = ContentDialogButton.Close };
            if (await Chrome.ShowDialog(parent, confirm) != ContentDialogResult.Primary) return;
            try
            {
                await RemoteWorkspaces.CallWorkspaceAsync(id, "workspace.remove", new JsonObject { ["id"] = id });
                var memory = await BrowserProjectMemory.ForAsync(id);
                if (memory is not null) PinnedWorkStore.Shared.Remove(memory.Owner, "");
                await TryLoadFoldersAsync(refresh: true);
            }
            catch (Exception ex) { await Chrome.ShowDialog(parent, new ContentDialog { Title = L10n.Text("windows.mainwindow_xaml.could_not_remove_folder.36080129"), Content = ex.Message, CloseButtonText = L10n.Text("common.close") }); }
        });
        var label = (UIElement)parent.Content;
        parent.Content = null;
        var compose = Buttons.ToolbarIcon(ActionIcon.Edit, L10n.Text("windows.mainwindow_xaml.new_chat_in_0.2436f7d3", $"{name}"), async (_, _) => await NewChat());
        compose.Width = compose.Height = 22;
        var more = ActionIconGlyph.MoreButton(L10n.Text("windows.mainwindow_xaml.project_actions.5d4ef7cc"), menu);
        more.Width = more.Height = 22;
        more.MinWidth = more.MinHeight = 0;
        more.Padding = new Thickness(0);
        SidebarChrome.RevealActions(parent, compose, more);
        parent.Content = SidebarChrome.ProjectContent(parent, label, remote, compose, more);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(parent, name);
        return parent;
    }

    private void UpdateProjectsHeader()
    {
        var header = new Grid { ColumnSpacing = Theme.SpaceS };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(new TextBlock { Text = L10n.Text("common.projects").ToUpperInvariant(),
            FontSize = 11, Opacity = 0.55, VerticalAlignment = VerticalAlignment.Center });
        var count = new TextBlock { Text = (_localFolders.Count + RemoteWorkspaces.CachedFolders().Count()).ToString(),
            FontSize = 11, Opacity = 0.45, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(count, 1);
        header.Children.Add(count);
        var add = Buttons.ToolbarIcon(ActionIcon.Create, L10n.Text("common.add_project"), async (_, _) => await AddWorkspaceAsync());
        add.Width = add.Height = 22;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(add, "sidebar.addProject");
        Grid.SetColumn(add, 2);
        header.Children.Add(add);
        _workspacesHeader.Content = header;
    }

    private static UIElement FolderLabel(string name, JsonNode? git)
    {
        var label = new Grid { ColumnSpacing = 6 };
        label.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        label.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        label.Children.Add(new TextBlock { Text = name, FontSize = 13, TextTrimming = TextTrimming.CharacterEllipsis });
        if (git is not null && Format.Flag(git, "isRepo"))
        {
            var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            var added = Format.Long(git, "added");
            var removed = Format.Long(git, "removed");
            if (added > 0) line.Children.Add(new TextBlock { Text = "+" + added, FontSize = 11, Foreground = Theme.Brush(static () => Theme.DiffAdded) });
            if (removed > 0) line.Children.Add(new TextBlock { Text = "−" + removed, FontSize = 11, Foreground = Theme.Brush(static () => Theme.DiffRemoved) });
            Grid.SetColumn(line, 1);
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
        _deviceDetailsSource = page as IInspectorRequest;
        if (_deviceDetailsSource is not null) _deviceDetailsSource.DetailsRequested += OnDeviceDetailsRequested;
        _toolbarSource = page as IToolbarItems;
        if (_toolbarSource is not null)
        {
            _toolbarSource.ToolbarChanged += OnToolbarChanged;
        }
        _inspectorPopover?.Hide();
        _frame.Content = page;
        _inspectorHost.RouteAllowsInspector = page is not AccountPage;
        _inspectorHost.MinimumContentWidth = (page as IInspectorContent)?.MinimumContentWidth ?? ShellWidths.ContentMinimum;
        _inspectorHost.MinimumInspectorWidth = (page as IInspectorContent)?.MinimumInspectorWidth ?? ShellWidths.Minimum;
        SyncInspectorFit();
        if (!_inspectorInPopover)
            _inspectorHost.SetInspector((page as IInspectorContent)?.Inspector, page is WorkspaceTabsPage or HomePage);
        if (page is IScopeAware aware)
        {
            aware.ApplyScope(_scope);
        }
        RebuildToolbar();
        Motion.PlayArrival(page);
    }

    private IToolbarItems? _toolbarSource;
    private IInspectorRequest? _deviceDetailsSource;
    private bool _inspectorInPopover;
    private Flyout? _inspectorPopover;

    private void OnDeviceDetailsRequested()
    {
        _inspectorHost.MinimumContentWidth = (_frame.Content as IInspectorContent)?.MinimumContentWidth ?? ShellWidths.ContentMinimum;
        _inspectorHost.MinimumInspectorWidth = (_frame.Content as IInspectorContent)?.MinimumInspectorWidth ?? ShellWidths.Minimum;
        SyncInspectorFit();
        _inspectorHost.IsOpen = true;
        if (_inspectorHost.FitsWidth) { _inspectorHost.Refresh(); RebuildToolbar(); }
        else ShowInspectorPopover();
    }

    private void ShowInspectorPopover()
    {
        if (_inspectorInPopover || _frame.Content is not Page page
            || page is not IInspectorContent { Inspector: UIElement detail }) return;
        _inspectorInPopover = true;
        _inspectorHost.SetInspector(null);
        var scroll = new ScrollViewer
        {
            Content = detail, Width = Math.Min(420, Math.Max(240, _contentHost.ActualWidth - 64)),
            MaxHeight = Math.Max(160, _contentHost.ActualHeight - 160),
        };
        if (page is WorkspaceTabsPage)
        {
            scroll.Height = Math.Max(240, _contentHost.ActualHeight - 128);
            scroll.VerticalScrollMode = ScrollMode.Disabled;
            scroll.VerticalScrollBarVisibility = ScrollBarVisibility.Disabled;
            scroll.VerticalContentAlignment = VerticalAlignment.Stretch;
        }
        var body = new StackPanel { Spacing = Theme.SpaceM };
        var popover = new Flyout { Content = body };
        _inspectorPopover = popover;
        body.Children.Add(Buttons.Secondary(L10n.Text("windows.mainwindow_xaml.close_details.edc82d69"), ActionIcon.Back, (_, _) => popover.Hide(), small: true));
        body.Children.Add(scroll);
        void Restore()
        {
            scroll.Content = null;
            _inspectorInPopover = false;
            _inspectorPopover = null;
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
            _inspectorHost.MinimumContentWidth = (_frame.Content as IInspectorContent)?.MinimumContentWidth ?? ShellWidths.ContentMinimum;
            _inspectorHost.MinimumInspectorWidth = (_frame.Content as IInspectorContent)?.MinimumInspectorWidth ?? ShellWidths.Minimum;
            SyncInspectorFit();
            if (!_inspectorInPopover)
                _inspectorHost.SetInspector((_frame.Content as IInspectorContent)?.Inspector, _frame.Content is WorkspaceTabsPage or HomePage);
            RebuildToolbar();
        });
    }

    /// <summary>
    /// Rebuild the one top bar for what is on screen, like the Mac contextual
    /// toolbar: the device scope picker on Home and Insights, then the page's
    /// scope chip and actions, and the inspector toggle last, nearest the edge
    /// it opens. Search lives in the project sidebar. Account never
    /// shows an inspector, so it gets no toggle either.
    /// </summary>
    private void RebuildToolbar()
    {
        var content = _frame.Content;
        var leading = new List<UIElement>
        {
            Buttons.ToolbarIcon(ActionIcon.Sidebar, L10n.Text("windows.mainwindow_xaml.show_or_hide_projects.0d518392"),
                (_, _) => _nav.IsPaneOpen = !_nav.IsPaneOpen),
        };
        if (content is HomePage or InsightsPage)
        {
            leading.Add(ScopePicker());
        }
        if (content is IToolbarItems scoped && scoped.ToolbarScope is UIElement chip)
        {
            leading.Add(chip);
        }
        else if (content is AutomationsPage or WorkflowsPage)
        {
            leading.Add(SegmentedCapsule.View(new List<(string Value, string Label, ActionIcon? Glyph)>
            {
                ("global:Automations", L10n.Text("common.automations"), ActionIcon.Scheduled),
                ("global:Workflows", L10n.Text("common.workflows"), ActionIcon.Move),
            }, content is WorkflowsPage ? "global:Workflows" : "global:Automations", tag =>
            {
                NavigateTo(tag);
                return Task.CompletedTask;
            }));
        }
        else if (content is TodoPage or NotesPage or MachinesPage or SshPage)
        {
            leading.Add(new TextBlock
            {
                Text = content switch
                {
                    TodoPage => L10n.Text("common.tasks"), NotesPage => L10n.Text("common.notes"),
                    MachinesPage => L10n.Text("common.devices"), _ => GlobalSection.Ssh.Label(),
                },
                FontSize = 14, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                VerticalAlignment = VerticalAlignment.Center,
            });
        }
        var trailing = new List<UIElement>();
        if (content is IToolbarItems items)
        {
            foreach (var action in items.ToolbarActions())
            {
                trailing.Add(action);
            }
        }
        if (content is IInspectorContent inspector && inspector.Inspector is not null
            && _inspectorHost.RouteAllowsInspector)
        {
            // Last, nearest the edge it opens, like the Mac: the toggle is the
            // control beside the column it controls.
            bool open = _inspectorHost.IsInspectorVisible;
            trailing.Add(Buttons.ToolbarIcon(
                ActionIcon.Collapse,
                open ? L10n.Text("windows.mainwindow_xaml.hide_inspector.a4baccaf") : L10n.Text("windows.mainwindow_xaml.show_inspector.fe07e804"),
                (_, _) => ToggleInspector(),
                open));
        }
        _toolbarSlot.Child = DetailBar.View(leading, null, null, trailing);
    }

    /// <summary>
    /// The This device / All devices switch, with the same device and globe
    /// marks as the Mac, fixed at the picker's width so the bar never
    /// jitters between selections.
    /// </summary>
    private UIElement ScopePicker()
    {
        var options = new List<(string Value, string Label, ActionIcon? Glyph)>
        {
            ("local", L10n.Text("windows.mainwindow_xaml.this_device.d052579c"), ActionIcon.Computer),
            ("account", L10n.Text("windows.mainwindow_xaml.all_devices.0594fe82"), ActionIcon.Browser),
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
    /// Open search from the sidebar or Ctrl+K. The selection clears:
    /// leaving the old row lit would claim the sidebar
    /// and the content agree when they do not, and the lit row would not
    /// navigate back.
    /// </summary>
    private void OpenSearch()
    {
        NavigateTo("global:Search");
    }

    private void ToggleInspector()
    {
        if (!_inspectorHost.FitsWidth) { ShowInspectorPopover(); return; }
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
        var companionWidth = _inspectorHost.MinimumInspectorWidth > ShellWidths.Minimum
            ? Math.Max(_inspectorHost.MinimumInspectorWidth, ShellWidths.Shared.Inspector) + 6 : 0;
        _nav.ExpandedModeThresholdWidth = ShellWidths.Shared.Sidebar + _inspectorHost.MinimumContentWidth + companionWidth;
        _nav.CompactModeThresholdWidth = _nav.ExpandedModeThresholdWidth - 1;
        bool fits = _contentHost.ActualWidth <= 0 || _contentHost.ActualWidth >= _inspectorHost.RequiredWidth;
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
        // Live rows under the folder parents, like the Mac sidebar. Actions
        // such as Show more leave the current rail destination selected.
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
            ToggleChatHistory(tag[SidebarLive.ChatMorePrefix.Length..]);
            return;
        }
        if (tag.StartsWith(SidebarLive.ChatAllPrefix, StringComparison.Ordinal))
        {
            OpenAllChats(tag[SidebarLive.ChatAllPrefix.Length..]);
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

    private void ToggleChatHistory(string folder)
    {
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
        else if (ProjectRowFor("ws:" + folder + ":Chat") is NavigationViewItem chatRow)
        {
            _nav.SelectedItem = chatRow;
        }
        _suppressNav = false;
    }

    private void OpenAllChats(string folder)
    {
        var chatTag = "ws:" + folder + ":Chat";
        if (ProjectRowFor(chatTag) is NavigationViewItem chatRow)
        {
            _suppressNav = true;
            _nav.SelectedItem = chatRow;
            _suppressNav = false;
        }
        _lastNavTag = chatTag;
        Show(chatTag);
        if (WorkspaceTabs(folder).ActivePage is ChatPage chat) _ = chat.ShowChatsAsync();
        RefreshUpdateBadge();
    }

    private void Show(string tag)
    {
        if (tag == "workspaces:add")
        {
            _ = AddWorkspaceAsync();
            return;
        }
        UpdateRail(tag);
        if (tag is "global:Automations" or "global:Workflows") _automationRoute = tag;
        if (tag.StartsWith("sshterm:", StringComparison.Ordinal))
        {
            SetContent(Ssh(SSHSection.Hosts, tag["sshterm:".Length..]), preserveSelection: true);
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
                    GlobalSection.Notes => _globalNotesPage ??= new NotesPage(),
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
    // Failed autosaves keep the person's draft in the page. Retain it when
    // global navigation leaves Notes, as project workbenches already do.
    private NotesPage? _globalNotesPage;
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
                    RemoteWorkspaces.TrySplit(id, out var browserPeer, out _) ? browserPeer : null, workspaceId: id),
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
            WorkspaceSection.Browser => new BrowserPage("", "127.0.0.1", 0, false, workspaceId: id),
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
        _nav.SelectedItem = tag is null ? null : FindNavItem(tag) ?? ProjectRowFor(tag);
        _suppressNav = false;
        UpdateRail(tag);
    }

    /// <summary>
    /// A project section has no sidebar row of its own, so the project's row
    /// lights while one of its sections is on screen.
    /// </summary>
    private NavigationViewItem? ProjectRowFor(string tag)
    {
        if (!tag.StartsWith("ws:", StringComparison.Ordinal)) return null;
        var cut = tag.LastIndexOf(':');
        return cut <= "ws:".Length ? null : FindNavItem(tag[..cut] + ":Launcher");
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
            Text = L10n.Text("windows.mainwindow_xaml.all_projects.4b87271b"),
            FontSize = 28,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
        });
        var spacer = new Grid { Width = Theme.SpaceM };
        head.Children.Add(spacer);
        head.Children.Add(Buttons.Primary(
            L10n.Text("common.add_project"), ActionIcon.Create, async (_, _) =>
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
            root.Children.Add(EmptyState.FirstProject(Buttons.Primary(L10n.Text("common.add_project"), ActionIcon.Create,
                async (_, _) => { await AddWorkspaceAsync(); if (ReferenceEquals(_frame.Content, page)) await FillOverviewAsync(root, page); })));
            return;
        }
        var filters = new Grid { ColumnSpacing = Theme.SpaceM };
        filters.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        filters.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var search = new TextBox { PlaceholderText = L10n.Text("windows.mainwindow_xaml.search_projects.9e079c7d"), MinWidth = 120 };
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
            if (id.Length > 0) AddFolder(id, Format.Text(folder, "name", id), Format.Text(folder, "path"), L10n.Text("windows.mainwindow_xaml.this_pc.638a348b"), folder?["git"]);
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
            identity.Children.Add(new TextBlock { Text = L10n.Text("windows.mainwindow_xaml.0_chats_1_tasks.52809945", $"{Format.Long(summary, "chats")}", $"{Format.Long(summary, "tasks")}"),
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
            await WorkspaceDiff.ShowFileDiffAsync(this, L10n.Text("windows.mainwindow_xaml.diff_file", filePath), diff);
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
                    L10n.Text("windows.mainwindow_xaml.reload_history.1efa15f0"),
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
            _sidebarRefreshPending = true;
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
            var previousSshSessions = _liveSshSessions;
            // Discover newly registered folders before asking for their chats.
            if (slow) await TryLoadFoldersAsync(refresh: true);
            var (sessions, chats) = await SidebarLive.FetchFastAsync(
                _localFolders.Select(folder => Format.Text(folder, "id"))
                    .Concat(RemoteWorkspaces.CachedFolders().Select(folder => folder.Id)));
            try
            {
                var sshSessions = Format.Items(await AppServices.Host.CallAsync("ssh.session.list"));
                if (sshSessions is not null) _liveSshSessions = sshSessions;
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
                        ContextMenus.AddAsync(menu, L10n.Text("windows.mainwindow_xaml.close_session.03362c26"), async () =>
                        {
                            var owner = menu.Target ?? row;
                            var confirm = new ContentDialog { Title = L10n.Text("windows.mainwindow_xaml.close_this_ssh_session.a11d9419"), Content = L10n.Text("windows.mainwindow_xaml.the_shell_will_stop.9beb2839"), PrimaryButtonText = L10n.Text("windows.mainwindow_xaml.close_session.e503367c"), CloseButtonText = L10n.Text("windows.mainwindow_xaml.keep_running.154949db"), DefaultButton = ContentDialogButton.Close };
                            if (await Chrome.ShowDialog(owner, confirm) != ContentDialogResult.Primary) return;
                            try { await AppServices.Host.CallAsync("ssh.session.close", new JsonObject { ["id"] = sessionId }); await RefreshSidebarLiveAsync(); }
                            catch (Exception ex) { await Chrome.ShowDialog(owner, new ContentDialog { Title = L10n.Text("windows.mainwindow_xaml.could_not_close_session.f56b373d"), Content = ex.Message, CloseButtonText = L10n.Text("common.close") }); }
                        });
                    }
                    NavigationRows.Reconcile(sshGroup.MenuItems, wanted, "sshterm:");
                    if (sshGroup.Visibility == Visibility.Collapsed && wanted.Count > 0) sshGroup.IsExpanded = _nav.IsPaneOpen;
                    sshGroup.Visibility = wanted.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
                }
            }
            catch { /* Keep reachable session rows on a transient host failure. */ }
            if (slow)
            {
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
                || !JsonNode.DeepEquals(previousSshSessions, _liveSshSessions)
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
            if (_sidebarRefreshPending)
            {
                var pendingSlow = _sidebarSlowRefreshPending;
                _sidebarRefreshPending = false;
                _sidebarSlowRefreshPending = false;
                _ = RefreshSidebarLiveAsync(slow: pendingSlow);
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
        foreach (var chat in _liveChats)
        {
            if (chat is null)
            {
                continue;
            }
            var folder = Format.Text(chat, "workspaceId");
            var id = Format.Text(chat, "id");
            if (string.IsNullOrEmpty(folder) || string.IsNullOrEmpty(id))
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

        // Running terminals, then chats, directly under each project, as on
        // the Mac. Section rows under every project repeated what the
        // project page's own tabs already offer.
        foreach (var item in NavItems(_nav.MenuItems).Where(row => (row.Tag as string)?.StartsWith("ws:") == true && (row.Tag as string)?.EndsWith(":Launcher") == true).ToList())
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
            var folder = _localFolders.FirstOrDefault(folder => Format.Text(folder, "id") == folderId);
            var desiredSessions = new List<NavigationViewItem>();
            if (sessionsByFolder.TryGetValue(folderId, out var sessions) && sessions.Count > 0)
            {
                foreach (var session in sessions)
                {
                    desiredSessions.Add(SidebarLive.SessionItem(folderId, session, folder));
                }
            }
            foreach (var session in _liveSshSessions.Where(session => Format.Flag(session, "alive")
                && WorkspaceSshTabs.In(folderId).Contains(Format.Text(session, "id"))))
            {
                var id = "ssh:" + Format.Text(session, "id");
                var row = new NavigationViewItem { Tag = LiveRoute.Join(SidebarLive.SessionPrefix, folderId, id), Content = SshHostPlatform.SessionRow(session) };
                SidebarHoverCard.AttachSsh(row, folderId, session, folder);
                var menu = ContextMenus.Menu(row);
                ContextMenus.Add(menu, L10n.Text("common.open"), () => AppServices.OpenTerminal?.Invoke(folderId, id));
                ContextMenus.Add(menu, L10n.Text("windows.terminalpane.open_in_split"), () => AppServices.OpenTerminalSplit?.Invoke(folderId, id));
                desiredSessions.Add(row);
            }
            NavigationRows.Reconcile(parent.MenuItems, desiredSessions, SidebarLive.SessionPrefix, 0);
            var desiredChats = new List<NavigationViewItem>();
            if (chatsByFolder.TryGetValue(folderId, out var chats) && chats.Count > 0)
            {
                var expanded = _liveChatExpanded.Contains(folderId);
                int? selectedIndex = null;
                if (selectedTag is not null && LiveRoute.TrySplit(selectedTag, SidebarLive.ChatPrefix, out var selectedFolder, out var selectedId)
                    && selectedFolder == folderId)
                {
                    var index = chats.FindIndex(chat => Format.Text(chat, "id") == selectedId);
                    if (index >= 0) selectedIndex = index;
                    if (index >= SidebarLive.CollapsedChats) expanded = true;
                }
                var window = ChatHistoryWindow.Visible(chats.Count, selectedIndex, expanded);
                var shown = window.Count;
                var folderName = RemoteWorkspaces.CachedFolder(folderId)?.Name
                    ?? Format.Text(_localFolders.FirstOrDefault(folder => Format.Text(folder, "id") == folderId), "name", L10n.Text("windows.mainwindow_xaml.project.98595978"));
                for (var i = window.Start; i < window.Start + window.Count; i++)
                    desiredChats.Add(SidebarLive.ChatItem(folderId, chats[i], folderName, folder));
                if (chats.Count > SidebarLive.CollapsedChats)
                {
                    var label = expanded
                        ? L10n.Text("windows.mainwindow_xaml.show_less.94ea9b1d")
                        : L10n.Text("windows.mainwindow_xaml.show_0_more.b91c3640", $"{(Math.Min(chats.Count, SidebarLive.InlineChats) - shown)}");
                    desiredChats.Add(SidebarChrome.ChatFooter(
                        SidebarLive.ChatMorePrefix + folderId, label,
                        () => ToggleChatHistory(folderId),
                        chats.Count > SidebarLive.InlineChats ? () => OpenAllChats(folderId) : null));
                }
            }
            // "wschat" covers the chat rows and their Show more and See all
            // rows, which share the prefix.
            NavigationRows.Reconcile(parent.MenuItems, desiredChats, "wschat", desiredSessions.Count);
            SidebarChrome.AlignProject(parent);
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
        key += "|" + _nav.IsPaneOpen;
        _railFooter.Visibility = Visibility.Visible;
        if (key == _liveFooterKey)
        {
            return;
        }
        _liveFooterKey = key;
        var presentation = signedIn && account is not null ? account : new JsonObject { ["displayName"] = L10n.Text("common.sign_in") };
        _railFooter.Child = AccountMenu(presentation);
        _nav.PaneFooter = _nav.IsPaneOpen ? AccountMenu(presentation, expanded: true) : null;
    }

    private UIElement AccountMenu(JsonNode account, bool expanded = false)
    {
        var name = Format.Text(account, "displayName");
        if (string.IsNullOrWhiteSpace(name)) name = Format.Text(account, "handle", L10n.Text("common.account"));
        if (string.IsNullOrWhiteSpace(name)) name = L10n.Text("common.account");
        FrameworkElement? avatar = null;
        UIElement identity;
        if (!expanded)
        {
            // The rail owns the one avatar; the open sidebar carries labels
            // beside it, rather than repeating the portrait in both columns.
            avatar = ProfileHoverRing.Wrap(Marks.Avatar(url: Format.Text(account, "avatar"), name: name,
                handle: Format.Text(account, "handle"), size: 28), 28);
            var portrait = new Grid { Width = 36, Height = 36 };
            portrait.Children.Add(avatar);
            if (Format.Flag(account, "signedIn") && Marks.TierMark(Format.Text(account, "tier"), 11) is FrameworkElement mark)
                portrait.Children.Add(new Border { Width = 17, Height = 17, CornerRadius = new CornerRadius(9), Background = Theme.Brush(static () => Theme.Sidebar),
                    BorderBrush = Theme.BorderBrush, BorderThickness = new Thickness(1), Child = mark,
                    HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom, IsHitTestVisible = false });
            identity = portrait;
        }
        else
        {
            var labels = new StackPanel { Spacing = 3, VerticalAlignment = VerticalAlignment.Center };
            labels.Children.Add(new TextBlock { Text = name, FontSize = 13, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis });
            var tier = Format.Text(account, "tier");
            var handle = Format.Text(account, "handle");
            if (!string.IsNullOrWhiteSpace(tier)) labels.Children.Add(new TextBlock { Text = tier[..1].ToUpperInvariant() + tier[1..], FontSize = 11, Opacity = 0.7, TextTrimming = TextTrimming.CharacterEllipsis });
            else if (!string.IsNullOrWhiteSpace(handle)) labels.Children.Add(new TextBlock { Text = "@" + handle, FontSize = 11, Opacity = 0.7, TextTrimming = TextTrimming.CharacterEllipsis });
            identity = labels;
        }
        var footer = new Button
        {
            Content = identity,
            Width = expanded ? double.NaN : 44, Height = 44, Padding = new Thickness(expanded ? 0 : 4),
            HorizontalAlignment = expanded ? HorizontalAlignment.Stretch : HorizontalAlignment.Center,
            MinWidth = 0, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Background = new SolidColorBrush(Colors.Transparent), BorderThickness = new Thickness(0),
        };
        if (avatar is not null) ProfileHoverRing.Attach(avatar, footer);
        var label = AppServices.Update.IsReady || AppServices.Update.IsAvailable ? L10n.Text("windows.mainwindow_xaml.account_update_available.29a1fbd6") : L10n.Text("windows.mainwindow_xaml.account_0.d8cd9318", $"{name}");
        if (expanded && !string.IsNullOrWhiteSpace(Format.Text(account, "tier"))) label = L10n.Text("common.account_plan_label", name, Format.Text(account, "tier"));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(footer, label);
        ToolTipService.SetToolTip(footer, label);
        var menu = new MenuFlyout();
        foreach (var section in new[] { GlobalSection.Account, GlobalSection.About })
        {
            var item = new MenuFlyoutItem
            {
                Text = section == GlobalSection.Account && (AppServices.Update.IsReady || AppServices.Update.IsAvailable)
                    ? L10n.Text("windows.mainwindow_xaml.account_update_available.29a1fbd6") : section.ToString(),
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
        var checkUpdate = new MenuFlyoutItem { Text = L10n.Text("windows.accountpage.check_for_updates") };
        checkUpdate.Click += async (_, _) =>
        {
            NavigateTo("global:" + GlobalSection.Account);
            await AppServices.Update.CheckNowAsync();
        };
        menu.Items.Add(checkUpdate);
        if (!expanded) return footer;
        var bar = new Grid { ColumnSpacing = Theme.SpaceS };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.Children.Add(footer);
        var settings = Buttons.ToolbarIcon(ActionIcon.Settings, L10n.Text("common.settings"), (_, _) =>
        {
            _nav.SelectedItem = null;
            _lastNavTag = "global:" + GlobalSection.Account;
            Show(_lastNavTag);
        });
        settings.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(settings, 1);
        bar.Children.Add(settings);
        return new Border { Child = bar, Padding = new Thickness(0), Margin = new Thickness(6),
            Background = new SolidColorBrush(Colors.Transparent) };
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
            AppWindow.GetFromWindowId(id).Title = L10n.Text("windows.mainwindow_xaml.tokenstat.63d30539");
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
        _chromeSidebar.Color = Theme.Sidebar;
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
        SyncInspectorFit();
        SyncTitleBarSplit();
        _paneResize.Visibility = _nav.IsPaneOpen ? Visibility.Visible : Visibility.Collapsed;
        _paneResize.Margin = new Thickness(Math.Max(0, _nav.OpenPaneLength - 3), 0, 0, 0);
        _nav.PaneHeader = _nav.IsPaneOpen ? LogoOpen() : null;
        RefreshAccountFooter();
        var show = _nav.IsPaneOpen ? Visibility.Visible : Visibility.Collapsed;
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
        var content = new StackPanel { Spacing = 0, Margin = new Thickness(0, 0, 0, Theme.SpaceM) };
        content.Children.Add(new Border { Height = DetailBar.Height,
            Padding = new Thickness(Theme.SpaceM, 0, Theme.SpaceM, 3), Child = Marks.Wordmark() });
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
                if (id.Length > 0) AddProject(id, Format.Text(folder, "name"), L10n.Text("windows.mainwindow_xaml.this_pc.638a348b"), Format.Text(folder, "path"));
            }
            foreach (var folder in RemoteWorkspaces.CachedFolders())
                AddProject(folder.Id, folder.Name, folder.MachineLabel, folder.Path);
            if (menu.Items.Count == 0)
                menu.Items.Add(new MenuFlyoutItem { Text = L10n.Text("windows.mainwindow_xaml.add_a_project_first.cc9bc2c9"), IsEnabled = false });
        };
        var create = SidebarChrome.Row(L10n.Text("windows.mainwindow_xaml.new_chat.db18382a"), ActionIcon.Edit, (_, _) => { });
        create.Flyout = menu;
        create.HorizontalAlignment = HorizontalAlignment.Stretch;
        ToolTipService.SetToolTip(create, L10n.Text("windows.mainwindow_xaml.choose_which_project_the_new_chat_belongs.e9b181c8"));
        content.Children.Add(create);
        content.Children.Add(SidebarChrome.Row(L10n.Text("common.search"), ActionIcon.Search, (_, _) => OpenSearch(), "Ctrl+K"));
        return content;
    }

    /// <summary>
    /// Keep the titlebar split on the pane edge: full length while the pane is
    /// open, compact length once it collapses to icons.
    /// </summary>
    private void SyncTitleBarSplit()
    {
        TitlePaneColumn.Width = new GridLength(RailWidth + (_nav.IsPaneOpen ? _nav.OpenPaneLength : _nav.CompactPaneLength));
        TitlePaneSide.Background = _nav.IsPaneOpen ? _chromeSidebar : _chromeBackground;
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
