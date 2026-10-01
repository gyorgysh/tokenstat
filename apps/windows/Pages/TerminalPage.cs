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
using Windows.Foundation;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Tokenstat.Design;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;
using Windows.UI;
using Windows.UI.Core;

namespace Tokenstat.Pages;

/// <summary>
/// A VT terminal shared by local and remote PTY sessions. The session outlives
/// the page, so navigating back reattaches to the running shell.
/// </summary>
internal sealed class TerminalPage : Page, IInspectorContent, IToolbarItems
{
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
    private readonly TerminalSurface _terminal = new();
    /// <summary>
    /// The spawn-to-first-paint cover over the scroll area: the session is
    /// up while the program has not drawn yet. Its shade is the pane
    /// surface, the same number the cells use, so no seam shows while it is
    /// up or when it lifts.
    /// </summary>
    private readonly Grid _startOverlay = new();
    private readonly TextBlock _startTitle = new();
    private bool _loaded;
    private bool _released;
    private int _generation;
    private readonly SemaphoreSlim _lifecycle = new(1, 1);
    private Window? _window;
    private readonly TypedEventHandler<object, WindowEventArgs> _windowClosed;
    internal string TabTitle => StartingLabel();

    public TerminalPage(string workspaceId, string? sessionId)
    {
        _workspaceId = workspaceId;
        _session = TerminalSession.For(workspaceId, sessionId);
        var dark = Theme.IsDark;
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
            Text = L10n.Text("windows.terminalpage.the_session_is_up_waiting_for_the_program.2a36333d"),
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

        _kill = Buttons.ToolbarIcon(ActionIcon.Stop, L10n.Text("windows.terminalpage.kill_the_process.9e42d840"), async (_, _) => await _session.KillAsync());
        _close = Buttons.ToolbarIcon(ActionIcon.Disconnect, L10n.Text("windows.terminalpage.close_this_session.fa2af1b6"), async (_, _) => await _session.CloseAsync());
        _respawn = Buttons.ToolbarIcon(ActionIcon.Refresh, L10n.Text("windows.terminalpage.start_a_fresh_shell.337e23dd"), async (_, _) =>
        {
            _terminal.Reset();
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
        termHost.Children.Add(_terminal);
        termHost.Children.Add(_startOverlay);
        Grid.SetRow(termHost, 2);
        grid.Children.Add(chrome);
        grid.Children.Add(_status);
        grid.Children.Add(termHost);
        Content = grid;
        RenderInspector();

        _terminal.Input = bytes => _session.WriteAsync(bytes);
        _terminal.Resized = (rows, cols) => _loaded ? _session.ResizeAsync(rows, cols) : Task.CompletedTask;
        _terminal.Failed += Banner;
        _windowClosed = (_, _) => Release();
        Loaded += async (_, _) =>
        {
            if (_released) return;
            _terminal.PrepareForReuse();
            var generation = ++_generation;
            _folderName = await FolderNameAsync();
            if (generation != _generation || !IsLoaded || _released) return;
            RaiseToolbarChanged();
            await StartAsync(generation);
        };
        Unloaded += (_, _) =>
        {
            if (_released) return;
            Stop();
            _terminal.Close();
        };
        if (App.CurrentWindow is { } window)
        {
            _window = window;
            window.Closed += _windowClosed;
        }
    }

    internal void Release()
    {
        if (_released) return;
        _released = true;
        Stop();
        _terminal.Close();
        if (_window is not null)
        {
            _window.Closed -= _windowClosed;
            _window = null;
        }
    }

    public event Action? ToolbarChanged;

    /// <summary>
    /// The folder this shell runs in.
    /// </summary>
    public UIElement? ToolbarScope =>
        Chrome.ScopeChip(string.IsNullOrEmpty(_folderName) ? L10n.Text("windows.terminalpage.terminal.e0926fda") : _folderName);

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
        var label = string.IsNullOrEmpty(_session.Command) ? L10n.Text("windows.terminalpage.shell.a7332854") : _session.Command;
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
        var state = _session.Closed ? L10n.Text("windows.terminalpage.closed.c21ead06")
            : !_session.Alive ? L10n.Text("windows.terminalpage.exited.85fc46c1")
            : L10n.Text("common.running");
        _inspector.Children.Add(Chrome.InspectorField(L10n.Text("windows.terminalpage.state.a3b50c47"), state));
        if (_session.ExitCode.HasValue)
        {
            _inspector.Children.Add(Chrome.InspectorField(L10n.Text("windows.terminalpage.exit_status.f69b3d7f"), $"{_session.ExitCode}"));
        }
        _inspector.Children.Add(Chrome.InspectorField(L10n.Text("windows.terminalpage.size.1af85190"), $"{_session.Cols}×{_session.Rows}"));
        if (_session.Paused)
        {
            _inspector.Children.Add(new TextBlock
            {
                Text = L10n.Text("windows.terminalpage.output_is_paused_while_the_handoff_window.23f0e74c"),
                Opacity = 0.7,
                TextWrapping = TextWrapping.Wrap,
            });
        }
        if (_session.Dropped > 0)
        {
            _inspector.Children.Add(Chrome.InspectorField(L10n.Text("windows.terminalpage.dropped.739f68fe"), $"{_session.Dropped:N0}"));
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

    private int CurrentRows() => _terminal.Rows;
    private int CurrentCols() => _terminal.Cols;

    private async Task StartAsync(int generation)
    {
        await _lifecycle.WaitAsync();
        try
        {
            await _terminal.Ready;
            if (generation != _generation || !IsLoaded) return;
            _terminal.Reset();
            _session.Output += Append;
            _session.Changed += Refresh;
            await _session.AttachAsync(CurrentRows(), CurrentCols());
            if (generation != _generation || !IsLoaded) return;
            _loaded = true;
            await _session.ResizeAsync(CurrentRows(), CurrentCols());
            RefreshOnUi();
            _terminal.FocusTerminal();
        }
        catch (Exception ex) { if (generation == _generation && IsLoaded) Banner(ex.Message); }
        finally { _lifecycle.Release(); }
    }

    private void Stop()
    {
        ++_generation;
        _loaded = false;
        _session.Output -= Append;
        _session.Changed -= Refresh;
        _ = DetachAsync();
    }

    private async Task DetachAsync()
    {
        await _lifecycle.WaitAsync();
        try { await _session.DetachAsync(); }
        finally { _lifecycle.Release(); }
    }

    private void Append(byte[] bytes)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            if (!IsLoaded) return;
            _terminal.Write(bytes);
            _startOverlay.Visibility = Visibility.Collapsed;
        });
    }

