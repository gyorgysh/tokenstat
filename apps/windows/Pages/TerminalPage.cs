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
        Loaded += async (_, _) =>
        {
            _folderName = await FolderNameAsync();
            RaiseToolbarChanged();
            await StartAsync();
        };
        Unloaded += (_, _) => { Stop(); _terminal.Close(); };
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

    private int CurrentRows() => _terminal.Rows;
    private int CurrentCols() => _terminal.Cols;

    private async Task StartAsync()
    {
        try { await _terminal.Ready; }
        catch (Exception ex) { Banner("Terminal could not open: " + ex.Message); return; }
        if (!IsLoaded) return;
        _session.Output += Append;
        _session.Changed += Refresh;
        try { await _session.AttachAsync(CurrentRows(), CurrentCols()); }
        catch (Exception ex) { if (IsLoaded) Banner(ex.Message); return; }
        if (!IsLoaded) { await _session.DetachAsync(); return; }
        _loaded = true;
        await _session.ResizeAsync(CurrentRows(), CurrentCols());
        RefreshOnUi();
        _terminal.FocusTerminal();
    }

    private void Stop()
    {
        _loaded = false;
        _session.Output -= Append;
        _session.Changed -= Refresh;
        _ = _session.DetachAsync();
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
        var label = string.IsNullOrEmpty(_session.Command) ? "Shell" : _session.Command;
        _startTitle.Text = "Starting " + StartingLabel();
        // Up but not painted yet: agent CLIs spend seconds in that gap. A
        // failed spawn or an exited process shows its banner instead.
        _startOverlay.Visibility = !_session.HasOutput && _session.Alive && !_session.Closed
            && string.IsNullOrEmpty(_session.LastError)
            ? Visibility.Visible
            : Visibility.Collapsed;
        _title.Text = StartingLabel();
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
            return tail;
        }
        return id.Length <= 6 ? id : id[^6..];
    }

    private void Banner(string text)
    {
        _status.Children.Add(Chrome.Banner(text, Theme.Danger, Symbol.Important));
    }
}
