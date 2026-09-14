// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Text;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Tokenstat.Design;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;
using Windows.UI;
using Windows.UI.Core;

namespace Tokenstat.Pages;

/// <summary>
/// A ConPTY-backed terminal over the full pty host set. The input box is a
/// key forwarder, not a line editor: printable text goes out as typed and
/// control and navigation keys are translated to VT sequences, so
/// full-screen programs work. The session outlives the page, so navigating
/// away and back reattaches to the same shell.
/// </summary>
internal sealed class TerminalPage : Page
{
    internal const int BufferCap = 200_000;

    private const double CellWidth = 8.0;
    private const double CellHeight = 17.0;

    private readonly TerminalSession _session;
    private readonly StackPanel _status = new() { Spacing = Theme.SpaceS };
    private readonly TextBlock _title = new()
    {
        VerticalAlignment = VerticalAlignment.Center,
        FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
    };
    private readonly TextBlock _size = new()
    {
        VerticalAlignment = VerticalAlignment.Center,
        Opacity = 0.7,
    };
    private readonly Button _kill;
    private readonly Button _close;
    private readonly Button _respawn;
    private readonly TextBlock _view = new()
    {
        FontFamily = Fonts.Mono,
        FontSize = 13,
        TextWrapping = TextWrapping.Wrap,
        IsTextSelectionEnabled = true,
    };
    private readonly ScrollViewer _scroll = new()
    {
        Padding = new Thickness(Theme.SpaceS),
    };
    private readonly TextBox _input = new()
    {
        PlaceholderText = "Type here. Keys go straight to the shell.",
        FontFamily = Fonts.Mono,
    };

    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _resizeTimer;
    private bool _muted;
    private bool _loaded;

    public TerminalPage(string workspaceId, string? sessionId)
    {
        _session = TerminalSession.For(workspaceId, sessionId);
        var dark = Theme.IsDark;
        _view.Foreground = new SolidColorBrush(TerminalPalette.Foreground(dark));
        _scroll.Background = new SolidColorBrush(TerminalPalette.Background(dark));

        _kill = ActionIconGlyph.Button("Kill", ActionIcon.Stop, async (_, _) => await _session.KillAsync());
        _close = ActionIconGlyph.Button("Close", ActionIcon.Disconnect, async (_, _) => await _session.CloseAsync());
        _respawn = ActionIconGlyph.Button("Respawn", ActionIcon.Refresh, async (_, _) =>
        {
            await _session.RespawnAsync(CurrentRows(), CurrentCols());
        });

        var chrome = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Theme.SpaceS,
            Padding = new Thickness(Theme.SpaceS),
        };
        chrome.Children.Add(_kill);
        chrome.Children.Add(_close);
        chrome.Children.Add(_respawn);
        chrome.Children.Add(_title);
        chrome.Children.Add(_size);

        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Grid.SetRow(_status, 1);
        Grid.SetRow(_scroll, 2);
        Grid.SetRow(_input, 3);
        _scroll.Content = _view;
        grid.Children.Add(chrome);
        grid.Children.Add(_status);
        grid.Children.Add(_scroll);
        grid.Children.Add(_input);
        Content = grid;

        _resizeTimer = DispatcherQueue.CreateTimer();
        _resizeTimer.Interval = TimeSpan.FromMilliseconds(400);
        _resizeTimer.Tick += (_, _) =>
        {
            _resizeTimer.Stop();
            _ = _session.ResizeAsync(CurrentRows(), CurrentCols());
        };
        _scroll.SizeChanged += (_, _) =>
        {
            if (!_loaded)
            {
                return;
            }
            _resizeTimer.Stop();
            _resizeTimer.Start();
        };

