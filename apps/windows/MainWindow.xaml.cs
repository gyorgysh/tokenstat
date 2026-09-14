// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Text.Json.Nodes;
using Microsoft.UI;
using Microsoft.UI.Composition.SystemBackdrops;
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
    private readonly NavigationViewItem _workspacesHeader = new()
    {
        Content = "FOLDERS",
        SelectsOnInvoked = false,
        IsEnabled = false,
    };
    private UIElement? _hostSplash;

    public MainWindow()
    {
        InitializeComponent();
        Title = "tokenstat";
        TryMica();
        TrySize();
        TryIcon();
        RootGrid.Background = Theme.BackgroundBrush;

        _nav.IsSettingsVisible = false;
        _nav.OpenPaneLength = 240;
        _nav.PaneDisplayMode = NavigationViewPaneDisplayMode.Left;
        _nav.IsBackButtonVisible = NavigationViewBackButtonVisible.Collapsed;
        _nav.Background = Theme.SidebarBrush;

        foreach (var section in Sections.Standalone)
        {
            _nav.MenuItems.Add(Item(section));
        }
        _nav.MenuItems.Add(new NavigationViewItemSeparator());
        _nav.MenuItems.Add(new NavigationViewItemHeader { Content = "EVERYWHERE" });
        foreach (var section in Sections.Everywhere)
        {
            _nav.MenuItems.Add(Item(section));
        }
        _nav.MenuItems.Add(new NavigationViewItemSeparator());
        _nav.MenuItems.Add(_workspacesHeader);

        _nav.FooterMenuItems.Add(Item(GlobalSection.Account));
        _nav.FooterMenuItems.Add(Item(GlobalSection.About));

        _nav.Content = _frame;
        _nav.SelectionChanged += NavOnSelectionChanged;
        RootGrid.Children.Add(_nav);

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
        Motion.PlayDoor(splash);
    }

    /// <summary>
    /// Mount a page with the smooth arrival. Every navigation goes through
    /// here so content lands the same way on every screen.
    /// </summary>
    private void SetContent(Page page)
    {
        _frame.Content = page;
        Motion.PlayArrival(page);
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
                    WorkspaceSection.Notes => new NotesPage(id),
                    WorkspaceSection.Workflows => new WorkflowsPage(id),
                    WorkspaceSection.Automations => new AutomationsPage(id),
                    WorkspaceSection.Pulls => new PullsPage(id),
                    WorkspaceSection.Chat => new ChatPage(id),
                    _ => new WorkspacePage(id, section),
                };
                SetContent(page);
            }
        }
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

    private void TryMica()
    {
        try
        {
            SystemBackdrop = new MicaBackdrop { Kind = MicaKind.Base };
        }
        catch
        {
            // Windows 10 keeps the solid background.
        }
    }
}
