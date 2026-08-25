// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;

namespace Tokenstat.Pages;

/// <summary>
/// In-app WebView2 pointed at a loopback URL from <c>proxy.listen</c>.
/// Close calls <c>proxy.unlisten</c> when this tab opened the listener.
/// </summary>
internal sealed class BrowserPage : Page
{
    private readonly string _url;
    private readonly string _host;
    private readonly int _port;
    private readonly bool _unlisten;
    private readonly WebView2 _web = new();
    private readonly StackPanel _status = new() { Spacing = Theme.SpaceS };
    private bool _closed;

    public BrowserPage(string url, string host, int port, bool unlisten)
    {
        _url = url;
        _host = host;
        _port = port;
        _unlisten = unlisten;

        var chrome = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Theme.SpaceS,
            Padding = new Thickness(Theme.SpaceS),
        };
        chrome.Children.Add(ActionIconGlyph.Button("Close", ActionIcon.Done, async (_, _) =>
        {
            await CloseAsync();
        }));
        chrome.Children.Add(ActionIconGlyph.Button("Reload", ActionIcon.Refresh, (_, _) =>
        {
            try
            {
                _web.Reload();
            }
            catch (Exception ex)
            {
                Banner(ex.Message);
            }
        }));
        chrome.Children.Add(new TextBlock
        {
            Text = url,
            VerticalAlignment = VerticalAlignment.Center,
            Opacity = 0.7,
            TextWrapping = TextWrapping.Wrap,
        });

        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        Grid.SetRow(_status, 1);
        Grid.SetRow(_web, 2);
        grid.Children.Add(chrome);
        grid.Children.Add(_status);
        grid.Children.Add(_web);
        Content = grid;

        Loaded += async (_, _) => await StartAsync();
        Unloaded += (_, _) => _ = CloseAsync();
    }

    private async Task StartAsync()
    {
        try
        {
            await _web.EnsureCoreWebView2Async();
            if (!string.IsNullOrEmpty(_url))
            {
                _web.Source = new Uri(_url);
            }
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
        }
    }

    private async Task CloseAsync()
    {
        if (_closed)
        {
            return;
        }
        _closed = true;
        if (_unlisten)
        {
            try
            {
                await AppServices.Host.CallAsync(
                    "proxy.unlisten",
                    new JsonObject
                    {
                        ["host"] = _host,
                        ["port"] = _port,
                    });
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