        _input.KeyDown += InputOnKeyDown;
        _input.TextChanged += InputOnTextChanged;
        Loaded += async (_, _) => await StartAsync();
        Unloaded += (_, _) => Stop();
    }

    private int CurrentRows()
    {
        var height = _scroll.ActualHeight - Theme.SpaceS * 2;
        return (int)Math.Floor(height / CellHeight);
    }

    private int CurrentCols()
    {
        var width = _scroll.ActualWidth - Theme.SpaceS * 2;
        return (int)Math.Floor(width / CellWidth);
    }

    private async Task StartAsync()
    {
        _session.Output += Append;
        _session.Changed += Refresh;
        await _session.AttachAsync(CurrentRows(), CurrentCols());
        _loaded = true;
        RefreshOnUi();
        _input.Focus(FocusState.Programmatic);
    }

    private void Stop()
    {
        _loaded = false;
        _resizeTimer.Stop();
        _session.Output -= Append;
        _session.Changed -= Refresh;
        _ = _session.DetachAsync();
    }

    private void Append(string text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return;
        }
        DispatcherQueue.TryEnqueue(() =>
        {
            var combined = _view.Text + text;
            if (combined.Length > BufferCap)
            {
                combined = combined[(combined.Length - (BufferCap - 20_000))..];
            }
            _view.Text = combined;
            _scroll.UpdateLayout();
            _scroll.ChangeView(null, _scroll.ExtentHeight, null);
        });
    }

    private void Refresh() => DispatcherQueue.TryEnqueue(RefreshOnUi);

    private void RefreshOnUi()
    {
        var label = string.IsNullOrEmpty(_session.Command) ? "Shell" : _session.Command;
        _title.Text = $"{label} · {ShortId(_session.Id)}";
        _size.Text = $"{_session.Cols}×{_session.Rows}";
        _kill.IsEnabled = _session.Alive && !_session.Closed;
        _close.IsEnabled = !_session.Closed;
        _respawn.Visibility = (!_session.Alive || _session.Closed)
            ? Visibility.Visible
            : Visibility.Collapsed;

        _status.Children.Clear();
        if (_session.Closed)
        {
            Banner("The session was closed. Respawn starts a fresh shell.");
        }
        else if (!_session.Alive)
        {
            Banner(_session.ExitCode.HasValue
                ? $"The process exited with status {_session.ExitCode}."
                : "The process exited.");
        }
        if (_session.Paused)
        {
            Banner("The host paused output because the handoff window is full. It resumes on its own.");
        }
        if (_session.Dropped > 0)
        {
            Banner("Some output was dropped while catching up.");
        }
        if (!string.IsNullOrEmpty(_session.LastError) && _session.Alive && !_session.Closed)
        {
            Banner(_session.LastError);
        }
    }

    private static string ShortId(string id)
    {
        if (id.StartsWith("remote:", StringComparison.Ordinal))
        {
            var rest = id["remote:".Length..];
            var cut = rest.IndexOf(':');
            var peer = cut < 0 ? rest : rest[..cut];
            var inner = cut < 0 ? "" : rest[(cut + 1)..];
            var tail = inner.Length <= 6 ? inner : inner[^6..];
            return $"{peer}:{tail}";
        }
        return id.Length <= 6 ? id : id[^6..];
    }

    private async void InputOnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (await TryPasteAsync(e))
        {
            e.Handled = true;
            return;
        }
        var bytes = TranslateKey(e);
        if (bytes is null)
        {
            return;
        }
        e.Handled = true;
        await _session.WriteAsync(bytes);
    }

    private async void InputOnTextChanged(object sender, TextChangedEventArgs e)
    {
        if (_muted)
        {
            return;
        }
        var text = _input.Text ?? "";
        if (text.Length == 0)
        {
            return;
        }
        _muted = true;
        _input.Text = "";
        _muted = false;
        await _session.WriteAsync(Encoding.UTF8.GetBytes(text));
    }

    private static bool ControlDown() =>
        (InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control) & CoreVirtualKeyStates.Down)
        == CoreVirtualKeyStates.Down;

    private static bool ShiftDown() =>
        (InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift) & CoreVirtualKeyStates.Down)
        == CoreVirtualKeyStates.Down;

    private static bool AltDown() =>
        (InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Menu) & CoreVirtualKeyStates.Down)
        == CoreVirtualKeyStates.Down;

    private async Task<bool> TryPasteAsync(KeyRoutedEventArgs e)
    {
        var paste = (ControlDown() && e.Key == VirtualKey.V)
            || (ShiftDown() && e.Key == VirtualKey.Insert);
        if (!paste)
        {
            return false;
        }
        try
        {
            var content = Clipboard.GetContent();
            if (content.Contains(StandardDataFormats.Text))
            {
                var text = await content.GetTextAsync();
                await _session.WriteAsync(Encoding.UTF8.GetBytes(text));
            }
        }
        catch
        {
            // A denied clipboard must not kill the session.
        }
        return true;
    }

    /// <summary>
    /// Control and navigation keys as VT sequences. Printable text returns
    /// null and goes out through the text change path as typed.
    /// </summary>
    private static byte[]? TranslateKey(KeyRoutedEventArgs e)
    {
        if (e.Key is VirtualKey.Control or VirtualKey.Shift or VirtualKey.Menu
            or VirtualKey.LeftWindows or VirtualKey.RightWindows)
        {
            return null;
        }
        var ctrl = ControlDown();
        var alt = AltDown();
        if (ctrl && e.Key >= VirtualKey.A && e.Key <= VirtualKey.Z)
        {
            return [(byte)((int)e.Key - (int)VirtualKey.A + 1)];
        }
        byte[]? special = e.Key switch
        {
            VirtualKey.Enter => [(byte)'\r'],
            VirtualKey.Escape => [(byte)'\x1b'],
            VirtualKey.Tab => [(byte)'\t'],
            VirtualKey.Back => [(byte)'\x7f'],
            VirtualKey.Up => "\x1b[A"u8.ToArray(),
            VirtualKey.Down => "\x1b[B"u8.ToArray(),
            VirtualKey.Right => "\x1b[C"u8.ToArray(),
            VirtualKey.Left => "\x1b[D"u8.ToArray(),
            VirtualKey.Home => "\x1b[H"u8.ToArray(),
            VirtualKey.End => "\x1b[F"u8.ToArray(),
            VirtualKey.PageUp => "\x1b[5~"u8.ToArray(),
            VirtualKey.PageDown => "\x1b[6~"u8.ToArray(),
            VirtualKey.Insert => "\x1b[2~"u8.ToArray(),
            VirtualKey.Delete => "\x1b[3~"u8.ToArray(),
            VirtualKey.F1 => "\x1bOP"u8.ToArray(),
            VirtualKey.F2 => "\x1bOQ"u8.ToArray(),
            VirtualKey.F3 => "\x1bOR"u8.ToArray(),
            VirtualKey.F4 => "\x1bOS"u8.ToArray(),
            VirtualKey.F5 => "\x1b[15~"u8.ToArray(),
            VirtualKey.F6 => "\x1b[17~"u8.ToArray(),
            VirtualKey.F7 => "\x1b[18~"u8.ToArray(),
            VirtualKey.F8 => "\x1b[19~"u8.ToArray(),
            VirtualKey.F9 => "\x1b[20~"u8.ToArray(),
            VirtualKey.F10 => "\x1b[21~"u8.ToArray(),
            VirtualKey.F11 => "\x1b[23~"u8.ToArray(),
            VirtualKey.F12 => "\x1b[24~"u8.ToArray(),
            _ => null,
        };
        if (special is not null)
        {
            return special;
        }
        if (alt && e.Key >= VirtualKey.A && e.Key <= VirtualKey.Z)
        {
            var letter = (char)('a' + ((int)e.Key - (int)VirtualKey.A));
            if (ShiftDown())
            {
                letter = char.ToUpperInvariant(letter);
            }
            return Encoding.UTF8.GetBytes("\x1b" + letter);
        }
        return null;
    }

    private void Banner(string text)
    {
        _status.Children.Add(Chrome.Banner(text, Theme.Danger, Symbol.Important));
    }
}
