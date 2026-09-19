// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Diagnostics;
using System.Text.Json.Nodes;
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
/// Matches the Mac browser: an address bar for committed navigations only, a
/// confirm before a remote site loads inside the app, and an empty state
/// until an address is entered.
/// </summary>
internal sealed class BrowserPage : Page, IInspectorContent, IToolbarItems
{
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

    public BrowserPage(string url, string host, int port, bool unlisten, string? peer = null)
    {
        _tabs.AddTabButtonClick += (_, _) => AddTab("", "127.0.0.1", 0, false);
        _tabs.TabCloseRequested += async (_, args) =>
        {
            if (args.Item is TabViewItem item && item.Tag is BrowserTab tab)
            {
                await CloseTabAsync(tab);
            }
        };
        _tabs.SelectionChanged += (_, _) => RenderInspector();
        Content = _tabs;
        RenderInspector();
        Loaded += (_, _) =>
        {
            if (_tabs.TabItems.Count == 0)
            {
                AddTab(url, host, port, unlisten, peer);
            }
        };
        // One close for every tab when the page itself goes away. Per-tab
        // Unloaded would also fire on a tab switch, which must not stop a
        // listener the tab still needs.
        Unloaded += (_, _) =>
        {
            foreach (var entry in _tabs.TabItems)
            {
                if (entry is TabViewItem item && item.Tag is BrowserTab tab)
                {
                    _ = tab.CloseAsync();
                }
            }
        };
    }

    /// <summary>
    /// The inspector column content: the open tabs and the current address.
    /// Tab switches and navigations repaint it, so the column stays live
    /// without the shell asking again.
    /// </summary>
    public UIElement? Inspector => _inspector;

