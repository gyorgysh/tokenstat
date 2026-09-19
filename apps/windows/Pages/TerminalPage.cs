// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Text;
using System.Text.Json.Nodes;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Input;
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
internal sealed class TerminalPage : Page, IInspectorContent, IToolbarItems
{
    internal const int BufferCap = 200_000;

    private const double CellWidth = 8.0;
    private const double CellHeight = 17.0;

    private readonly string _workspaceId;
    private readonly StackPanel _inspector = new()
    {
        Spacing = Theme.SpaceM,
        Padding = new Thickness(Theme.SpaceM),
    };
    private readonly TerminalSession _session;
    private string _folderName = "";
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
    /// <summary>
    /// The spawn-to-first-paint cover over the scroll area: the session is
    /// up while the program has not drawn yet. Its shade is the pane
    /// surface, the same number the cells use, so no seam shows while it is
    /// up or when it lifts.
    /// </summary>
    private readonly Grid _startOverlay = new();
    private readonly TextBlock _startTitle = new();
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
        _workspaceId = workspaceId;
        _session = TerminalSession.For(workspaceId, sessionId);
        var dark = Theme.IsDark;
        _view.Foreground = new SolidColorBrush(TerminalPalette.Foreground(dark));
        _scroll.Background = new SolidColorBrush(TerminalPalette.Background(dark));
        _startTitle.FontSize = 20;
        _startTitle.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
        _startTitle.Foreground = new SolidColorBrush(TerminalPalette.Foreground(dark));
        _startTitle.HorizontalAlignment = HorizontalAlignment.Center;
        _startTitle.TextAlignment = TextAlignment.Center;
        _startTitle.TextWrapping = TextWrapping.Wrap;
        var startBody = new StackPanel
        {
            Spacing = Theme.SpaceM,
            VerticalAlignment = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        startBody.Children.Add(new ProgressRing
        {
            IsActive = true,
            Width = 32,
            Height = 32,
            HorizontalAlignment = HorizontalAlignment.Center,
        });
        startBody.Children.Add(_startTitle);
        startBody.Children.Add(new TextBlock
        {
            Text = "The session is up. Waiting for the program to draw.",
            FontSize = 13,
            Opacity = 0.7,
            MaxWidth = 360,
            Foreground = new SolidColorBrush(TerminalPalette.Foreground(dark)),
            HorizontalAlignment = HorizontalAlignment.Center,
            TextAlignment = TextAlignment.Center,
            TextWrapping = TextWrapping.Wrap,
        });
        _startOverlay.Background = new SolidColorBrush(TerminalPalette.Surface(dark));
        _startOverlay.Children.Add(startBody);

        _kill = Buttons.ToolbarIcon(ActionIcon.Stop, "Kill the process", async (_, _) => await _session.KillAsync());
        _close = Buttons.ToolbarIcon(ActionIcon.Disconnect, "Close this session", async (_, _) => await _session.CloseAsync());
        _respawn = Buttons.ToolbarIcon(ActionIcon.Refresh, "Start a fresh shell", async (_, _) =>
        {
            await _session.RespawnAsync(CurrentRows(), CurrentCols());
        });

        var chrome = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Theme.SpaceS,
            Padding = new Thickness(Theme.SpaceS),
        };
        chrome.Children.Add(_title);
        chrome.Children.Add(_size);

        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Grid.SetRow(_status, 1);
        var termHost = new Grid();
        termHost.Children.Add(_scroll);
        termHost.Children.Add(_startOverlay);
        Grid.SetRow(termHost, 2);
        Grid.SetRow(_input, 3);
        _scroll.Content = _view;
        grid.Children.Add(chrome);
        grid.Children.Add(_status);
        grid.Children.Add(termHost);
        grid.Children.Add(_input);
        Content = grid;
        RenderInspector();

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
        Loaded += async (_, _) =>
        {
            _folderName = await FolderNameAsync();
            RaiseToolbarChanged();
            await StartAsync();
        };
        Unloaded += (_, _) => Stop();
    }

    public event Action? ToolbarChanged;

    /// <summary>
    /// The folder this shell runs in.
    /// </summary>
    public UIElement? ToolbarScope =>
        Chrome.ScopeChip(string.IsNullOrEmpty(_folderName) ? "Terminal" : _folderName);

    /// <summary>
    /// Kill, close, and respawn. The same buttons the page holds, so session
    /// state keeps driving their enabled marks from one place.
    /// </summary>
    public IList<UIElement> ToolbarActions() => new List<UIElement> { _kill, _close, _respawn };

    private void RaiseToolbarChanged() => ToolbarChanged?.Invoke();

    /// <summary>
    /// The inspector column content: what this shell is and how it is doing.
    /// Session changes repaint it, so the column stays live without the shell
    /// asking again.
    /// </summary>
    public UIElement? Inspector => _inspector;

    private void RenderInspector()
    {
        _inspector.Children.Clear();
        var label = string.IsNullOrEmpty(_session.Command) ? "Shell" : _session.Command;
        _inspector.Children.Add(new TextBlock
        {
            Text = label,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
        });
        _inspector.Children.Add(new TextBlock
        {
            Text = ShortId(_session.Id),
            FontFamily = Fonts.Mono,
            FontSize = 12,
            Opacity = 0.7,
        });
        var state = _session.Closed ? "Closed"
            : !_session.Alive ? "Exited"
            : "Running";
        _inspector.Children.Add(Chrome.InspectorField("State", state));
        if (_session.ExitCode.HasValue)
        {
            _inspector.Children.Add(Chrome.InspectorField("Exit status", $"{_session.ExitCode}"));
        }
        _inspector.Children.Add(Chrome.InspectorField("Size", $"{_session.Cols}×{_session.Rows}"));
        if (_session.Paused)
        {
            _inspector.Children.Add(new TextBlock
            {
                Text = "Output is paused while the handoff window is full. It resumes on its own.",
                Opacity = 0.7,
                TextWrapping = TextWrapping.Wrap,
            });
        }
        if (_session.Dropped > 0)
        {
            _inspector.Children.Add(Chrome.InspectorField("Dropped", $"{_session.Dropped:N0}"));
        }
    }

    private async Task<string> FolderNameAsync()
    {
        try
        {
            var listed = await AppServices.Host.CallAsync("workspace.list");
            var array = listed as JsonArray ?? listed["workspaces"] as JsonArray;
            if (array is not null)
            {
                foreach (var folder in array)
                {
                    if (Format.Text(folder, "id") == _workspaceId)
                    {
                        return Format.Text(folder, "name", Format.Text(folder, "path", _workspaceId));
                    }
                }
            }
        }
        catch
        {
        }
        return "";
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
            // First paint lifts the cover at once rather than waiting for
            // the next session change to repaint.
            _startOverlay.Visibility = Visibility.Collapsed;
        });
    }

    private void Refresh() => DispatcherQueue.TryEnqueue(RefreshOnUi);

    private void RefreshOnUi()
    {
        var label = string.IsNullOrEmpty(_session.Command) ? "Shell" : _session.Command;
        _startTitle.Text = "Starting " + StartingLabel();
        // Up but not painted yet: agent CLIs spend seconds in that gap. A
        // failed spawn or an exited process shows its banner instead.
        _startOverlay.Visibility = !_session.HasOutput && _session.Alive && !_session.Closed
            && string.IsNullOrEmpty(_session.LastError)
            ? Visibility.Visible
            : Visibility.Collapsed;
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
        RenderInspector();
    }

    /// <summary>
    /// What the starting cover names: the program's own file name without
    /// its extension, or a shell when the host has not said yet.
    /// </summary>
    private string StartingLabel()
    {
        var command = (_session.Command ?? "").Replace('\\', '/');
        var cut = command.LastIndexOf('/');
        if (cut >= 0)
        {
            command = command[(cut + 1)..];
        }
        if (command.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
        {
            command = command[..^4];
        }
        return string.IsNullOrEmpty(command) ? "Shell" : command;
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
