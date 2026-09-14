// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Runtime.InteropServices.WindowsRuntime;
using System.Text;
using System.Text.Json.Nodes;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Tokenstat.Design;
using Windows.Media.Core;
using Windows.Storage.Streams;
using Windows.UI;

namespace Tokenstat.Pages;

/// <summary>
/// Screen viewer for another host. H.264 video frames are decoded through
/// a MediaStreamSource after the same TSCR envelope check the Apple
/// decoder runs, and plain JPEG stills from older hosts blit to an image.
/// Pointer and keyboard input, the control toggle, quality, and display
/// choice ride screen.viewer.input with the same event shapes the Apple
/// capture side applies. Audio has no pipeline in this cut and is skipped.
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
        VerticalAlignment = VerticalAlignment.Center,
    };
    private readonly Image _picture = new()
    {
        Stretch = Stretch.Uniform,
        HorizontalAlignment = HorizontalAlignment.Stretch,
        VerticalAlignment = VerticalAlignment.Stretch,
    };
    private readonly MediaPlayerElement _player = new()
    {
        Stretch = Stretch.Uniform,
        AreTransportControlsEnabled = false,
        Visibility = Visibility.Collapsed,
        HorizontalAlignment = HorizontalAlignment.Stretch,
        VerticalAlignment = VerticalAlignment.Stretch,
    };
    private readonly Grid _stage = new()
    {
        Background = new SolidColorBrush(Color.FromArgb(255, 0, 0, 0)),
    };
    private readonly StackPanel _controlSlot = new()
    {
        Orientation = Orientation.Horizontal,
        Spacing = Theme.SpaceS,
    };
    private readonly StackPanel _qualitySlot = new()
    {
        Orientation = Orientation.Horizontal,
        Spacing = Theme.SpaceS,
    };
    private readonly StackPanel _displaySlot = new()
    {
        Orientation = Orientation.Horizontal,
        Spacing = Theme.SpaceS,
    };
    private readonly TextBox _keyBox = new()
    {
        PlaceholderText = "Type keys for the remote machine",
        MinWidth = 240,
    };

    private string _peerId = "";
    private string _capability = "";
    private string _hostSessionId = "";
    private string _transport = "relay";
    private bool _control;
    private string _quality = "auto";

    private string? _sessionId;
    private CancellationTokenSource? _poll;
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? _heartbeat;
    private bool _closed;
    private int _reconnects;
    private DateTime _connectedSince;
    private DateTime? _streamingSince;
    private H264Streamer? _streamer;
    private bool _havePicture;
    private long _dropped;
    private long _stampMs;
    private double _cursorX = 0.5;
    private double _cursorY = 0.5;
    private DateTime _lastMove = DateTime.MinValue;
    private DateTime _lastClick = DateTime.MinValue;
    private List<ScreenDisplay> _displays = new();
    private uint _selectedDisplay;

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

        var controls = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Theme.SpaceL,
            Padding = new Thickness(Theme.SpaceS, 0, Theme.SpaceS, Theme.SpaceS),
        };
        RefreshControlChip();
        RefreshQualityPicker();
        controls.Children.Add(_controlSlot);
        controls.Children.Add(_qualitySlot);
        controls.Children.Add(_displaySlot);

        _caption.Foreground = new SolidColorBrush(Color.FromArgb(255, 255, 255, 255));
        _stage.Children.Add(_picture);
        _stage.Children.Add(_player);
        _stage.Children.Add(_caption);
        _stage.PointerPressed += StageOnPointerPressed;
        _stage.PointerMoved += StageOnPointerMoved;
        _stage.PointerWheelChanged += StageOnPointerWheel;

        var keyBar = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Theme.SpaceS,
            Padding = new Thickness(Theme.SpaceS),
        };
        keyBar.Children.Add(_keyBox);
        keyBar.Children.Add(ActionIconGlyph.Button("Send", ActionIcon.Send, async (_, _) =>
        {
            var text = _keyBox.Text ?? "";
            _keyBox.Text = "";
            await SendTextAsync(text);
        }));
        foreach (var special in new[] { "Esc", "Tab", "Enter", "Back" })
        {
            var keyButton = new Button
            {
                Content = special,
                MinWidth = 56,
            };
            var label = special;
            keyButton.Click += async (_, _) => await SendSpecialAsync(label);
            keyBar.Children.Add(keyButton);
        }
        _keyBox.KeyDown += async (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Enter)
            {
                e.Handled = true;
                var text = _keyBox.Text ?? "";
                _keyBox.Text = "";
                await SendTextAsync(text);
            }
        };

        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Grid.SetRow(_status, 2);
        Grid.SetRow(_stage, 3);
        Grid.SetRow(keyBar, 4);
        grid.Children.Add(chrome);
        grid.Children.Add(controls);
        grid.Children.Add(_status);
        grid.Children.Add(_stage);
        grid.Children.Add(keyBar);
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
            Caption(ex.Message);
            return;
        }
        if (!Format.IsLegend(tier))
        {
            Caption("Screen access requires the Legend plan.");
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
            Caption(ex.Message);
            return;
        }
        _peerId = Format.Text(identity, "key", Format.Text(identity, "publicIdentity"));
        if (string.IsNullOrEmpty(_peerId))
        {
            Banner("This PC has no identity yet.");
            Caption("This PC has no identity yet.");
            return;
        }

        try
        {
            await OpenAsync(_control);
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
            Caption(ex.Message);
            return;
        }
        _poll = new CancellationTokenSource();
        _ = PollAsync(_poll.Token);
    }

    /// <summary>
    /// Open the viewer stream: fresh capability, then the local viewer
    /// session over the same direct-then-relay ladder as terminals. Auto
    /// quality is the absence of a choice, so it is omitted and the host
    /// reads the route instead.
    /// </summary>
    private async Task OpenAsync(bool control)
    {
        _capability = await IssueCapabilityAsync(control);
        var openParams = new JsonObject
        {
            ["peer"] = _peer,
            ["capability"] = _capability,
            ["control"] = control,
        };
        if (_quality != "auto")
        {
            openParams["quality"] = _quality;
        }
        var opened = await AppServices.Host.CallAsync(
            "screen.viewer.open", openParams, TimeSpan.FromSeconds(30));
        _sessionId = Format.Text(opened, "id");
        if (string.IsNullOrEmpty(_sessionId))
        {
            throw new InvalidOperationException("The viewer opened without an id.");
        }
        _hostSessionId = Format.Text(opened, "sessionId");
        _transport = Format.Transport(Format.Text(opened, "transport", "relay"));
        _control = control;
        _connectedSince = DateTime.UtcNow;
        _streamingSince = null;
        RefreshControlChip();
        Caption("Waiting for the first picture · " + _transport);
    }

    private async Task<string> IssueCapabilityAsync(bool control)
    {
        var issued = await AppServices.Host.CallAsync(
            "remote.call",
            new JsonObject
            {
                ["peer"] = _peer,
                ["method"] = "screen.capability.issue",
                ["params"] = new JsonObject
                {
                    ["peerId"] = _peerId,
                    ["control"] = control,
                    ["tier"] = "legend",
                },
            },
            TimeSpan.FromSeconds(30));
        var token = Format.Text(issued, "token", Format.Text(issued, "capability"));
        if (string.IsNullOrEmpty(token))
        {
            throw new InvalidOperationException("The host did not issue a capability.");
        }
        return token;
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
                    await ReconnectAsync(ex.Message);
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
                var reason = string.IsNullOrEmpty(error) ? "The host stopped sharing." : error;
                if (Actionable(reason))
                {
                    Banner(reason);
                    Caption(reason);
                }
                else
                {
                    await ReconnectAsync(reason);
                }
                return;
            }
            _dropped += Format.Long(chunk, "dropped");
            HandleMetadata(Format.Text(chunk, "metadata"));
            var encoded = Format.Text(chunk, "frame");
            if (!string.IsNullOrEmpty(encoded))
            {
                byte[] bytes;
                try
                {
                    bytes = Convert.FromBase64String(encoded);
                }
                catch
                {
                    continue;
                }
                HandleFrame(bytes);
            }
            if (!_streamingSince.HasValue
                && (DateTime.UtcNow - _connectedSince).TotalSeconds > 8)
            {
                await CloseViewerAsync();
                Caption("Connected, but no picture has arrived yet. The host may not have Screen Recording, or tokenstat may not be open on that machine.");
                Banner("No picture arrived.");
                return;
            }
        }
    }

    private void HandleMetadata(string encoded)
    {
        if (string.IsNullOrEmpty(encoded))
        {
            return;
        }
        byte[] bytes;
        try
        {
            bytes = Convert.FromBase64String(encoded);
        }
        catch
        {
            return;
        }
        JsonNode? metadata;
        try
        {
            metadata = JsonNode.Parse(Encoding.UTF8.GetString(bytes));
        }
        catch
        {
            return;
        }
        if (Format.Text(metadata, "type") != "displays")
        {
            // Clipboard notes have no pipeline in this cut.
            return;
        }
        var displays = new List<ScreenDisplay>();
        if (metadata is JsonObject obj && obj["displays"] is JsonArray array)
        {
            foreach (var item in array)
            {
                var id = Format.Long(item, "id");
                if (id < 0)
                {
                    continue;
                }
                displays.Add(new ScreenDisplay(
                    (uint)id,
                    Format.Text(item, "name", "Display"),
                    (int)Format.Long(item, "width"),
                    (int)Format.Long(item, "height")));
            }
        }
        if (displays.Count == 0)
        {
            return;
        }
        _displays = displays;
        var selected = Format.Long(metadata, "selected");
        _selectedDisplay = selected < 0 ? displays[0].Id : (uint)selected;
        DispatcherQueue.TryEnqueue(RefreshDisplayPicker);
    }

    private void HandleFrame(byte[] bytes)
    {
        if (ScreenFrame.LooksLikeJpeg(bytes))
        {
            var still = bytes;
            DispatcherQueue.TryEnqueue(() => ShowStillOnUi(still));
            MarkStreaming();
            return;
        }
        var frame = ScreenFrame.Parse(bytes);
        if (frame is null)
        {
            return;
        }
        if (ScreenFrame.LooksLikeJpeg(frame.Payload))
        {
            var still = frame.Payload;
            DispatcherQueue.TryEnqueue(() => ShowStillOnUi(still));
            MarkStreaming();
            return;
        }
        var avcc = frame.ToAvcc();
        if (avcc.Length == 0)
        {
            return;
        }
        if (!frame.Keyframe && !_havePicture)
        {
            // Deltas before the first keyframe cannot be drawn, and
            // forwarding them only looks connected while staying black.
            return;
        }
        MarkStreaming();
        DispatcherQueue.TryEnqueue(() => PushH264OnUi(frame, avcc));
    }

    private void MarkStreaming()
    {
        if (_streamingSince.HasValue)
        {
            return;
        }
        _streamingSince = DateTime.UtcNow;
        Caption(_name);
    }

    private void PushH264OnUi(ScreenFrame frame, byte[] avcc)
    {
        if (frame.Width <= 0 || frame.Height <= 0)
        {
            return;
        }
        var width = (uint)frame.Width;
        var height = (uint)frame.Height;
        try
        {
            if (_streamer is null || _streamer.Width != width || _streamer.Height != height)
            {
                _streamer?.Close();
                _streamer = null;
                if (!frame.Keyframe)
                {
                    // A fresh decoder needs its parameter sets first.
                    return;
                }
                var streamer = new H264Streamer(width, height);
                _player.Source = MediaSource.CreateFromMediaStreamSource(streamer.Source);
                _streamer = streamer;
                _stampMs = 0;
                _player.Visibility = Visibility.Visible;
                _picture.Visibility = Visibility.Collapsed;
                Caption(_dropped > 0
                    ? $"Decoding H.264 · {_transport} · {_dropped} frames dropped"
                    : "Decoding H.264 · " + _transport);
            }
            _stampMs += 33;
            _streamer.Push(avcc, frame.Keyframe, TimeSpan.FromMilliseconds(_stampMs));
            _havePicture = true;
        }
        catch (Exception ex)
        {
            _streamer = null;
            _player.Source = null;
            _player.Visibility = Visibility.Collapsed;
            _picture.Visibility = Visibility.Visible;
            Caption("This stream is H.264, but the decoder could not start: " + ex.Message);
            Banner("The H.264 decoder could not start: " + ex.Message);
        }
    }

    private void ShowStillOnUi(byte[] bytes)
    {
        _streamer?.Close();
        _streamer = null;
        _havePicture = true;
        _player.Source = null;
        _player.Visibility = Visibility.Collapsed;
        _picture.Visibility = Visibility.Visible;
        _ = ShowJpegOnUiAsync(bytes);
        Caption(_name);
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

    private async Task ReconnectAsync(string reason)
    {
        if (_closed)
        {
            return;
        }
        await CloseViewerAsync();
        DispatcherQueue.TryEnqueue(() =>
        {
            _streamer?.Close();
            _streamer = null;
            _havePicture = false;
            _player.Source = null;
            _player.Visibility = Visibility.Collapsed;
            _picture.Source = null;
            _picture.Visibility = Visibility.Visible;
        });
        if (_closed)
        {
            return;
        }
        _reconnects++;
        if (_reconnects > 3)
        {
            Caption("Connection could not recover. " + reason);
            Banner(reason);
            return;
        }
        Caption($"Reconnecting, attempt {_reconnects} of 3. {reason}");
        try
        {
            await Task.Delay(TimeSpan.FromSeconds(_reconnects));
        }
        catch
        {
            // Shutdown must not throw.
        }
        if (_closed)
        {
            return;
        }
        try
        {
            await OpenAsync(_control);
        }
        catch (Exception ex)
        {
            await ReconnectAsync(ex.Message);
            return;
        }
        _poll?.Cancel();
        _poll = new CancellationTokenSource();
        _ = PollAsync(_poll.Token);
    }

    private static bool Actionable(string reason)
    {
        var value = reason.ToLowerInvariant();
        return value.Contains("screen recording") || value.Contains("accessibility")
            || value.Contains("permission") || value.Contains("not been allowed")
            || value.Contains("does not have screen access") || value.Contains("legend plan")
            || value.Contains("no display") || value.Contains("videotoolbox");
    }

    private async Task CloseViewerAsync()
    {
        _poll?.Cancel();
        _poll = null;
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

    private async Task CloseAsync()
    {
        if (_closed)
        {
            return;
        }
        _closed = true;
        _heartbeat?.Stop();
        _heartbeat = null;
        await CloseViewerAsync();
        DispatcherQueue.TryEnqueue(() =>
        {
            _streamer?.Close();
            _streamer = null;
            _player.Source = null;
        });
    }

    private void StageOnPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        if (!_control)
        {
            return;
        }
        e.Handled = true;
        var point = Normalize(e);
        if (point is null)
        {
            return;
        }
        var (x, y) = point.Value;
        _cursorX = x;
        _cursorY = y;
        var now = DateTime.UtcNow;
        var count = (now - _lastClick).TotalMilliseconds < 400 ? 2 : 1;
        _lastClick = now;
        var properties = e.GetCurrentPoint(_stage).Properties;
        var button = properties.IsRightButtonPressed ? 2
            : properties.IsMiddleButtonPressed ? 1 : 0;
        _ = SendEventAsync(new JsonObject
        {
            ["type"] = "click",
            ["x"] = x,
            ["y"] = y,
            ["button"] = button,
            ["clickCount"] = count,
        });
    }

    private void StageOnPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!_control)
        {
            return;
        }
        var now = DateTime.UtcNow;
        if ((now - _lastMove).TotalMilliseconds < 60)
        {
            return;
        }
        var point = Normalize(e);
        if (point is null)
        {
            return;
        }
        _lastMove = now;
        _cursorX = point.Value.x;
        _cursorY = point.Value.y;
        _ = SendEventAsync(new JsonObject
        {
            ["type"] = "move",
            ["x"] = _cursorX,
            ["y"] = _cursorY,
        });
    }

    private void StageOnPointerWheel(object sender, PointerRoutedEventArgs e)
    {
        if (!_control)
        {
            return;
        }
        e.Handled = true;
        var properties = e.GetCurrentPoint(_stage).Properties;
        _ = SendEventAsync(new JsonObject
        {
            ["type"] = "scroll",
            ["x"] = _cursorX,
            ["y"] = _cursorY,
            ["dx"] = 0,
            ["dy"] = properties.MouseWheelDelta,
        });
    }

    private (double x, double y)? Normalize(PointerRoutedEventArgs e)
    {
        var width = _stage.ActualWidth;
        var height = _stage.ActualHeight;
        if (width <= 0 || height <= 0)
        {
            return null;
        }
        var position = e.GetCurrentPoint(_stage).Position;
        return (
            Math.Clamp(position.X / width, 0, 1),
            Math.Clamp(position.Y / height, 0, 1));
    }

    private async Task SendTextAsync(string text)
    {
        if (string.IsNullOrEmpty(text) || !_control)
        {
            return;
        }
        await SendEventAsync(new JsonObject
        {
            ["type"] = "text",
            ["text"] = text,
            ["flags"] = 0,
        });
    }

    private async Task SendSpecialAsync(string label)
    {
        var text = label switch
        {
            "Esc" => "\u001b",
            "Tab" => "\t",
            "Enter" => "\r",
            "Back" => "\b",
            _ => "",
        };
        await SendTextAsync(text);
    }

    private async Task SendDisplayAsync(uint id)
    {
        _selectedDisplay = id;
        await SendEventAsync(new JsonObject
        {
            ["type"] = "display",
            ["id"] = JsonValue.Create(id),
        });
    }

    private Task SendEventAsync(JsonObject evt)
    {
        var id = _sessionId;
        if (!_control || string.IsNullOrEmpty(id))
        {
            return Task.CompletedTask;
        }
        var data = Convert.ToBase64String(Encoding.UTF8.GetBytes(evt.ToJsonString()));
        return AppServices.Host.CallAsync(
            "screen.viewer.input",
            new JsonObject
            {
                ["id"] = id,
                ["data"] = data,
            });
    }

    /// <summary>
    /// Hand the mouse over, or take it back, on the session that is already
    /// up. A fresh capability every time: the one this session opened with
    /// says what it was opened for, and control is exactly the field the
    /// host checks. Falls back to reopening when the host is too old to
    /// flip in place.
    /// </summary>
    private async Task SetControlAsync(bool wanted)
    {
        if (wanted == _control || _closed)
        {
            return;
        }
        if (!string.IsNullOrEmpty(_hostSessionId) && !string.IsNullOrEmpty(_sessionId))
        {
            try
            {
                var capability = await IssueCapabilityAsync(wanted);
                await AppServices.Host.CallAsync(
                    "remote.call",
                    new JsonObject
                    {
                        ["peer"] = _peer,
                        ["method"] = "screen.control.set",
                        ["params"] = new JsonObject
                        {
                            ["sessionId"] = _hostSessionId,
                            ["capability"] = capability,
                            ["control"] = wanted,
                        },
                    },
                    TimeSpan.FromSeconds(15));
                _capability = capability;
                _control = wanted;
                RefreshControlChip();
                UpdateHeartbeat();
                Caption(wanted ? "Controlling · " + _name : _name);
                return;
            }
            catch
            {
                // Fall through to reopening below.
            }
        }
        await CloseViewerAsync();
        ResetPictureOnUi();
        try
        {
            await OpenAsync(wanted);
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
            Caption(ex.Message);
            _control = false;
            RefreshControlChip();
            return;
        }
        UpdateHeartbeat();
        _poll?.Cancel();
        _poll = new CancellationTokenSource();
        _ = PollAsync(_poll.Token);
    }

    /// <summary>
    /// Move a live session to a different budget without reopening: the
    /// relay allows one screen channel per account, so a reopen races its
    /// own teardown. A host too old to know the method keeps the picture
    /// it has.
    /// </summary>
    private async Task SetQualityAsync(string wire)
    {
        if (wire == _quality || _closed)
        {
            return;
        }
        _quality = wire;
        RefreshQualityPicker();
        if (string.IsNullOrEmpty(_hostSessionId) || string.IsNullOrEmpty(_sessionId))
        {
            return;
        }
        try
        {
            var capability = await IssueCapabilityAsync(_control);
            await AppServices.Host.CallAsync(
                "remote.call",
                new JsonObject
                {
                    ["peer"] = _peer,
                    ["method"] = "screen.quality.set",
                    ["params"] = new JsonObject
                    {
                        ["sessionId"] = _hostSessionId,
                        ["capability"] = capability,
                        ["quality"] = wire,
                    },
                },
                TimeSpan.FromSeconds(15));
            _capability = capability;
        }
        catch
        {
            // Not worth a failed state. The session still runs on the old budget.
        }
    }

    private void UpdateHeartbeat()
    {
        _heartbeat?.Stop();
        _heartbeat = null;
        if (!_control || _closed)
        {
            return;
        }
        _heartbeat = DispatcherQueue.CreateTimer();
        _heartbeat.Interval = TimeSpan.FromSeconds(15);
        _heartbeat.Tick += (_, _) =>
        {
            _ = SendEventAsync(new JsonObject { ["type"] = "heartbeat" });
        };
        _heartbeat.Start();
    }

    private void RefreshControlChip()
    {
        void show()
        {
            _controlSlot.Children.Clear();
            _controlSlot.Children.Add(Chrome.ToggleChip("Control", _control, SetControlAsync));
        }
        if (DispatcherQueue.HasThreadAccess)
        {
            show();
            return;
        }
        DispatcherQueue.TryEnqueue(show);
    }

    private void RefreshQualityPicker()
    {
        void show()
        {
            _qualitySlot.Children.Clear();
            _qualitySlot.Children.Add(Chrome.Segmented(
                new List<(string Value, string Label)>
                {
                    ("auto", "Automatic"),
                    ("sharp", "Sharp"),
                    ("smooth", "Smooth"),
                    ("dataSaver", "Data saver"),
                },
                _quality,
                SetQualityAsync));
        }
        if (DispatcherQueue.HasThreadAccess)
        {
            show();
            return;
        }
        DispatcherQueue.TryEnqueue(show);
    }

    private void RefreshDisplayPicker()
    {
        _displaySlot.Children.Clear();
        if (_displays.Count < 2)
        {
            return;
        }
        var options = new List<(string Value, string Label)>();
        foreach (var display in _displays)
        {
            options.Add((display.Id.ToString(), $"{display.Name} {display.Width}x{display.Height}"));
        }
        _displaySlot.Children.Add(Chrome.Segmented(
            options,
            _selectedDisplay.ToString(),
            async value =>
            {
                if (uint.TryParse(value, out var id))
                {
                    await SendDisplayAsync(id);
                }
            }));
    }

    private void ResetPictureOnUi()
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            _streamer?.Close();
            _streamer = null;
            _havePicture = false;
            _player.Source = null;
            _player.Visibility = Visibility.Collapsed;
            _picture.Source = null;
            _picture.Visibility = Visibility.Visible;
        });
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

    private sealed record ScreenDisplay(uint Id, string Name, int Width, int Height);
}
