// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Text.Json.Nodes;
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
    private readonly NavigationView _nav = new();
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
    private DeviceScope _scope = DeviceScope.AllDevices;
    // One brush instance per flat surface, shared by every element showing
    // that tone. A theme change mutates the color in place, which reaches the
    // NavigationView template too: a StaticResource lookup would keep a
    // replaced brush, but it cannot keep a mutated one.
    private readonly SolidColorBrush _chromeBackground = new(Theme.Background);
    private readonly SolidColorBrush _chromeSidebar = new(Theme.Sidebar);
    private readonly SolidColorBrush _chromeBorder = new(Theme.Border);
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
    private bool _suppressNav;
    private string? _lastNavTag;
    private JsonArray _liveSessions = new();
    private JsonArray _liveChats = new();
    private Dictionary<string, JsonNode> _liveSummaries = new(StringComparer.Ordinal);
    private JsonNode? _liveAccount;
    private string _liveFooterKey = "";

    public MainWindow()
    {
        InitializeComponent();
        Title = "tokenstat";
        TryExtendIntoTitleBar();
        TrySize();
        TryIcon();

        // Flat theme surfaces, no Mica: the Mac app is flat colors everywhere,
        // and a translucent backdrop would tint every tone it sits behind.
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

        _nav.IsSettingsVisible = false;
        _nav.OpenPaneLength = 240;
        _nav.PaneDisplayMode = NavigationViewPaneDisplayMode.Left;
        _nav.IsBackButtonVisible = NavigationViewBackButtonVisible.Collapsed;
        _nav.Background = _chromeSidebar;
        _nav.Resources["NavigationViewContentBackground"] = _chromeBackground;
        _nav.Resources["NavigationViewContentGridBorderBrush"] = _chromeBorder;

        foreach (var section in Sections.Standalone)
        {
            _nav.MenuItems.Add(Item(section));
        }
        _nav.MenuItems.Add(new NavigationViewItemSeparator());
        _nav.MenuItems.Add(new NavigationViewItemHeader { Content = "GLOBAL" });
        foreach (var section in Sections.Everywhere)
        {
            _nav.MenuItems.Add(Item(section));
        }
        _nav.MenuItems.Add(new NavigationViewItemSeparator());
        _nav.MenuItems.Add(SshGroup());
        _nav.MenuItems.Add(new NavigationViewItemSeparator());
        _nav.MenuItems.Add(_workspacesHeader);
        _nav.MenuItems.Add(new NavigationViewItem
        {
            Content = "All folders",
            Tag = "workspaces:all",
            Icon = new SymbolIcon { Symbol = Symbol.Folder },
        });
        _nav.MenuItems.Add(new NavigationViewItem
        {
            Content = "Add workspace",
            Tag = "workspaces:add",
            Icon = new SymbolIcon { Symbol = Symbol.Add },
        });

        // Search is a toolbar icon, like the Mac: it opens the search page from
        // anywhere without taking a row. Account and About keep the footer.
        _nav.FooterMenuItems.Add(Item(GlobalSection.Account));
        _nav.FooterMenuItems.Add(Item(GlobalSection.About));

        _nav.Content = _contentHost;
        _nav.SelectionChanged += NavOnSelectionChanged;
        Grid.SetRow(_nav, 1);
        RootGrid.Children.Add(_nav);
        ApplyChromeColors();
        RootGrid.ActualThemeChanged += (_, _) => ApplyChromeColors();
        RootGrid.SizeChanged += (_, _) => SyncInspectorFit();
        // Keep the titlebar split on the pane edge when the pane collapses to
        // its compact width. The display mode itself is fixed at Left.
        _nav.RegisterPropertyChangedCallback(
            NavigationView.IsPaneOpenProperty,
            (_, _) => SyncPaneChrome());

        AppServices.OpenTerminal = (workspaceId, sessionId) =>
        {
            DispatcherQueue.TryEnqueue(() =>
            {
                SetContent(new TerminalPage(workspaceId, sessionId));
                RestoreSelection(SidebarLive.SessionPrefix + workspaceId + ":" + sessionId);
                _lastNavTag = (_nav.SelectedItem as NavigationViewItem)?.Tag as string;
            });
        };
        AppServices.OpenBrowser = (url, host, port, unlisten, peer) =>
        {
            DispatcherQueue.TryEnqueue(() =>
            {
                SetContent(new BrowserPage(url, host, port, unlisten, peer));
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
                // Through the sidebar row, so the pane and the content agree,
                // then the named conversation reveals onto the mounted page.
                // The page holds the id until its list loads, like the Mac
                // pending reveal, and falls back to the list when the thread
                // is gone.
                var tag = "ws:" + workspaceId + ":Chat";
                if (FindNavItem(tag) is NavigationViewItem row)
                {
                    _nav.SelectedItem = row;
                    if (_frame.Content is ChatPage page)
                    {
                        _ = page.RevealAsync(chatId);
                    }
                }
                else
                {
                    SetContent(new ChatPage(workspaceId, chatId));
                }
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
        AppServices.Update.Changed += () => DispatcherQueue.TryEnqueue(RefreshUpdateBadge);
    }

    private static NavigationViewItem Item(GlobalSection section)
    {
        return new NavigationViewItem
        {
            Content = section.Label(),
            Tag = "global:" + section,
            Icon = new SymbolIcon { Symbol = section.Symbol() },
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
        // Shortest the splash stays, so a hot helper is not a one-frame flash.
        var elapsed = DateTime.UtcNow - started;
        if (elapsed < TimeSpan.FromMilliseconds(560))
        {
            await Task.Delay(TimeSpan.FromMilliseconds(560) - elapsed);
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

    private bool _foldersLoaded;
    private JsonArray _localFolders = new();

    /// <summary>
    /// The folder rows under Workspaces. Runs once after boot mounts content,
    /// then again on every slow sidebar poll until it lands, so a helper that
    /// answers late still fills the sidebar in. A miss keeps the old rows.
    /// </summary>
    private async Task TryLoadFoldersAsync()
    {
        if (_foldersLoaded)
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
        _foldersLoaded = true;
        _localFolders = array;
        DispatcherQueue.TryEnqueue(() =>
        {
            RebuildFolderItems();
            RebuildSidebarLive();
        });
        _ = RemoteWorkspaces.SweepAsync();
    }

    /// <summary>
    /// Local folders and every reachable peer's, each with all sections. The
    /// Add workspace row stays last, under whatever folders exist.
    /// </summary>
    private void RebuildFolderItems()
    {
        var selectedTag = (_nav.SelectedItem as NavigationViewItem)?.Tag as string;
        var expanded = _nav.MenuItems.OfType<NavigationViewItem>()
            .Where(item => item.IsExpanded && item.Tag is string)
            .Select(item => (string)item.Tag).ToHashSet(StringComparer.Ordinal);
        var keep = new List<object>();
        foreach (var item in _nav.MenuItems)
        {
            if (item is NavigationViewItem nav
                && ((nav.Tag as string)?.StartsWith("ws:") == true
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
            _nav.MenuItems.Add(FolderParent(id, name, remote: false, Format.Text(folder, "path")));
        }
        foreach (var folder in RemoteWorkspaces.CachedFolders())
        {
            _nav.MenuItems.Add(FolderParent(folder.Id, folder.DisplayName, remote: true, folder.Path));
        }
        _nav.MenuItems.Add(new NavigationViewItem
        {
            Content = "Add workspace",
            Tag = "workspaces:add",
            Icon = new SymbolIcon { Symbol = Symbol.Add },
        });
        foreach (var item in _nav.MenuItems.OfType<NavigationViewItem>())
        {
            if (item.Tag is string tag && expanded.Contains(tag))
            {
                item.IsExpanded = true;
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

    private static NavigationViewItem FolderParent(string id, string name, bool remote, string path)
    {
        var parent = new NavigationViewItem
        {
            Content = name,
            Tag = "ws:" + id + ":Files",
            Icon = new SymbolIcon { Symbol = remote ? Symbol.Globe : Symbol.Folder },
        };
        if (!string.IsNullOrEmpty(path))
        {
            ToolTipService.SetToolTip(parent, path);
        }
        foreach (var section in Enum.GetValues<WorkspaceSection>())
        {
            parent.MenuItems.Add(new NavigationViewItem
            {
                Content = section.Label(),
                Tag = "ws:" + id + ":" + section,
            });
        }
        return parent;
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
        _toolbarSource = page as IToolbarItems;
        if (_toolbarSource is not null)
        {
            _toolbarSource.ToolbarChanged += OnToolbarChanged;
        }
        _frame.Content = page;
        _inspectorHost.RouteAllowsInspector = page is not AccountPage;
        _inspectorHost.SetInspector((page as IInspectorContent)?.Inspector);
        if (page is IScopeAware aware)
        {
            aware.ApplyScope(_scope);
        }
        RebuildToolbar();
        Motion.PlayArrival(page);
    }

    private IToolbarItems? _toolbarSource;

    private void OnToolbarChanged()
    {
        DispatcherQueue.TryEnqueue(RebuildToolbar);
    }

    /// <summary>
    /// Rebuild the one top bar for what is on screen, like the Mac contextual
    /// toolbar: the device scope picker only on Home, then the page's own
    /// scope chip, then the page's actions before the shared search icon, and
    /// the inspector toggle last, nearest the edge it opens. Insights is
    /// local only, like the desktop Mac, so it gets no picker. Account never
    /// shows an inspector, so it gets no toggle either.
    /// </summary>
    private void RebuildToolbar()
    {
        var content = _frame.Content;
        List<UIElement>? leading = null;
        if (content is HomePage)
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
        bool fits = RootGrid.ActualWidth <= 0 || RootGrid.ActualWidth >= InspectorHost.FitEdge;
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
        if (tag.StartsWith("global:", StringComparison.Ordinal))
        {
            if (Enum.TryParse<GlobalSection>(tag["global:".Length..], out var section))
            {
                Page page = section switch
                {
                    GlobalSection.Home => new HomePage(),
                    GlobalSection.Insights => new InsightsPage(),
                    GlobalSection.Machines => new MachinesPage(),
                    GlobalSection.Ssh => new SshPage(),
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
                SetContent(new SshPage(section), preserveSelection: true);
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
                SetContent(WorkspaceSectionPage(id, section), preserveSelection: true);
            }
        }
    }

    /// <summary>
    /// The page for one folder section. Local folders open the full
    /// workbench. A folder on another machine opens the same dedicated pages,
    /// whose helpers route through the peer, except Notes, which stays local
    /// like the desktop Mac.
    /// </summary>
    private Page WorkspaceSectionPage(string id, WorkspaceSection section)
    {
        if (RemoteWorkspaces.IsRemote(id))
        {
            return section switch
            {
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
            Text = "All folders",
            FontSize = 18,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
        });
        var spacer = new Grid { Width = Theme.SpaceM };
        head.Children.Add(spacer);
        head.Children.Add(Buttons.Primary(
            "Add folder", ActionIcon.Create, async (_, _) =>
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
        var list = new StackPanel { Spacing = Theme.SpaceS };
        if (array is not null)
        {
            foreach (var folder in array)
            {
                var id = Format.Text(folder, "id");
                if (string.IsNullOrEmpty(id))
                {
                    continue;
                }
                list.Children.Add(OverviewFolderRow(
                    Format.Text(folder, "name", Format.Text(folder, "path", id)),
                    Format.Text(folder, "path", id),
                    "ws:" + id + ":Files"));
            }
        }
        foreach (var folder in remote)
        {
            list.Children.Add(OverviewFolderRow(
                folder.DisplayName,
                string.IsNullOrEmpty(folder.Path) ? "On " + folder.MachineLabel : folder.Path,
                "ws:" + folder.Id + ":Files"));
        }
        root.Children.Add(Chrome.Card("Folders", list));
    }

    private UIElement OverviewFolderRow(string title, string subtitle, string tag)
    {
        var open = new Button
        {
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Left,
            Content = new StackPanel
            {
                Spacing = 2,
                Children =
                {
                    new TextBlock
                    {
                        Text = title,
                        FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                        TextWrapping = TextWrapping.Wrap,
                    },
                    new TextBlock
                    {
                        Text = subtitle,
                        Opacity = 0.7,
                        TextWrapping = TextWrapping.Wrap,
                    },
                },
            },
        };
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
                ? await WorkspaceRemoteHistory.LoadCardAsync(this, _id, ShowDiffAsync)
                : await WorkspaceHistory.LoadCardAsync(
                    this,
                    _id,
                    async filePath =>
                    {
                        JsonNode? diff;
                        try
                        {
                            diff = await AppServices.Host.CallAsync(
                                "workspace.diff",
                                new JsonObject { ["id"] = _id, ["path"] = filePath });
                        }
                        catch (Exception ex)
                        {
                            _root.Children.Add(Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important));
                            return;
                        }
                        await WorkspaceDiff.ShowFileDiffAsync(this, "Diff · " + filePath, diff);
                    });
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

    private NavigationViewItem? FindNavItem(string tag)
    {
        foreach (var item in _nav.MenuItems)
        {
            if (item is NavigationViewItem row)
            {
                if ((row.Tag as string) == tag)
                {
                    return row;
                }
                foreach (var child in row.MenuItems)
                {
                    if (child is NavigationViewItem sub && (sub.Tag as string) == tag)
                    {
                        return sub;
                    }
                }
            }
        }
        foreach (var item in _nav.FooterMenuItems)
        {
            if (item is NavigationViewItem row && (row.Tag as string) == tag)
            {
                return row;
            }
        }
        return null;
    }

    private void RefreshUpdateBadge()
    {
        foreach (var item in _nav.FooterMenuItems)
        {
            if (item is NavigationViewItem nav && (nav.Tag as string) == "global:Account")
            {
                nav.InfoBadge = AppServices.Update.IsReady || AppServices.Update.IsAvailable
                    ? new InfoBadge { Value = 1 }
                    : null;
            }
        }
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
            return;
        }
        _sidebarRefreshing = true;
        try
        {
            var (sessions, chats) = await SidebarLive.FetchFastAsync();
            if (slow)
            {
                if (!_foldersLoaded)
                {
                    _ = TryLoadFoldersAsync();
                }
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
            DispatcherQueue.TryEnqueue(() =>
            {
                RebuildSidebarLive();
                RefreshAccountFooter();
            });
        }
        finally
        {
            _sidebarRefreshing = false;
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

        foreach (var item in _nav.MenuItems)
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
            for (var i = parent.MenuItems.Count - 1; i >= 0; i--)
            {
                if (parent.MenuItems[i] is NavigationViewItem child
                    && SidebarLive.IsLiveTag(child.Tag as string))
                {
                    parent.MenuItems.RemoveAt(i);
                }
            }
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
                SidebarLive.ApplyCount(section, SidebarLive.SectionCount(sectionKind, summary));
            }
            if (sessionsByFolder.TryGetValue(folderId, out var sessions) && sessions.Count > 0)
            {
                var at = ChildIndex(parent, "ws:" + folderId + ":Sessions");
                foreach (var session in sessions)
                {
                    parent.MenuItems.Insert(++at, SidebarLive.SessionItem(folderId, session));
                }
            }
            if (chatsByFolder.TryGetValue(folderId, out var chats) && chats.Count > 0)
            {
                var expanded = _liveChatExpanded.Contains(folderId);
                var chatPrefix = SidebarLive.ChatPrefix + folderId + ":";
                if (!expanded
                    && selectedTag is not null
                    && selectedTag.StartsWith(chatPrefix, StringComparison.Ordinal))
                {
                    // The lit row must stay drawn: a selection past the first
                    // five opens the list, like the Mac auto-expansion.
                    var selectedId = selectedTag[chatPrefix.Length..];
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
                var at = ChildIndex(parent, "ws:" + folderId + ":Chat");
                for (var i = 0; i < shown; i++)
                {
                    parent.MenuItems.Insert(++at, SidebarLive.ChatItem(folderId, chats[i]));
                }
                if (chats.Count > SidebarLive.CollapsedChats)
                {
                    var label = expanded
                        ? "Show less"
                        : "Show " + (Math.Min(chats.Count, SidebarLive.InlineChats) - shown) + " more";
                    parent.MenuItems.Insert(++at, SidebarLive.ActionItem(
                        SidebarLive.ChatMorePrefix + folderId, label));
                }
                if (chats.Count > SidebarLive.InlineChats)
                {
                    parent.MenuItems.Insert(++at, SidebarLive.ActionItem(
                        SidebarLive.ChatAllPrefix + folderId, "See all chats"));
                }
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

    /// <summary>Index of a section child, or the end when it is missing.</summary>
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
    /// Who is signed in, above the Account footer row. Signed out, or before
    /// the first answer, the plain Account row stands alone.
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
            _nav.PaneFooter = null;
            return;
        }
        var captured = account;
        _nav.PaneFooter = SidebarLive.AccountFooter(captured, () =>
        {
            if (FindNavItem("global:Account") is NavigationViewItem row)
            {
                _nav.SelectedItem = row;
            }
        });
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

    /// <summary>
    /// Repaint every flat surface from the theme tokens. Runs once at launch
    /// and again whenever the system theme changes, so the window frame never
    /// shows a stale tone. Pages rebuild on navigation and pick the new theme
    /// up there.
    /// </summary>
    private void ApplyChromeColors()
    {
        Theme.WindowTheme = RootGrid.ActualTheme;
        _chromeBackground.Color = Theme.Background;
        _chromeSidebar.Color = Theme.Sidebar;
        _chromeBorder.Color = Theme.Border;
        _inspectorHost.ApplyTheme();
        // The toolbar bakes its brushes at build time, like the pages do at
        // navigation: rebuild it so a theme change repaints it too.
        RebuildToolbar();
        SyncPaneChrome();
        TryTitleBarColors();
    }

    /// <summary>
    /// Keep the pane chrome on the pane state: the titlebar split follows the
    /// pane edge, and group headers hide while the pane collapses to icons,
    /// where they would otherwise render as clipped stubs like "WOR".
    /// </summary>
    private void SyncPaneChrome()
    {
        SyncTitleBarSplit();
        _nav.PaneHeader = _nav.IsPaneOpen ? LogoOpen() : LogoClosed();
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
    private static UIElement LogoOpen()
    {
        return new Border
        {
            Padding = new Thickness(Theme.SpaceM, Theme.SpaceM, Theme.SpaceM, Theme.SpaceM),
            Child = Marks.Wordmark(),
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
        TitlePaneColumn.Width = new GridLength(_nav.IsPaneOpen ? _nav.OpenPaneLength : _nav.CompactPaneLength);
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
