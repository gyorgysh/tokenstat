// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Diagnostics;
using System.Text.Json.Nodes;
using Microsoft.Web.WebView2.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Tokenstat.Design;
using Windows.System;

namespace Tokenstat.Pages;

/// <summary>
/// Tabbed in-app browser over the proxy.* lifecycle. Each tab owns one
/// loopback page: opening through proxy.listen gives a tab whose close calls
/// proxy.unlisten, and a tab opened on a plain port closes without a call.
/// Matches the Mac browser: an address bar for committed navigations only, an
/// address bar for local previews and external sites, and an empty state
/// until an address is entered.
/// </summary>
internal sealed class BrowserPage : Page, IInspectorContent, IToolbarItems
{
    private readonly string? _peer;
    private readonly string? _workspaceId;
    private readonly bool _sharedTabs;
    private readonly TabView _tabs = new()
    {
        IsAddTabButtonVisible = true,
        TabWidthMode = TabViewWidthMode.SizeToContent,
    };
    private readonly StackPanel _inspector = new()
    {
        Spacing = Theme.SpaceM,
        Padding = new Thickness(Theme.SpaceM),
    };

    public BrowserPage(string url, string host, int port, bool unlisten, string? peer = null, TabView? workspaceTabs = null, string? workspaceId = null)
    {
        _peer = peer;
        _workspaceId = workspaceId;
        _sharedTabs = workspaceTabs is not null;
        if (workspaceTabs is not null) _tabs = workspaceTabs;
        if (!_sharedTabs) _tabs.AddTabButtonClick += (_, _) => AddTab("", "127.0.0.1", 0, false, peer);
        _tabs.TabCloseRequested += async (_, args) =>
        {
            if (args.Item is TabViewItem item && item.Tag is BrowserTab tab)
            {
                await CloseTabAsync(tab);
            }
        };
        _tabs.SelectionChanged += (_, _) => RenderInspector();
        if (!_sharedTabs) Content = _tabs;
        RenderInspector();
        Loaded += (_, _) =>
        {
            if (!_sharedTabs && _tabs.TabItems.Count == 0)
            {
                AddTab(url, host, port, unlisten, peer);
            }
        };
        // Keep tabs alive while switching workspace sections. Release native
        // WebViews and listeners when the window closes, or a tab is closed.
        void CloseAll()
        {
            foreach (var entry in _tabs.TabItems)
            {
                if (entry is TabViewItem item && item.Tag is BrowserTab tab)
                {
                    _ = tab.CloseAsync();
                }
            }
        }
        if (App.CurrentWindow is { } window) window.Closed += (_, _) => CloseAll();
    }

    /// <summary>
    /// The inspector column content: the open tabs and the current address.
    /// Tab switches and navigations repaint it, so the column stays live
    /// without the shell asking again.
    /// </summary>
    public UIElement? Inspector => _inspector;

    public event Action? ToolbarChanged { add { } remove { } }

    /// <summary>
    /// The tab strip names its own pages; the scope says this is the browser.
    /// </summary>
    public UIElement? ToolbarScope => Chrome.ScopeChip("Browser", Symbol.Globe);

    public IList<UIElement> ToolbarActions()
    {
        return new List<UIElement>
        {
            Buttons.ToolbarIcon(
                ActionIcon.Refresh,
                "Reload the current page",
                (_, _) => CurrentTab()?.Reload()),
            Buttons.ToolbarIcon(
                ActionIcon.Create,
                "Open a new tab",
                (_, _) => AddTab("", "127.0.0.1", 0, false, _peer)),
        };
    }

