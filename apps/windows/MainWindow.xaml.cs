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
    private readonly NavigationViewItem _workspacesHeader = new()
    {
        Content = "WORKSPACES",
        SelectsOnInvoked = false,
        IsEnabled = false,
    };
    private UIElement? _hostSplash;

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
            (_, _) => SyncTitleBarSplit());

        AppServices.OpenTerminal = (workspaceId, sessionId) =>
        {
            DispatcherQueue.TryEnqueue(() =>
            {
                SetContent(new TerminalPage(workspaceId, sessionId));
            });
        };
        AppServices.OpenBrowser = (url, host, port, unlisten) =>
        {
            DispatcherQueue.TryEnqueue(() =>
            {
                SetContent(new BrowserPage(url, host, port, unlisten));
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
                SetContent(section switch
                {
                    WorkspaceSection.Files => new EditorPage(workspaceId),
                    WorkspaceSection.Notes => new NotesPage(workspaceId),
                    WorkspaceSection.Workflows => new WorkflowsPage(workspaceId),
                    WorkspaceSection.Automations => new AutomationsPage(workspaceId),
                    WorkspaceSection.Pulls => new PullsPage(workspaceId),
                    WorkspaceSection.Chat => new ChatPage(workspaceId),
                    _ => new WorkspacePage(workspaceId, section),
                });
            });
        };
        AppServices.OpenConversation = (workspaceId, chatId) =>
        {
            DispatcherQueue.TryEnqueue(() =>
            {
                // Through the sidebar row, so the pane and the content agree.
                // The chat id travels for the reveal; the folder's chat opens
                // either way.
                var tag = "ws:" + workspaceId + ":Chat";
                if (FindNavItem(tag) is NavigationViewItem row)
                {
                    _nav.SelectedItem = row;
                }
                else
                {
                    SetContent(new ChatPage(workspaceId));
                }
            });
        };
        AppServices.OpenInsightsDay = (date) =>
        {
            DispatcherQueue.TryEnqueue(() =>
            {
                // Through the sidebar row, like the search opener. The day
                // travels for the focus; Insights opens either way.
                const string tag = "global:Insights";
                if (FindNavItem(tag) is NavigationViewItem row)
                {
                    _nav.SelectedItem = row;
                }
                else
                {
                    Show(tag);
                }
            });
        };

        if (_nav.MenuItems[0] is NavigationViewItem first)
        {
            _nav.SelectedItem = first;
        }

        // First frame is the brand on paper, before the helper has answered.
        ShowHostSplash(null);
        _ = LoadWorkspacesAsync();
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

    private async Task LoadWorkspacesAsync()
    {
        JsonNode listed;
        while (true)
        {
            try
            {
                listed = await AppServices.Host.CallAsync("workspace.list");
                break;
            }
            catch (Exception ex)
            {
                var info = FriendlyError.From(ex.Message);
                DispatcherQueue.TryEnqueue(() => ShowHostSplash(info));
                // Try again shortens the wait. One loop only: the button
                // wakes this wait rather than starting a second loop.
                _hostWake = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                var wake = _hostWake.Task;
                try
                {
                    await Task.WhenAny(Task.Delay(2000), wake);
                }
                catch
                {
                    return;
                }
            }
        }
        var array = listed as JsonArray
            ?? listed["folders"] as JsonArray
            ?? listed["workspaces"] as JsonArray;

        DispatcherQueue.TryEnqueue(() =>
        {
            if (array is not null)
            {
                var keep = new List<object>();
                foreach (var item in _nav.MenuItems)
                {
                    if (item is NavigationViewItem nav && (nav.Tag as string)?.StartsWith("ws:") == true)
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
                foreach (var folder in array)
                {
                    var id = Format.Text(folder, "id");
                    var name = Format.Text(folder, "name", Format.Text(folder, "path", id));
                    if (string.IsNullOrEmpty(id))
                    {
                        continue;
                    }
                    var parent = new NavigationViewItem
                    {
                        Content = name,
                        Tag = "ws:" + id + ":Files",
                        Icon = new SymbolIcon { Symbol = Symbol.Folder },
                    };
                    foreach (var section in Enum.GetValues<WorkspaceSection>())
                    {
                        parent.MenuItems.Add(new NavigationViewItem
                        {
                            Content = section.Label(),
                            Tag = "ws:" + id + ":" + section,
                        });
                    }
                    _nav.MenuItems.Add(parent);
                }
            }
            if (_frame.Content == _hostSplash
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
        });
    }

    private TaskCompletionSource? _hostWake;
    private string _hostSplashKey = "";

    private void ShowHostSplash(FriendlyErrorInfo? error)
    {
        // Dismissed once the helper answered: a late retry must not drag the
        // splash back over the first page.
        if (_hostSplash is not null && _frame.Content != _hostSplash)
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
        SetContent(new OnboardingPage(() =>
        {
            if (_nav.SelectedItem is NavigationViewItem selected
                && selected.Tag is string tag)
            {
                Show(tag);
            }
        }));
    }

    /// <summary>
    /// Mount a page with the smooth arrival. Every navigation goes through
    /// here so content lands the same way on every screen.
    /// </summary>
    private void SetContent(Page page)
    {
        // Pages sit transparent over the content host, which carries the
        // Background tone. Only when the page did not choose its own surface:
        // the terminal and the screen own a black one, and a local value wins.
        if (page.ReadLocalValue(Control.BackgroundProperty) == DependencyProperty.UnsetValue)
        {
            page.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
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

    /// <summary>
    /// Rebuild the global toolbar for what is on screen: the scope picker only
    /// on Home and Insights, the inspector toggle on every page that may show
    /// one. Account never shows an inspector, so it gets no toggle either.
    /// </summary>
    private void RebuildToolbar()
    {
        var content = _frame.Content;
        List<UIElement>? leading = null;
        if (content is HomePage or InsightsPage)
        {
            leading = new List<UIElement> { ScopePicker() };
        }
        var trailing = new List<UIElement>
        {
            Buttons.ToolbarIcon(ActionIcon.Search, "Search work", (_, _) => OpenSearch()),
        };
        if (content is Page and not AccountPage)
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
        Show("global:Search");
        _nav.SelectedItem = null;
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
        if (args.SelectedItem is not NavigationViewItem item || item.Tag is not string tag)
        {
            return;
        }
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
                SetContent(page);
            }
            return;
        }
        if (tag.StartsWith("ssh:", StringComparison.Ordinal))
        {
            if (Enum.TryParse<SSHSection>(tag["ssh:".Length..], out var section))
            {
                SetContent(new SshPage(section));
            }
            return;
        }
        if (tag == "workspaces:all")
        {
            SetContent(WorkspacesOverviewPage());
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
                Page page = section switch
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
                SetContent(page);
            }
        }
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
                Padding = new Thickness(Theme.SpaceL),
                Content = root,
            },
        };
        page.Loaded += async (_, _) =>
        {
            root.Children.Clear();
            root.Children.Add(new TextBlock
            {
                Text = "All folders",
                FontSize = 18,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            });
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
            if (array is null || array.Count == 0)
            {
                root.Children.Add(EmptyState.View(
                    "No folders yet",
                    "Add a project folder and it will appear here.",
                    EmptyArtKind.WorkspaceAccess));
                return;
            }
            var list = new StackPanel { Spacing = Theme.SpaceS };
            foreach (var folder in array)
            {
                var id = Format.Text(folder, "id");
                if (string.IsNullOrEmpty(id))
                {
                    continue;
                }
                var captured = "ws:" + id + ":Files";
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
                                Text = Format.Text(folder, "name", Format.Text(folder, "path", id)),
                                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                                TextWrapping = TextWrapping.Wrap,
                            },
                            new TextBlock
                            {
                                Text = Format.Text(folder, "path", id),
                                Opacity = 0.7,
                                TextWrapping = TextWrapping.Wrap,
                            },
                        },
                    },
                };
                open.Click += (_, _) =>
                {
                    if (FindNavItem(captured) is NavigationViewItem row)
                    {
                        _nav.SelectedItem = row;
                    }
                    else
                    {
                        Show(captured);
                    }
                };
                list.Children.Add(open);
            }
            root.Children.Add(Chrome.Card("Folders", list));
        };
        return page;
    }

    /// <summary>
    /// One folder's commit history, through the shared history card. The diff
    /// opener matches the Changes screen, so a file reads the same from both.
    /// </summary>
    private static Page WorkspaceHistoryPage(string id)
    {
        var root = new StackPanel { Spacing = Theme.SpaceL };
        var page = new Page
        {
            Content = new ScrollViewer
            {
                Padding = new Thickness(Theme.SpaceL),
                Content = root,
            },
        };
        page.Loaded += async (_, _) =>
        {
            root.Children.Clear();
            root.Children.Add(new TextBlock
            {
                Text = WorkspaceSection.History.Label(),
                FontSize = 18,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            });
            var card = await WorkspaceHistory.LoadCardAsync(
                page,
                id,
                async filePath =>
                {
                    JsonNode? diff;
                    try
                    {
                        diff = await AppServices.Host.CallAsync(
                            "workspace.diff",
                            new JsonObject { ["id"] = id, ["path"] = filePath });
                    }
                    catch (Exception ex)
                    {
                        root.Children.Add(Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important));
                        return;
                    }
                    await WorkspaceDiff.ShowFileDiffAsync(page, "Diff · " + filePath, diff);
                });
            if (card is not null)
            {
                root.Children.Add(card);
            }
        };
        return page;
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
        _chromeBackground.Color = Theme.Background;
        _chromeSidebar.Color = Theme.Sidebar;
        _chromeBorder.Color = Theme.Border;
        _inspectorHost.ApplyTheme();
        // The toolbar bakes its brushes at build time, like the pages do at
        // navigation: rebuild it so a theme change repaints it too.
        RebuildToolbar();
        SyncTitleBarSplit();
        TryTitleBarColors();
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
