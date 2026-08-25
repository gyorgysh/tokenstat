// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Text;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Tokenstat.Design;
using Windows.System;
using Windows.UI;

namespace Tokenstat.Pages;

internal sealed class TerminalPage : Page
{
    internal const int BufferCap = 200_000;

    private readonly string _workspaceId;
    private readonly StackPanel _status = new() { Spacing = Theme.SpaceS };
    private readonly TextBlock _view = new()
    {
        FontFamily = new FontFamily("Consolas"),
        FontSize = 13,
        Foreground = new SolidColorBrush(Color.FromArgb(255, 255, 255, 255)),
        TextWrapping = TextWrapping.Wrap,
        IsTextSelectionEnabled = true,
    };
    private readonly ScrollViewer _scroll = new()
    {
        Background = new SolidColorBrush(Color.FromArgb(255, 0, 0, 0)),
        Padding = new Thickness(Theme.SpaceS),
    };
    private readonly TextBox _input = new()
    {
        PlaceholderText = "Type, then Enter",
        FontFamily = new FontFamily("Consolas"),
    };

    private string? _sessionId;
    private long _offset;
    private CancellationTokenSource? _poll;
    private bool _started;

    public TerminalPage(string workspaceId, string? sessionId)
    {
        _workspaceId = workspaceId;
        _sessionId = sessionId;
        _scroll.Content = _view;

        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Grid.SetRow(_scroll, 1);
        Grid.SetRow(_input, 2);
        grid.Children.Add(_status);
        grid.Children.Add(_scroll);
        grid.Children.Add(_input);
        Content = grid;

        _input.KeyDown += InputOnKeyDown;
        Loaded += async (_, _) => await StartAsync();
        Unloaded += (_, _) => _ = StopAsync();
    }

    private async Task StartAsync()
    {
        if (_started)
        {
            return;
        }
        _started = true;
        try
        {
            if (string.IsNullOrEmpty(_sessionId))
            {
                var spawned = await AppServices.Host.CallAsync(
                    "pty.spawn",
                    new JsonObject
                    {
                        ["workspaceId"] = _workspaceId,
                        ["command"] = "cmd.exe",
                        ["args"] = new JsonArray(),
                        ["rows"] = 30,
                        ["cols"] = 100,
                    });
                _sessionId = Format.Text(spawned, "id");
            }
            if (string.IsNullOrEmpty(_sessionId))
            {
                Banner("The host did not return a session id.");
                return;
            }
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
            return;
        }

        _poll = new CancellationTokenSource();
        _ = PollAsync(_poll.Token);
    }

    private async Task StopAsync()
    {
        _poll?.Cancel();
        var id = _sessionId;
        if (string.IsNullOrEmpty(id))
        {
            return;
        }
        try
        {
            await AppServices.Host.CallAsync("pty.detach", new JsonObject { ["id"] = id });
        }
        catch
        {
            // Leaving the page must not throw.
        }
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
                    "pty.read",
                    new JsonObject
                    {
                        ["id"] = id,
                        ["offset"] = _offset,
                        ["waitMs"] = 400,
                    },
                    TimeSpan.FromSeconds(8));
            }
            catch (Exception ex)
            {
                if (!token.IsCancellationRequested)
                {
                    Banner(ex.Message);
                }
                return;
            }
            if (token.IsCancellationRequested)
            {
                return;
            }
            var next = Format.Long(chunk, "nextOffset");
            if (next > _offset)
            {
                _offset = next;
            }
            if (Format.Long(chunk, "dropped") > 0)
            {
                Append("\r\n[output dropped]\r\n");
            }
            var encoded = Format.Text(chunk, "data");
            if (encoded.Length == 0)
            {
                continue;
            }
            try
            {
                var bytes = Convert.FromBase64String(encoded);
                Append(Encoding.UTF8.GetString(bytes));
            }
            catch
            {
                // Skip a malformed chunk rather than killing the session.
            }
        }
    }

    private async void InputOnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Enter)
        {
            return;
        }
        e.Handled = true;
        var id = _sessionId;
        if (string.IsNullOrEmpty(id))
        {
            return;
        }
        var line = _input.Text ?? "";
        _input.Text = "";
        var payload = Encoding.UTF8.GetBytes(line + "\r\n");
        try
        {
            await AppServices.Host.CallAsync(
                "pty.write",
                new JsonObject
                {
                    ["id"] = id,
                    ["data"] = Convert.ToBase64String(payload),
                });
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
        }
    }

    private void Append(string text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return;
        }
        var combined = _view.Text + text;
        if (combined.Length > BufferCap)
        {
            combined = combined[(combined.Length - (BufferCap - 20_000))..];
        }
        _view.Text = combined;
        _scroll.UpdateLayout();
        _scroll.ChangeView(null, _scroll.ExtentHeight, null);
    }

    private void Banner(string text)
    {
        _status.Children.Clear();
        _status.Children.Add(Chrome.Banner(text, Theme.Danger, Symbol.Important));
    }
}
