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
internal sealed class ScreenPage : Page, IInspectorContent, IToolbarItems
{
    private readonly string _peer;
    private readonly string _name;
    private readonly StackPanel _inspector = new()
    {
        Spacing = Theme.SpaceM,
        Padding = new Thickness(Theme.SpaceM),
    };
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
    private Windows.Media.Playback.MediaPlayer? _mediaPlayer;
    private readonly MediaPlayerElement _player = new()
    {
        Stretch = Stretch.Uniform,
        AreTransportControlsEnabled = false,
        AutoPlay = true,
        Visibility = Visibility.Collapsed,
        HorizontalAlignment = HorizontalAlignment.Stretch,
        VerticalAlignment = VerticalAlignment.Stretch,
    };
    private readonly ContentControl _screenInput = new() { IsTabStop = true, HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    private int? _pressedButton;
    private readonly HashSet<int> _pressedKeys = new();
    private readonly SemaphoreSlim _inputGate = new(1, 1);
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
        PlaceholderText = L10n.Text("windows.screenpage.type_keys_for_the_remote_machine.5c29f8c7"),
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
    private long _dropped;
    private ulong _firstStampUs;
    private long _lastStampTicks;
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
        chrome.Children.Add(new TextBlock
        {
            Text = name,
            VerticalAlignment = VerticalAlignment.Center,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });

        var controls = new FlowPanel
        {
            Spacing = Theme.SpaceS,
            Margin = new Thickness(Theme.SpaceS, 0, Theme.SpaceS, Theme.SpaceS),
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
        _screenInput.Content = _stage;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_screenInput, L10n.Text("windows.screenpage.remote_screen_click_to_send_keyboard_and_m.286bed2d"));
        _screenInput.KeyDown += (_, e) => ForwardKey(e, true);
        _screenInput.KeyUp += (_, e) => ForwardKey(e, false);
        _screenInput.LostFocus += (_, _) =>
        {
            ReleasePointer();
            foreach (var code in _pressedKeys.ToArray())
                _ = SendEventAsync(new JsonObject { ["type"] = "key", ["keyCode"] = code, ["down"] = false, ["flags"] = 0 });
            _pressedKeys.Clear();
        };
        _stage.PointerPressed += StageOnPointerPressed;
        _stage.PointerReleased += (_, e) =>
        {
            if (Normalize(e) is { } point) { _cursorX = point.x; _cursorY = point.y; }
            ReleasePointer();
            _stage.ReleasePointerCapture(e.Pointer);
        };
        _stage.PointerCaptureLost += (_, _) => ReleasePointer();
        _stage.PointerMoved += StageOnPointerMoved;
        _stage.PointerWheelChanged += StageOnPointerWheel;

        var keyBar = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Theme.SpaceS,
            Padding = new Thickness(Theme.SpaceS),
        };
        keyBar.Children.Add(_keyBox);
        keyBar.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.screenpage.send.f6f4688f"), ActionIcon.Send, async (_, _) =>
        {
            var text = _keyBox.Text ?? "";
            _keyBox.Text = "";
            await SendTextAsync(text);
        }));
        foreach (var (label, text) in new[]
        {
            (L10n.Text("windows.screenpage.esc.52f878ed"), "\u001b"),
            (L10n.Text("windows.screenpage.tab.90ddf196"), "\t"),
            (L10n.Text("windows.screenpage.enter.dc8659db"), "\r"),
            (L10n.Text("common.back"), "\b"),
        })
        {
            var keyButton = new Button
            {
                Content = label,
                MinWidth = 56,
            };
            keyButton.Click += async (_, _) => await SendTextAsync(text);
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
        Grid.SetRow(controls, 1);
        Grid.SetRow(_status, 2);
        Grid.SetRow(_screenInput, 3);
        Grid.SetRow(keyBar, 4);
        grid.Children.Add(chrome);
        grid.Children.Add(controls);
        grid.Children.Add(_status);
        grid.Children.Add(_screenInput);
        grid.Children.Add(keyBar);
        Content = grid;
        RenderInspector();

        Loaded += async (_, _) => await StartAsync();
        Unloaded += (_, _) =>
        {
            DispatcherQueue.TryEnqueue(async () =>
            {
                try { await CloseAsync(); }
                catch (Exception ex) { Tokenstat.Program.LogStartup(L10n.Text("windows.screenpage.screen_close_0.1e065dda", $"{ex}")); }
            });
        };
    }

    public event Action? ToolbarChanged { add { } remove { } }

    /// <summary>
    /// The machine on the other end of the viewer.
    /// </summary>
    public UIElement? ToolbarScope => Chrome.ScopeChip(_name, Symbol.View);

    public IList<UIElement> ToolbarActions()
    {
        return new List<UIElement>
        {
            Buttons.ToolbarIcon(
                ActionIcon.Done,
                L10n.Text("windows.screenpage.close_the_viewer.fb7de0ec"),
                async (_, _) => await CloseAsync()),
        };
    }

    /// <summary>
    /// The inspector column content: the connection behind the picture.
    /// State changes repaint it, so the column stays live without the shell
    /// asking again.
    /// </summary>
    public UIElement? Inspector => _inspector;

    private void RenderInspector()
    {
        void show()
        {
            _inspector.Children.Clear();
            _inspector.Children.Add(new TextBlock
            {
                Text = _name,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                TextWrapping = TextWrapping.Wrap,
            });
            _inspector.Children.Add(Chrome.InspectorField(
                L10n.Text("windows.screenpage.picture.9a1c54f5"), _streamingSince.HasValue ? L10n.Text("windows.screenpage.streaming.a951c594") : L10n.Text("common.waiting")));
            _inspector.Children.Add(Chrome.InspectorField(L10n.Text("windows.screenpage.route.adc74704"), _transport));
            _inspector.Children.Add(Chrome.InspectorField(L10n.Text("windows.screenpage.quality.1b2c08a8"), QualityLabel(_quality)));
            _inspector.Children.Add(Chrome.InspectorField(
                L10n.Text("windows.screenpage.control.32d7e820"), _control ? L10n.Text("windows.screenpage.controlling.119deec3") : L10n.Text("windows.screenpage.viewing.9dc859e8")));
            if (_displays.Count > 0)
            {
                var selected = _displays.FirstOrDefault(d => d.Id == _selectedDisplay)
                    ?? _displays[0];
                _inspector.Children.Add(Chrome.InspectorField(
                    L10n.Text("windows.screenpage.display.34e108c0"), $"{selected.Name} {selected.Width}x{selected.Height}"));
            }
            if (_dropped > 0)
            {
                _inspector.Children.Add(Chrome.InspectorField(L10n.Text("windows.screenpage.dropped.739f68fe"), $"{_dropped:N0}"));
            }
            if (_reconnects > 0)
            {
                _inspector.Children.Add(Chrome.InspectorField(L10n.Text("windows.screenpage.reconnects.8432cd7f"), $"{_reconnects}"));
            }
        }
        if (DispatcherQueue.HasThreadAccess)
        {
            show();
            return;
        }
        DispatcherQueue.TryEnqueue(show);
    }

    private static string QualityLabel(string wire) => wire switch
    {
        "sharp" => L10n.Text("windows.screenpage.sharp.1a3c4b30"),
        "smooth" => L10n.Text("windows.screenpage.smooth.da519387"),
        "dataSaver" => L10n.Text("windows.screenpage.data_saver.5b444f24"),
        _ => L10n.Text("windows.screenpage.automatic.d461a493"),
    };

    private async Task StartAsync()
    {
        _caption.Text = L10n.Text("windows.screenpage.connecting.72021eb7");
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
            Caption(L10n.Text("windows.screenpage.screen_access_requires_the_legend_plan.66173f1c"));
            Banner(L10n.Text("windows.screenpage.requires_legend.a630be5b"));
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
            Banner(L10n.Text("windows.screenpage.this_pc_has_no_identity_yet.5d41ab41"));
            Caption(L10n.Text("windows.screenpage.this_pc_has_no_identity_yet.5d41ab41"));
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
            throw new InvalidOperationException(L10n.Text("windows.screenpage.the_viewer_opened_without_an_id.9cdf904c"));
        }
        _hostSessionId = Format.Text(opened, "sessionId");
        _transport = Format.Transport(Format.Text(opened, "transport", "relay"));
        _control = control;
        _connectedSince = DateTime.UtcNow;
        _streamingSince = null;
        RefreshControlChip();
        Caption(L10n.Text("windows.screenpage.waiting_for_the_first_picture_0.5068452b", $"{_transport}"));
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
            throw new InvalidOperationException(L10n.Text("windows.screenpage.the_host_did_not_issue_a_capability.b8faa6a5"));
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
                var reason = string.IsNullOrEmpty(error) ? L10n.Text("windows.screenpage.that_computer_stopped_sharing.6289600c") : error;
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
            _dropped = Format.Long(chunk, "dropped");
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
                Caption(L10n.Text("windows.screenpage.connected_but_no_picture_has_arrived_yet_t.388c1e4f"));
                Banner(L10n.Text("windows.screenpage.no_picture_arrived.34793922"));
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
                    Format.Text(item, "name", L10n.Text("windows.screenpage.display.34e108c0")),
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
        var annexB = frame.Payload;
        if (annexB.Length == 0)
        {
            return;
        }
        DispatcherQueue.TryEnqueue(() => PushH264OnUi(frame, annexB));
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

    private void PushH264OnUi(ScreenFrame frame, byte[] annexB)
    {
        if (_closed || !IsLoaded || frame.Width <= 0 || frame.Height <= 0)
        {
            return;
        }
        var width = (uint)frame.Width;
        var height = (uint)frame.Height;
        try
        {
            if (_streamer is null || _streamer.Width != width || _streamer.Height != height)
            {
                if (!frame.Keyframe)
                {
                    // A fresh decoder needs its parameter sets first.
                    return;
                }
                ResetDecoderOnUi();
                var streamer = new H264Streamer(width, height);
                _streamer = streamer;
                var mediaPlayer = new Windows.Media.Playback.MediaPlayer { AutoPlay = true };
                _mediaPlayer = mediaPlayer;
                mediaPlayer.MediaFailed += (_, failure) => DispatcherQueue.TryEnqueue(() =>
                {
                    if (_closed || !ReferenceEquals(_mediaPlayer, mediaPlayer)) return;
                    var detail = L10n.Text("windows.screenpage.0_0x_1_2.b0acbd80", $"{failure.Error}", $"{failure.ExtendedErrorCode?.HResult ?? 0:X8}", $"{failure.ErrorMessage}");
                    Program.LogStartup(L10n.Text("windows.screenpage.screen_decoder_failed_0.69fb566b", $"{detail}"));
                    ResetDecoderOnUi();
                    _streamingSince = null;
                    _connectedSince = DateTime.UtcNow;
                    Caption(L10n.Text("windows.screenpage.waiting_for_a_fresh_video_frame.fd71799a"));
                    Banner(L10n.Text("windows.screenpage.screen_decoder_failed_0.69fb566b", $"{detail}"));
                });
                mediaPlayer.MediaOpened += (_, _) => DispatcherQueue.TryEnqueue(() =>
                {
                    if (!_closed && ReferenceEquals(_mediaPlayer, mediaPlayer))
                    {
                        MarkStreaming();
                        _caption.Visibility = Visibility.Collapsed;
                        _status.Children.Clear();
                    }
                });
                _player.SetMediaPlayer(mediaPlayer);
                mediaPlayer.Source = MediaSource.CreateFromMediaStreamSource(streamer.Source);
                _firstStampUs = frame.TimestampMicroseconds;
                _lastStampTicks = -1;
                _player.MediaPlayer?.Play();
                _player.Visibility = Visibility.Visible;
                _picture.Visibility = Visibility.Collapsed;
                Caption(_dropped > 0
                    ? L10n.Text("windows.screenpage.decoding_h_264_0_1_frames_dropped.aa9134b4", $"{_transport}", $"{_dropped}")
                    : L10n.Text("windows.screenpage.decoding_h_264_0.7e4e49f8", $"{_transport}"));
            }
            var relativeUs = frame.TimestampMicroseconds >= _firstStampUs ? frame.TimestampMicroseconds - _firstStampUs : 0;
            var ticks = (long)Math.Min(relativeUs, (ulong)(long.MaxValue / 10)) * 10;
            ticks = Math.Max(ticks, _lastStampTicks + 1);
            _lastStampTicks = ticks;
            _streamer.Push(annexB, frame.Keyframe, TimeSpan.FromTicks(ticks), frame.Sequence);
        }
        catch (Exception ex)
        {
            ResetDecoderOnUi();
            _picture.Visibility = Visibility.Visible;
            Caption(L10n.Text("windows.screenpage.this_stream_is_h_264_but_the_decoder_could.d8814dd8", $"{ex.Message}"));
            Banner(L10n.Text("windows.screenpage.the_h_264_decoder_could_not_start_0.6d16f925", $"{ex.Message}"));
        }
    }

    private void ShowStillOnUi(byte[] bytes)
    {
        if (_closed || !IsLoaded) return;
        ResetDecoderOnUi();
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
            if (_closed || !IsLoaded) return;
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
            if (_closed) return;
            ResetDecoderOnUi();
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
            Caption(L10n.Text("windows.screenpage.connection_could_not_recover_0.7c8ca1d2", $"{reason}"));
            Banner(reason);
            return;
        }
        Caption(L10n.Text("windows.screenpage.reconnecting_attempt_0_of_3_1.8f4f26ac", $"{_reconnects}", $"{reason}"));
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

    private void ResetDecoderOnUi()
    {
        var previous = _mediaPlayer;
        _mediaPlayer = null;
        // Detach the player before disposal so XAML cannot call a closed COM object.
        _player.SetMediaPlayer(null);
        _streamer?.Close();
        _streamer = null;
        if (previous is not null) { previous.Source = null; previous.Dispose(); }
        _player.Visibility = Visibility.Collapsed;
    }

    private async Task CloseAsync()
    {
        if (_closed) return;
        _closed = true;
        _heartbeat?.Stop();
        _heartbeat = null;
        ResetDecoderOnUi();
        await CloseViewerAsync();
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
        var button = properties.IsRightButtonPressed ? 1
            : properties.IsMiddleButtonPressed ? 2 : 0;
        _screenInput.Focus(FocusState.Pointer);
        _stage.CapturePointer(e.Pointer);
        _pressedButton = button;
        _ = SendEventAsync(new JsonObject
        {
            ["type"] = "mouse",
            ["down"] = true,
            ["x"] = x,
            ["y"] = y,
            ["button"] = button,
            ["clickCount"] = count,
        });
    }

    private void ReleasePointer()
    {
        if (_pressedButton is not int button) return;
        _pressedButton = null;
        _ = SendEventAsync(new JsonObject { ["type"] = "mouse", ["button"] = button,
            ["down"] = false, ["x"] = _cursorX, ["y"] = _cursorY });
    }

    private void ForwardKey(KeyRoutedEventArgs e, bool down)
    {
        if (!_control || ScreenKeys.MacCode((int)e.Key) is not int code) return;
        e.Handled = true;
        if (down) _pressedKeys.Add(code); else _pressedKeys.Remove(code);
        ulong flags = 0;
        bool Held(Windows.System.VirtualKey key) => Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(key)
            .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        if (Held(Windows.System.VirtualKey.Shift)) flags |= 1UL << 17;
        if (Held(Windows.System.VirtualKey.Control)) flags |= 1UL << 18;
        if (Held(Windows.System.VirtualKey.Menu)) flags |= 1UL << 19;
        if (Held(Windows.System.VirtualKey.LeftWindows) || Held(Windows.System.VirtualKey.RightWindows)) flags |= 1UL << 20;
        _ = SendEventAsync(new JsonObject { ["type"] = "key", ["keyCode"] = code, ["down"] = down, ["flags"] = flags });
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
        if (Normalize(e) is not { } point) return;
        var properties = e.GetCurrentPoint(_stage).Properties;
        _ = SendEventAsync(new JsonObject
        {
            ["type"] = "scroll",
            ["x"] = point.x,
            ["y"] = point.y,
            ["dx"] = properties.IsHorizontalMouseWheel ? properties.MouseWheelDelta : 0,
            ["dy"] = properties.IsHorizontalMouseWheel ? 0 : properties.MouseWheelDelta,
        });
    }

    private (double x, double y)? Normalize(PointerRoutedEventArgs e)
    {
        var position = e.GetCurrentPoint(_stage).Position;
        var bitmap = _picture.Source as BitmapSource;
        var width = _streamer?.Width ?? (uint)(bitmap?.PixelWidth ?? 0);
        var height = _streamer?.Height ?? (uint)(bitmap?.PixelHeight ?? 0);
        return ScreenViewport.Normalize(position.X, position.Y, _stage.ActualWidth, _stage.ActualHeight,
            width, height, _pressedButton is not null);
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

    private async Task SendDisplayAsync(uint id)
    {
        _selectedDisplay = id;
        await SendEventAsync(new JsonObject
        {
            ["type"] = "display",
            ["id"] = JsonValue.Create(id),
        });
    }

    private async Task SendEventAsync(JsonObject evt)
    {
        var id = _sessionId;
        var kind = Format.Text(evt, "type");
        if (_closed || string.IsNullOrEmpty(id) || (!_control && kind != "display")) return;
        var data = Convert.ToBase64String(Encoding.UTF8.GetBytes(evt.ToJsonString()));
        // Preserve press/release order even when the transport yields between writes.
        await _inputGate.WaitAsync();
        try
        {
            if (_closed || id != _sessionId) return;
            await AppServices.Host.CallAsync("screen.viewer.input", new JsonObject
            { ["id"] = id, ["data"] = data });
        }
        catch (Exception ex) { if (!_closed) Banner(FriendlyError.Display(ex.Message)); }
        finally { _inputGate.Release(); }
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
                Caption(wanted ? L10n.Text("windows.screenpage.controlling_0.711cd5d9", $"{_name}") : _name);
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
            _controlSlot.Children.Add(Chrome.ToggleChip(L10n.Text("windows.screenpage.control.32d7e820"), _control, SetControlAsync));
            RenderInspector();
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
                    ("auto", L10n.Text("windows.screenpage.automatic.d461a493")),
                    ("sharp", L10n.Text("windows.screenpage.sharp.1a3c4b30")),
                    ("smooth", L10n.Text("windows.screenpage.smooth.da519387")),
                    ("dataSaver", L10n.Text("windows.screenpage.data_saver.5b444f24")),
                },
                _quality,
                SetQualityAsync));
            RenderInspector();
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
            RenderInspector();
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
        RenderInspector();
    }

    private void ResetPictureOnUi()
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            if (_closed) return;
            ResetDecoderOnUi();
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
            _caption.Visibility = Visibility.Visible;
            RenderInspector();
            return;
        }
        DispatcherQueue.TryEnqueue(() =>
        {
            _caption.Text = text;
            _caption.Visibility = Visibility.Visible;
            RenderInspector();
        });
    }

    private sealed record ScreenDisplay(uint Id, string Name, int Width, int Height);
}