    private void RenderInspector()
    {
        _inspector.Children.Clear();
        _inspector.Children.Add(new TextBlock
        {
            Text = $"Open tabs ({_tabs.TabItems.OfType<TabViewItem>().Count(Owns)})",
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        foreach (var entry in _tabs.TabItems)
        {
            if (entry is not TabViewItem item || item.Tag is not BrowserTab tab)
            {
                continue;
            }
            var captured = item;
            var pick = new Button
            {
                Content = new TextBlock
                {
                    Text = tab.Title,
                    FontSize = 12,
                    TextWrapping = TextWrapping.Wrap,
                },
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Left,
            };
            pick.Click += (_, _) => _tabs.SelectedItem = captured;
            _inspector.Children.Add(pick);
        }
        if (CurrentTab() is BrowserTab current && !string.IsNullOrWhiteSpace(current.Url))
        {
            _inspector.Children.Add(Chrome.InspectorField("Address", current.Url));
        }
    }

    internal bool ShowLastTab()
    {
        var last = _tabs.TabItems.OfType<TabViewItem>().LastOrDefault(item => item.Tag is BrowserTab);
        if (last is null) return false;
        _tabs.SelectedItem = last;
        return true;
    }

    internal bool Owns(TabViewItem item) => item.Tag is BrowserTab;

    private BrowserTab? CurrentTab() =>
        (_tabs.SelectedItem as TabViewItem)?.Tag as BrowserTab;

    internal void AddTab(string url, string host, int port, bool unlisten, string? peer = null)
    {
        var tab = new BrowserTab(this, url, host, port, unlisten, peer, CloseRequested, _workspaceId);
        var item = new TabViewItem
        {
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            VerticalContentAlignment = VerticalAlignment.Stretch,
            Header = tab.Title,
            IconSource = new FontIconSource { Glyph = "\uE774" },
            Content = tab.View,
            IsClosable = true,
        };
        tab.HeaderChanged = _ =>
        {
            item.Header = tab.Title;
            RenderInspector();
        };
        ContextMenus.AddAsync(ContextMenus.Menu(item), "Close", async () => await CloseTabAsync(tab));
        item.Tag = tab;
        _tabs.TabItems.Add(item);
        _tabs.SelectedItem = item;
        RenderInspector();
    }

    private async void CloseRequested(BrowserTab tab)
    {
        await CloseTabAsync(tab);
    }

    private async Task CloseTabAsync(BrowserTab tab)
    {
        TabViewItem? item = null;
        foreach (var entry in _tabs.TabItems)
        {
            if (entry is TabViewItem candidate && candidate.Tag == tab)
            {
                item = candidate;
                break;
            }
        }
        if (item is not null)
        {
            _tabs.TabItems.Remove(item);
        }
        await tab.CloseAsync();
        if (!_sharedTabs && _tabs.TabItems.Count == 0)
        {
            AddTab("", "127.0.0.1", 0, false, _peer);
        }
        RenderInspector();
    }

    /// <summary>
    /// One open page. The address field holds what the user is typing, never
    /// what the page is: a half-typed URL must not start loading, or the
    /// first keystroke throws a DNS error.
    /// </summary>
    private sealed class BrowserTab
    {
        private readonly Grid _view = new();
        private readonly WebView2 _web = new();
        private readonly TextBox _address = new()
        {
            PlaceholderText = "Enter a URL, for example localhost:8000",
            FontFamily = Fonts.Mono,
            FontSize = 12,
            MinWidth = 200,
        };
        private readonly StackPanel _status = new() { Spacing = Theme.SpaceS };
        private readonly ProgressRing _spinner = new()
        {
            Width = 16,
            Height = 16,
            Visibility = Visibility.Collapsed,
        };
        private readonly Button _back;
        private readonly Button _forward;
        private readonly Button _reload;
        private readonly Grid _empty;
        private readonly Page _owner;
        private readonly string? _workspaceId;
        private readonly Action<BrowserTab> _closeTab;
        private readonly MenuFlyout _recentMenu = new();
        private int _recentGeneration;

        private string _loadedUrl;
        private string _host;
        private int _port;
        private readonly string _peer;
        private readonly bool _unlisten;
        private readonly string _initialUrl;
        private readonly BrowserRouteState _routes = new();
        private readonly OperationEpoch _navigationEpoch = new();
        private readonly OperationEpoch.Operation _initialOperation;
        private readonly SemaphoreSlim _navigationGate = new(1, 1);
        private long _documentGeneration;
        private long _startedNavigationEpoch;
        private ulong _navigationId;
        private bool _resourceFilterInstalled;
        private bool _closed;
        private bool _started;

        public Action<BrowserTab>? HeaderChanged { get; set; }

        public UIElement View => _view;

        public string Url => DisplayUrl(_loadedUrl);

        private string DisplayUrl(string actual)
        {
            if (!Uri.TryCreate(actual, UriKind.Absolute, out var uri)) return actual;
            if (_unlisten && Uri.TryCreate(_initialUrl, UriKind.Absolute, out var initial)
                && uri.Host == initial.Host && uri.Port == initial.Port)
                return new UriBuilder(uri) { Host = _host, Port = _port }.Uri.AbsoluteUri;
            return _routes.Display(actual);
        }

        public void Reload()
        {
            if (_closed) return;
            if (_web.CoreWebView2 is null)
            {
                _ = CommitAsync(DisplayUrl(_loadedUrl));
                return;
            }
            try
            {
                _navigationEpoch.Advance();
                _web.Reload();
            }
            catch (Exception ex)
            {
                Banner(ex.Message);
            }
        }

        public string Title
        {
            get
            {
                if (string.IsNullOrWhiteSpace(_loadedUrl))
                {
                    return "New tab";
                }
                try
                {
                    var uri = new Uri(Url);
                    var port = uri.IsDefaultPort ? "" : ":" + uri.Port;
                    return uri.Host + port;
                }
                catch
                {
                    return _loadedUrl;
                }
            }
        }

        public BrowserTab(Page owner, string url, string host, int port, bool unlisten, string? peer, Action<BrowserTab> close, string? workspaceId)
        {
            _owner = owner;
            _workspaceId = workspaceId;
            _closeTab = close;
            _loadedUrl = url ?? "";
            _host = host ?? "127.0.0.1";
            _port = port;
            _peer = peer ?? "";
            _unlisten = unlisten;
            _initialUrl = _loadedUrl;
            _initialOperation = BrowserProjectMemory.AccountEpoch.Capture(() => _closed || _navigationEpoch.Revision != 0);
            _documentGeneration = _initialOperation.Revision;
            AppServices.AccountChanged += OnAccountChanged;
            _address.Text = _loadedUrl;

            _back = ActionIconGlyph.Button("Back", ActionIcon.Back, (_, _) =>
            {
                try
                {
                    if (_web.CanGoBack)
                    {
                        _navigationEpoch.Advance();
                        _web.GoBack();
                    }
                }
                catch (Exception ex)
                {
                    Banner(ex.Message);
                }
            });
            _forward = ActionIconGlyph.Button("Forward", ActionIcon.Next, (_, _) =>
            {
                try
                {
                    if (_web.CanGoForward)
                    {
                        _navigationEpoch.Advance();
                        _web.GoForward();
                    }
                }
                catch (Exception ex)
                {
                    Banner(ex.Message);
                }
            });
            _reload = ActionIconGlyph.Button("Reload", ActionIcon.Refresh, (_, _) => Reload());

            var go = ActionIconGlyph.Button("Go", ActionIcon.Next, async (_, _) => await CommitAsync(_address.Text));
            var recent = ActionIconGlyph.Button("Browser actions and recent previews", ActionIcon.More, (_, _) => { });
            recent.Flyout = _recentMenu;
            _recentMenu.Opening += async (_, _) => await RefreshRecentAsync(prefill: false);
            _address.KeyDown += async (_, e) =>
            {
                if (e.Key == VirtualKey.Enter)
                {
                    e.Handled = true;
                    await CommitAsync(_address.Text);
                }
            };

            var chrome = new Grid
            {
                ColumnSpacing = Theme.SpaceS,
                Padding = new Thickness(Theme.SpaceS),
                VerticalAlignment = VerticalAlignment.Center,
            };
            foreach (var control in new FrameworkElement[] { _back, _forward, _reload, _spinner, _address, go, recent })
            {
                chrome.ColumnDefinitions.Add(new ColumnDefinition { Width = control == _address ? new GridLength(1, GridUnitType.Star) : GridLength.Auto });
                Grid.SetColumn(control, chrome.ColumnDefinitions.Count - 1);
                if (control is Button button)
                {
                    if (button.Content is StackPanel label && label.Children.LastOrDefault() is TextBlock text)
                    {
                        ToolTipService.SetToolTip(button, text.Text);
                        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, text.Text);
                        label.Children.Remove(text);
                    }
                }
            }
            chrome.Children.Add(_back);
            chrome.Children.Add(_forward);
            chrome.Children.Add(_reload);
            chrome.Children.Add(_spinner);
            chrome.Children.Add(_address);
            chrome.Children.Add(go);
            chrome.Children.Add(recent);

            _empty = new Grid
            {
                HorizontalAlignment = HorizontalAlignment.Stretch,
                VerticalAlignment = VerticalAlignment.Stretch,
                Visibility = string.IsNullOrWhiteSpace(_loadedUrl) ? Visibility.Visible : Visibility.Collapsed,
            };
            _empty.Children.Add(Chrome.Empty(
                "Open a project preview",
                "Enter a local development server or any URL above.",
                ActionIcon.Browser));

            _view.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            _view.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            _view.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            Grid.SetRow(_status, 1);
            Grid.SetRow(_web, 2);
            Grid.SetRow(_empty, 2);
            _view.Children.Add(chrome);
            _view.Children.Add(_status);
            _view.Children.Add(_web);
            _view.Children.Add(_empty);

            _web.NavigationStarting += (_, args) =>
            {
                if (args.IsUserInitiated && !args.IsRedirected) _navigationEpoch.Advance();
                _startedNavigationEpoch = _navigationEpoch.Revision;
                _navigationId = args.NavigationId;
                SetLoading(true);
            };
            _web.NavigationCompleted += (_, args) =>
            {
                if (_closed || _documentGeneration != BrowserProjectMemory.AccountEpoch.Revision
                    || _startedNavigationEpoch != _navigationEpoch.Revision || args.NavigationId != _navigationId) return;
                SetLoading(false);
                RefreshHistory();
                if (!args.IsSuccess)
                {
                    Banner("The page stopped responding. Reload to try again.");
                    return;
                }
                try
                {
                    var shown = _web.Source?.AbsoluteUri ?? "";
                    if (!string.IsNullOrEmpty(shown))
                    {
                        _loadedUrl = shown;
                        _address.Text = DisplayUrl(shown);
                        HeaderChanged?.Invoke(this);
                    }
                }
                catch
                {
                }
            };
            _view.Loaded += async (_, _) => await StartAsync();
        }

        private void SetLoading(bool loading)
        {
            _spinner.Visibility = loading ? Visibility.Visible : Visibility.Collapsed;
            try
            {
                _back.IsEnabled = !loading && _web.CanGoBack;
                _forward.IsEnabled = !loading && _web.CanGoForward;
            }
            catch
            {
            }
        }

        private void RefreshHistory()
        {
            try
            {
                _back.IsEnabled = _web.CanGoBack;
                _forward.IsEnabled = _web.CanGoForward;
            }
            catch
            {
            }
        }

        private async Task StartAsync()
        {
            if (_started)
            {
                return;
            }
            _started = true;
            await RefreshRecentAsync(prefill: true);
            if (!_initialOperation.IsCurrent) return;
            if (string.IsNullOrWhiteSpace(_loadedUrl))
            {
                return;
            }
            if (!_unlisten && _peer.Length > 0 && Uri.TryCreate(_loadedUrl, UriKind.Absolute, out var target) && IsLoopback(target))
                await CommitAsync(_loadedUrl);
            else await NavigateAsync(_loadedUrl, _initialOperation);
        }

        private async Task RefreshRecentAsync(bool prefill)
        {
            if (_closed) return;
            var generation = ++_recentGeneration;
            _recentMenu.Items.Clear();
            ContextMenus.Add(_recentMenu, "Open in default browser", () =>
            {
                try { if (Uri.TryCreate(_loadedUrl, UriKind.Absolute, out var uri)) Process.Start(new ProcessStartInfo { FileName = uri.AbsoluteUri, UseShellExecute = true }); }
                catch (Exception ex) { Banner(ex.Message); }
            }).IsEnabled = _loadedUrl.Length > 0;
            ContextMenus.Add(_recentMenu, "Close tab", () => _closeTab(this));
            _recentMenu.Items.Add(new MenuFlyoutSeparator());
            var memory = _workspaceId is null ? null : await BrowserProjectMemory.ForAsync(_workspaceId);
            if (_closed || generation != _recentGeneration) return;
            var targets = memory?.Targets ?? [];
            if (prefill && _loadedUrl.Length == 0 && _address.Text.Length == 0 && targets.Count > 0)
                _address.Text = targets[0];
            foreach (var target in targets)
                ContextMenus.Add(_recentMenu, target, () => { _address.Text = target; _address.Focus(FocusState.Programmatic); });
            if (targets.Count == 0) _recentMenu.Items.Add(new MenuFlyoutItem { Text = "No recent previews", IsEnabled = false });
        }

        /// <summary>
        /// Commit a typed address. Local dev servers are plain HTTP; anything
        /// else defaults to HTTPS so a mistyped or remote site is never sent
        /// in the clear. Remote loopback addresses keep their original port
        /// in the address bar while the WebView uses a local bridge.
        /// </summary>
        private async Task CommitAsync(string raw)
        {
            // Capture before the semaphore: a queued click belongs to its original account.
            _navigationEpoch.Advance();
            var navigation = _navigationEpoch.Revision;
            var operation = BrowserProjectMemory.AccountEpoch.Capture(() => _closed || navigation != _navigationEpoch.Revision);
            await _navigationGate.WaitAsync();
            try
            {
                if (!operation.IsCurrent) return;
                var memory = _workspaceId is null ? null : await BrowserProjectMemory.ForAsync(_workspaceId);
                if (!operation.IsCurrent) return;
                await CommitCoreAsync(raw, operation, memory);
            }
            finally { _navigationGate.Release(); }
        }

        private async Task CommitCoreAsync(string raw, OperationEpoch.Operation operation, BrowserProjectMemory? memory)
        {
            var input = (raw ?? "").Trim();
            var canonical = BrowserHistory.CanonicalTarget(input);
            if (canonical is null && input.Length > 0 && input.All(char.IsDigit))
            {
                Banner("Enter a port between 1 and 65535.");
                return;
            }
            var candidate = canonical ?? input;
            if (candidate.Length == 0)
            {
                return;
            }
            if (!candidate.Contains("://", StringComparison.Ordinal))
            {
                Uri? probe = null;
                try
                {
                    probe = new Uri("http://" + candidate);
                }
                catch
                {
                }
                candidate = probe is not null && !IsLoopback(probe)
                    ? "https://" + candidate
                    : "http://" + candidate;
            }
            Uri? url;
            try
            {
                url = new Uri(candidate);
            }
            catch
            {
                return;
            }
            var scheme = url.Scheme.ToLowerInvariant();
            if (scheme != "http" && scheme != "https")
            {
                try
                {
                    Process.Start(new ProcessStartInfo { FileName = url.AbsoluteUri, UseShellExecute = true });
                }
                catch
                {
                }
                return;
            }
            if (!string.IsNullOrEmpty(_peer) && IsLoopback(url))
            {
                try
                {
                    var lease = await SwitchBridgeAsync(url.Host, url.Port, operation);
                    if (lease is null || !operation.IsCurrent) return;
                    memory?.Remember(url.AbsoluteUri);
                    await NavigateAsync(BrowserRouteState.Through(lease, url), operation);
                }
                catch (Exception ex) { if (operation.IsCurrent) Banner(ex.Message); }
                return;
            }
            await RetireBridgeAsync();
            if (!operation.IsCurrent) return;
            memory?.Remember(url.AbsoluteUri);
            await NavigateAsync(url.AbsoluteUri, operation);
        }

        private async Task<BrowserRouteState.Lease?> SwitchBridgeAsync(string host, int port, OperationEpoch.Operation operation)
        {
            if (!operation.IsCurrent) return null;
            if (_routes.Active is { } existing && existing.Generation == operation.Revision
                && existing.Host.Equals(host, StringComparison.OrdinalIgnoreCase) && existing.Port == port) return existing;
            // Retire before listen, so even sixteen open tabs can each change their target.
            await RetireBridgeAsync();
            var local = await operation.AcquireAsync(
                () => BrowserBridges.AcquireAsync(_peer, host, port, operation.Revision),
                () => BrowserBridges.ReleaseAsync(_peer, host, port, operation.Revision));
            if (local is null) return null;
            var lease = new BrowserRouteState.Lease(host, port, operation.Revision, local);
            _routes.Activate(lease);
            return lease;
        }

        private async Task RetireBridgeAsync()
        {
            if (_routes.Retire() is { } lease)
                await BrowserBridges.ReleaseAsync(_peer, lease.Host, lease.Port, lease.Generation);
        }

        private async Task NavigateAsync(string url, OperationEpoch.Operation operation)
        {
            if (!operation.IsCurrent || string.IsNullOrWhiteSpace(url)) return;
            _documentGeneration = operation.Revision;
            _loadedUrl = url;
            _address.Text = DisplayUrl(url);
            _status.Children.Clear();
            _empty.Visibility = Visibility.Collapsed;
            HeaderChanged?.Invoke(this);
            SetLoading(true);
            try
            {
                await _web.EnsureCoreWebView2Async();
                if (!operation.IsCurrent || _loadedUrl != url) return;
                InstallResourceFilter();
                _web.Source = new Uri(url);
            }
            catch (Exception ex)
            {
                if (!operation.IsCurrent || _loadedUrl != url) return;
                SetLoading(false);
                if (_web.CoreWebView2 is null)
                {
                    BrowserUnavailable(ex);
                }
                else
                {
                    Banner(FriendlyError.Display(ex.Message));
                }
            }
        }

        private void InstallResourceFilter()
        {
            if (_resourceFilterInstalled || _peer.Length == 0 || _web.CoreWebView2 is not { } core) return;
            // Include frames and workers. Shared worker requests are raised on every
            // WebView in an environment, so they use the pool's live listener set.
            core.AddWebResourceRequestedFilter("*", CoreWebView2WebResourceContext.All, CoreWebView2WebResourceRequestSourceKinds.All);
            core.FrameNavigationStarting += (_, args) =>
            {
                if (_closed || _documentGeneration != BrowserProjectMemory.AccountEpoch.Revision
                    || Uri.TryCreate(args.Uri, UriKind.Absolute, out var uri) && !_routes.AllowsFrame(uri, _documentGeneration))
                    args.Cancel = true;
            };
            core.WebResourceRequested += async (_, args) =>
            {
                if (!Uri.TryCreate(args.Request.Uri, UriKind.Absolute, out var uri)) return;
                var navigation = _navigationEpoch.Revision;
                var operation = BrowserProjectMemory.AccountEpoch.Capture(() => _closed || navigation != _navigationEpoch.Revision);
                var destination = args.Request.Headers.Contains("Sec-Fetch-Dest") ? args.Request.Headers.GetHeader("Sec-Fetch-Dest") : null;
                var topLevel = BrowserRouteState.IsTopLevelDocument(args.ResourceContext == CoreWebView2WebResourceContext.Document, destination);
                var worker = (args.RequestedSourceKind & (CoreWebView2WebResourceRequestSourceKinds.SharedWorker | CoreWebView2WebResourceRequestSourceKinds.ServiceWorker)) != 0;
                var action = !operation.IsCurrent ? BrowserRouteState.RequestAction.Block
                    : worker ? BrowserRouteState.WorkerRequest(uri, BrowserBridges.IsCurrentListener(uri))
                    : _documentGeneration == operation.Revision ? _routes.Request(uri, args.Request.Method, topLevel, operation.Revision)
                    : BrowserRouteState.RequestAction.Block;
                if (action == BrowserRouteState.RequestAction.Pass) return;
                // Refuse before rewriting too, so a failed WebView API call cannot
                // send the original localhost request to this computer.
                args.Response = core.Environment.CreateWebResourceResponse(null, 403, "Remote preview address unavailable", "Content-Length: 0\r\n");
                if (action == BrowserRouteState.RequestAction.Rewrite && _routes.Active is { } active)
                {
                    // Preserve the request method and body, including forms and subresources.
                    try { args.Request.Uri = BrowserRouteState.Through(active, uri); args.Response = null; }
                    catch (Exception ex) { if (operation.IsCurrent) Banner(FriendlyError.Display(ex.Message)); }
                    return;
                }
                // Default to refusal before awaiting anything. An unmapped remote localhost
                // request must never fall through to a service on this Windows computer.
                if (action != BrowserRouteState.RequestAction.Reopen) return;
                var deferral = args.GetDeferral();
                await _navigationGate.WaitAsync();
                try
                {
                    if (!operation.IsCurrent || _documentGeneration != operation.Revision) return;
                    var historical = _routes.Historical(uri, operation.Revision);
                    if (historical is null) return;
                    var lease = await SwitchBridgeAsync(historical.Host, historical.Port, operation);
                    if (lease is null || !operation.IsCurrent) return;
                    // A document redirect gives the page its new proxy origin, so its
                    // relative requests follow the live listener after Back/Forward.
                    args.Response = core.Environment.CreateWebResourceResponse(null, 302, "Preview listener refreshed",
                        "Location: " + BrowserRouteState.Through(lease, uri) + "\r\nContent-Length: 0\r\n");
                }
                catch (Exception ex) { if (operation.IsCurrent) Banner(FriendlyError.Display(ex.Message)); }
                finally { _navigationGate.Release(); deferral.Complete(); }
            };
            // A failed or unsupported runtime setup must keep Retry fail closed.
            _resourceFilterInstalled = true;
        }

        private void OnAccountChanged()
        {
            var changedGeneration = BrowserProjectMemory.AccountEpoch.Revision;
            _view.DispatcherQueue.TryEnqueue(async () =>
            {
                if (_closed) return;
                if (_documentGeneration < changedGeneration)
                {
                    // Stop before waiting for an in-flight Open to release the navigation gate.
                    try { _web.CoreWebView2?.Stop(); _web.CoreWebView2?.Navigate("about:blank"); } catch { }
                    _loadedUrl = "";
                    _address.Text = "";
                    _empty.Visibility = Visibility.Visible;
                    SetLoading(false);
                    HeaderChanged?.Invoke(this);
                }
                await _navigationGate.WaitAsync();
                try
                {
                    if (_routes.Active is { } active && active.Generation < changedGeneration) await RetireBridgeAsync();
                    _routes.ForgetBefore(changedGeneration);
                }
                catch { /* Account invalidation also retires listeners in the shared pool. */ }
                finally { _navigationGate.Release(); }
            });
        }

        private void BrowserUnavailable(Exception error)
        {
            _status.Children.Clear();
            _status.Children.Add(Chrome.Banner(
                "The built-in browser could not start. Install or repair Microsoft Edge WebView2 Runtime, then retry.",
                Theme.Warning, Symbol.Important));
            _status.Children.Add(new TextBlock
            {
                Text = FriendlyError.Display(error.Message),
                TextWrapping = TextWrapping.Wrap,
                FontSize = 12,
            });
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
            void OpenExternal(string address)
            {
                try { Process.Start(new ProcessStartInfo { FileName = address, UseShellExecute = true }); }
                catch (Exception ex) { Banner(FriendlyError.Display(ex.Message)); }
            }
            actions.Children.Add(ActionIconGlyph.Button("Get WebView2", ActionIcon.Download,
                (_, _) => OpenExternal("https://developer.microsoft.com/microsoft-edge/webview2/#download-section")));
            actions.Children.Add(ActionIconGlyph.Button("Retry", ActionIcon.Refresh,
                async (_, _) => await CommitAsync(DisplayUrl(_loadedUrl))));
            actions.Children.Add(ActionIconGlyph.Button("Open in browser", ActionIcon.External,
                (_, _) => OpenExternal(_loadedUrl)));
            _status.Children.Add(actions);
        }

        /// <summary>
        /// Whether an address names a loopback development server.
        /// </summary>
        private static bool IsLoopback(Uri url)
        {
            return BrowserRouteState.IsLoopback(url);
        }

        public async Task CloseAsync()
        {
            if (_closed)
            {
                return;
            }
            _closed = true;
            AppServices.AccountChanged -= OnAccountChanged;
            try
            {
                _web.CoreWebView2?.Stop();
                _web.Close();
            }
            catch
            {
            }
            await _navigationGate.WaitAsync();
            try { await RetireBridgeAsync(); _routes.Reset(); }
            catch { /* Closing a tab must not throw. */ }
            finally { _navigationGate.Release(); }
            if (_unlisten && _initialOperation.Revision == BrowserProjectMemory.AccountEpoch.Revision)
            {
                try
                {
                    // The host keys bridges by peer, host and port, so the
                    // peer travels back or the bridge leaks. Local tabs never
                    // unlisten: their ports were opened directly.
                    var parameters = new JsonObject
                    {
                        ["host"] = _host,
                        ["port"] = _port,
                    };
                    if (!string.IsNullOrEmpty(_peer))
                    {
                        parameters["peer"] = _peer;
                    }
                    await AppServices.Host.CallAsync("proxy.unlisten", parameters);
                }
                catch
                {
                    // Leaving the page must not throw.
                }
            }
        }

        private void Banner(string text)
        {
            _status.Children.Clear();
            _status.Children.Add(Chrome.Banner(text, Theme.Danger, Symbol.Important));
        }
    }
}
