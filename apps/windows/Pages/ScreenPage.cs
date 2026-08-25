// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Runtime.InteropServices.WindowsRuntime;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Tokenstat.Design;
using Windows.Storage.Streams;
using Windows.UI;

namespace Tokenstat.Pages;

/// <summary>
/// Legend screen viewer for another host. JPEG stills blit to an image.
/// H.264 frames show status text in this cut.
/// </summary>
internal sealed class ScreenPage : Page
{
    private readonly string _peer;
    private readonly string _name;
    private readonly StackPanel _status = new() { Spacing = Theme.SpaceS };
    private readonly TextBlock _caption = new()
    {
        Opacity = 0.8,
        TextWrapping = TextWrapping.Wrap,
        HorizontalAlignment = HorizontalAlignment.Center,
    };
    private readonly Image _picture = new()
    {
        Stretch = Stretch.Uniform,
        HorizontalAlignment = HorizontalAlignment.Stretch,
        VerticalAlignment = VerticalAlignment.Stretch,
    };

    private string? _sessionId;
    private CancellationTokenSource? _poll;
    private bool _closed;
    private bool _sawH264;

    public ScreenPage(string peer, string name)
    {
        _peer = peer;
        _name = name;

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
        chrome.Children.Add(new TextBlock
        {
            Text = name,
            VerticalAlignment = VerticalAlignment.Center,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });

        var stage = new Grid
        {
            Background = new SolidColorBrush(Color.FromArgb(255, 0, 0, 0)),
        };
        stage.Children.Add(_picture);
        _caption.Foreground = new SolidColorBrush(Color.FromArgb(255, 255, 255, 255));
        _caption.VerticalAlignment = VerticalAlignment.Center;
        stage.Children.Add(_caption);

        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        Grid.SetRow(_status, 1);
        Grid.SetRow(stage, 2);
        grid.Children.Add(chrome);
        grid.Children.Add(_status);
        grid.Children.Add(stage);
        Content = grid;

        Loaded += async (_, _) => await StartAsync();
        Unloaded += (_, _) => _ = CloseAsync();
    }

    private async Task StartAsync()
    {
        _caption.Text = "Connecting…";
        string tier;
        try
        {
            var account = await AppServices.Host.CallAsync("account.status");
            tier = Format.Text(account, "tier");
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
            _caption.Text = ex.Message;
            return;
        }
        if (!Format.IsLegend(tier))
        {
            _caption.Text = "Screen access requires the Legend plan.";
            Banner("Requires Legend");
            return;
        }

        JsonNode identity;
        try
        {
            identity = await AppServices.Host.CallAsync("machine.identity");
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
            _caption.Text = ex.Message;
            return;
        }
        var peerId = Format.Text(identity, "key", Format.Text(identity, "publicIdentity"));
        if (string.IsNullOrEmpty(peerId))
        {
            Banner("This PC has no identity yet.");
            _caption.Text = "This PC has no identity yet.";
            return;
        }

        JsonNode issued;
        try
        {
            issued = await AppServices.Host.CallAsync(
                "remote.call",
                new JsonObject
                {
                    ["peer"] = _peer,
                    ["method"] = "screen.capability.issue",
                    ["params"] = new JsonObject
                    {
                        ["peerId"] = peerId,
                        ["control"] = false,
                        ["tier"] = "legend",
                    },
                },
                TimeSpan.FromSeconds(30));
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
            _caption.Text = ex.Message;
            return;
        }

        var token = Format.Text(issued, "token", Format.Text(issued, "capability"));
        if (string.IsNullOrEmpty(token))
        {
            Banner("The host did not issue a capability.");
            _caption.Text = "The host did not issue a capability.";
            return;
        }

        JsonNode opened;
        try
        {
            opened = await AppServices.Host.CallAsync(
                "screen.viewer.open",
                new JsonObject
                {
                    ["peer"] = _peer,
                    ["capability"] = token,
                    ["control"] = false,
                },
                TimeSpan.FromSeconds(30));
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
            _caption.Text = ex.Message;
            return;
        }

        _sessionId = Format.Text(opened, "id");
        if (string.IsNullOrEmpty(_sessionId))
        {
            Banner("The viewer opened without an id.");
            _caption.Text = "The viewer opened without an id.";
            return;
        }
        var transport = Format.Text(opened, "transport", "relay");
        _caption.Text = "Waiting for the first picture · " + transport;
        _poll = new CancellationTokenSource();
        _ = PollAsync(_poll.Token);
    }

    private async Task PollAsync(CancellationToken token)
    {
        var id = _sessionId;
        if (string.IsNullOrEmpty(id))
        {
            return;
        }
        while (!token.IsCancellationRequested)
        {
            JsonNode chunk;
            try
            {
                chunk = await AppServices.Host.CallAsync(
                    "screen.viewer.read",
                    new JsonObject
                    {
                        ["id"] = id,
                        ["waitMs"] = 250,
                    },
                    TimeSpan.FromSeconds(8));
            }
            catch (Exception ex)
            {
                if (!token.IsCancellationRequested)
                {
                    Banner(ex.Message);
                    Caption(ex.Message);
                }
                return;
            }
            if (token.IsCancellationRequested)
            {
                return;
            }
            var error = Format.Text(chunk, "error");
            if (!string.IsNullOrEmpty(error))
            {
                Banner(error);
                Caption(error);
                return;
            }
            if (chunk["active"] is not null && !Format.Flag(chunk, "active"))
            {
                Caption("The host stopped sharing.");
                return;
            }
            var encoded = Format.Text(chunk, "frame");
            if (string.IsNullOrEmpty(encoded))
            {
                continue;
            }
            byte[] bytes;
            try
            {
                bytes = Convert.FromBase64String(encoded);
            }
            catch
            {
                continue;
            }
            if (bytes.Length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8)
            {
                var still = bytes;
                DispatcherQueue.TryEnqueue(() => _ = ShowJpegOnUiAsync(still));
                Caption(_name);
            }
            else if (!_sawH264)
            {
                _sawH264 = true;
                Caption("This stream is H.264. JPEG stills show as a picture here.");
            }
        }
    }

    private async Task ShowJpegOnUiAsync(byte[] bytes)
    {
        try
        {
            using var stream = new InMemoryRandomAccessStream();
            await stream.WriteAsync(bytes.AsBuffer());
            stream.Seek(0);
            var bitmap = new BitmapImage();
            await bitmap.SetSourceAsync(stream);
            _picture.Source = bitmap;
        }
        catch
        {
            // A bad still must not kill the viewer.
        }
    }

    private async Task CloseAsync()
    {
        if (_closed)
        {
            return;
        }
        _closed = true;
        _poll?.Cancel();
        var id = _sessionId;
        _sessionId = null;
        if (string.IsNullOrEmpty(id))
        {
            return;
        }
        try
        {
            await AppServices.Host.CallAsync("screen.viewer.close", new JsonObject { ["id"] = id });
        }
        catch
        {
            // Leaving the page must not throw.
        }
    }

    private void Banner(string text)
    {
        void show()
        {
            _status.Children.Clear();
            _status.Children.Add(Chrome.Banner(text, Theme.Danger, Symbol.Important));
        }
        if (DispatcherQueue.HasThreadAccess)
        {
            show();
            return;
        }
        DispatcherQueue.TryEnqueue(show);
    }

    private void Caption(string text)
    {
        if (DispatcherQueue.HasThreadAccess)
        {
            _caption.Text = text;
            return;
        }
        DispatcherQueue.TryEnqueue(() => _caption.Text = text);
    }
}