    private void Refresh() => DispatcherQueue.TryEnqueue(RefreshOnUi);

    private void RefreshOnUi()
    {
        var label = string.IsNullOrEmpty(_session.Command) ? L10n.Text("windows.terminalpage.shell.a7332854") : _session.Command;
        _startTitle.Text = L10n.Text("windows.terminalpage.starting_0.099752ea", $"{StartingLabel()}");
        // Up but not painted yet: agent CLIs spend seconds in that gap. A
        // failed spawn or an exited process shows its banner instead.
        _startOverlay.Visibility = !_session.HasOutput && _session.Alive && !_session.Closed
            && string.IsNullOrEmpty(_session.LastError)
            ? Visibility.Visible
            : Visibility.Collapsed;
        var title = StartingLabel();
        if (_title.Text != title) { _title.Text = title; RaiseToolbarChanged(); }
        _size.Text = $"{_session.Cols}×{_session.Rows}";
        _terminal.SetGeometry(_session.Rows, _session.Cols);
        _kill.IsEnabled = _session.Alive && !_session.Closed;
        _close.IsEnabled = !_session.Closed;
        _respawn.Visibility = (!_session.Alive || _session.Closed)
            ? Visibility.Visible
            : Visibility.Collapsed;

        _status.Children.Clear();
        if (_session.Closed)
        {
            Banner(L10n.Text("windows.terminalpage.the_session_was_closed_respawn_starts_a_fr.0ebaaba6"));
        }
        else if (!_session.Alive)
        {
            Banner(_session.ExitCode.HasValue
                ? L10n.Text("windows.terminalpage.the_process_exited_with_status_0.25dad567", $"{_session.ExitCode}")
                : L10n.Text("windows.terminalpage.the_process_exited.fd45b6ed"));
        }
        if (_session.Paused)
        {
            Banner(L10n.Text("windows.terminalpage.tokenstat_paused_output_because_the_handof.1e2648f2"));
        }
        if (_session.Dropped > 0)
        {
            Banner(L10n.Text("windows.terminalpage.some_output_was_dropped_while_catching_up.dc39823b"));
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
        if (new[] { L10n.Text("windows.terminalpage.exe.e42f3ea0"), L10n.Text("windows.terminalpage.cmd.4ec29444"), L10n.Text("windows.terminalpage.bat.e23b5839") }.Any(extension => command.EndsWith(extension, StringComparison.OrdinalIgnoreCase)))
        {
            command = command[..^4];
        }
        return string.IsNullOrEmpty(command) ? L10n.Text("windows.terminalpage.shell.a7332854") : command;
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
            return tail;
        }
        return id.Length <= 6 ? id : id[^6..];
    }

    private void Banner(string text)
    {
        _status.Children.Add(Chrome.Banner(text, Theme.Danger, Symbol.Important));
    }
}