    public event Action? ToolbarChanged;

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
                (_, _) => AddTab("", "127.0.0.1", 0, false)),
        };
    }

    private void RenderInspector()
    {
        _inspector.Children.Clear();
        _inspector.Children.Add(new TextBlock
        {
            Text = $"Open tabs ({_tabs.TabItems.Count})",
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
            _inspector.Children.Add(Chrome.Stat("Address", current.Url));
        }
    }

    private BrowserTab? CurrentTab() =>
        (_tabs.SelectedItem as TabViewItem)?.Tag as BrowserTab;

    private void AddTab(string url, string host, int port, bool unlisten, string? peer = null)
    {
        var tab = new BrowserTab(this, url, host, port, unlisten, peer, CloseRequested);
        var item = new TabViewItem
        {
            Header = tab.Title,
            Content = tab.View,
            IsClosable = true,
        };
        tab.HeaderChanged = _ =>
        {
            item.Header = tab.Title;
            RenderInspector();
        };
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
        if (_tabs.TabItems.Count == 0)
        {
            AddTab("", "127.0.0.1", 0, false);
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

        private string _loadedUrl;
        private string _host;
        private int _port;
        private readonly string _peer;
        private readonly bool _unlisten;
        private bool _closed;
        private bool _started;

        public Action<BrowserTab>? HeaderChanged { get; set; }

        public UIElement View => _view;

        public string Url => _loadedUrl;

        public void Reload()
        {
            try
            {
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
                    var uri = new Uri(_loadedUrl);
                    var port = uri.IsDefaultPort ? "" : ":" + uri.Port;
                    return uri.Host + port;
                }
                catch
                {
                    return _loadedUrl;
                }
            }
        }

        public BrowserTab(Page owner, string url, string host, int port, bool unlisten, string? peer, Action<BrowserTab> close)
        {
            _owner = owner;
            _loadedUrl = url ?? "";
            _host = host ?? "127.0.0.1";
            _port = port;
            _peer = peer ?? "";
            _unlisten = unlisten;
            _address.Text = _loadedUrl;

            _back = ActionIconGlyph.Button("Back", ActionIcon.Back, (_, _) =>
            {
                try
                {
                    if (_web.CanGoBack)
                    {
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
                        _web.GoForward();
                    }
                }
                catch (Exception ex)
                {
                    Banner(ex.Message);
                }
            });
            _reload = ActionIconGlyph.Button("Reload", ActionIcon.Refresh, (_, _) =>
            {
                try
                {
                    _web.Reload();
                }
                catch (Exception ex)
                {
                    Banner(ex.Message);
                }
            });

            var go = ActionIconGlyph.Button("Go", ActionIcon.Next, async (_, _) => await CommitAsync(_address.Text));
            var external = ActionIconGlyph.Button("Open in default browser", ActionIcon.External, (_, _) =>
            {
                try
                {
                    if (Uri.TryCreate(_loadedUrl, UriKind.Absolute, out var uri))
                    {
                        Process.Start(new ProcessStartInfo { FileName = uri.AbsoluteUri, UseShellExecute = true });
                    }
                }
                catch
                {
                }
            });
            var shut = ActionIconGlyph.Button("Close", ActionIcon.Done, (_, _) => close(this));
            _address.KeyDown += async (_, e) =>
            {
                if (e.Key == VirtualKey.Enter)
                {
                    e.Handled = true;
                    await CommitAsync(_address.Text);
                }
            };

            var chrome = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = Theme.SpaceS,
                Padding = new Thickness(Theme.SpaceS),
                VerticalAlignment = VerticalAlignment.Center,
            };
            chrome.Children.Add(_back);
            chrome.Children.Add(_forward);
            chrome.Children.Add(_reload);
            chrome.Children.Add(_spinner);
            chrome.Children.Add(_address);
            chrome.Children.Add(go);
            chrome.Children.Add(external);
            chrome.Children.Add(shut);

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

            _web.NavigationStarting += (_, args) => SetLoading(true);
            _web.NavigationCompleted += (_, args) =>
            {
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
                        _address.Text = shown;
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
            if (string.IsNullOrWhiteSpace(_loadedUrl))
            {
                return;
            }
            try
            {
                await _web.EnsureCoreWebView2Async();
                _web.Source = new Uri(_loadedUrl);
            }
            catch (Exception ex)
            {
                Banner(ex.Message);
            }
        }

        /// <summary>
        /// Commit a typed address. Local dev servers are plain HTTP; anything
        /// else defaults to HTTPS so a mistyped or remote site is never sent
        /// in the clear. A remote site needs an explicit go-ahead before it
        /// loads inside the app.
        /// </summary>
        private async Task CommitAsync(string raw)
        {
            var candidate = (raw ?? "").Trim();
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
            if (!IsLoopback(url))
            {
                var dialog = new ContentDialog
                {
                    Title = "Open an external site?",
                    Content = $"{url.Host} is not a local development server. It will load inside the app's browser.",
                    PrimaryButtonText = "Open",
                    CloseButtonText = "Cancel",
                    DefaultButton = ContentDialogButton.Primary,
                };
                if (await Chrome.ShowDialog(_owner, dialog) != ContentDialogResult.Primary)
                {
                    return;
                }
            }
            Navigate(url.AbsoluteUri);
        }

        private void Navigate(string url)
        {
            _loadedUrl = url;
            _address.Text = url;
            _status.Children.Clear();
            _empty.Visibility = Visibility.Collapsed;
            HeaderChanged?.Invoke(this);
            try
            {
                _web.Source = new Uri(url);
            }
            catch (Exception ex)
            {
                Banner(ex.Message);
            }
        }

        /// <summary>
        /// Whether a URL points at this machine. Missing or odd hosts fail
        /// closed so they get a confirm.
        /// </summary>
        private static bool IsLoopback(Uri url)
        {
            var host = (url.Host ?? "").ToLowerInvariant();
            if (string.IsNullOrEmpty(host))
            {
                return false;
            }
            if (host == "localhost" || host == "::1" || host == "0.0.0.0")
            {
                return true;
            }
            var parts = host.Split('.');
            if (parts.Length == 4 && parts[0] == "127" && parts.All(p => p.Length > 0 && p.All(char.IsDigit)))
            {
                return true;
            }
            return false;
        }

        public async Task CloseAsync()
        {
            if (_closed)
            {
                return;
            }
            _closed = true;
            try
            {
                _web.CoreWebView2?.Stop();
            }
            catch
            {
            }
            if (_unlisten)
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
