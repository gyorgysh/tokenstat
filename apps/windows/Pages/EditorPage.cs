// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Tokenstat.Design;
using Windows.System;
using Windows.UI.Text;

namespace Tokenstat.Pages;

/// <summary>
/// Workspace file editor: a file tree, tabs, syntax colour from the host
/// highlight service, find and replace, and saves that re-read before
/// writing. Matches the Mac editor: dirty is the difference between the
/// buffer and the last saved text, a host file that moved while the draft
/// was dirty raises a conflict card, and saving stays off until a copy is
/// chosen.
/// </summary>
internal sealed class EditorPage : Page
{
    private readonly string _workspaceId;
    private readonly StackPanel _tree = new() { Spacing = Theme.SpaceXs };
    private readonly TextBlock _treeCrumb = new() { Opacity = 0.7 };
    private readonly StackPanel _pageStatus = new() { Spacing = Theme.SpaceS };
    private readonly TabView _tabs = new() { IsAddTabButtonVisible = false };
    private readonly List<EditorTab> _open = [];
    private string _directory = "";

    public EditorPage(string workspaceId)
    {
        _workspaceId = workspaceId;

        var files = new Grid { MinWidth = 240, MaxWidth = 320 };
        files.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        files.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        files.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var filesTitle = new TextBlock
        {
            Text = "Files",
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        };
        var treeList = new ScrollViewer { Content = _tree };
        Grid.SetRow(filesTitle, 0);
        Grid.SetRow(_treeCrumb, 1);
        Grid.SetRow(treeList, 2);
        files.Children.Add(filesTitle);
        files.Children.Add(_treeCrumb);
        files.Children.Add(treeList);

        var editor = new Grid();
        editor.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        editor.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        Grid.SetRow(_pageStatus, 0);
        Grid.SetRow(_tabs, 1);
        editor.Children.Add(_pageStatus);
        editor.Children.Add(_tabs);

        var split = new Grid { Margin = new Thickness(Theme.SpaceL) };
        split.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        split.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        Grid.SetColumn(files, 0);
        Grid.SetColumn(editor, 1);
        split.Children.Add(files);
        split.Children.Add(editor);

        Content = split;
        _tabs.TabCloseRequested += async (_, args) =>
        {
            if (args.Item is TabViewItem item && item.Tag is EditorTab tab)
            {
                await CloseTabAsync(tab);
            }
        };
        Loaded += async (_, _) => await LoadTreeAsync();
    }

    private async Task LoadTreeAsync()
    {
        _tree.Children.Clear();
        _pageStatus.Children.Clear();
        try
        {
            var request = new JsonObject { ["id"] = _workspaceId };
            if (!string.IsNullOrEmpty(_directory))
            {
                request["path"] = _directory;
            }
            var listed = await AppServices.Host.CallAsync("workspace.tree", request);
            _treeCrumb.Text = string.IsNullOrEmpty(_directory) ? "Root" : _directory;
            if (!string.IsNullOrEmpty(_directory))
            {
                var up = ActionIconGlyph.Button("Up", ActionIcon.Back, async (_, _) =>
                {
                    var slash = _directory.TrimEnd('/').LastIndexOf('/');
                    _directory = slash < 0 ? "" : _directory.TrimEnd('/')[..slash];
                    await LoadTreeAsync();
                });
                _tree.Children.Add(up);
            }
            var entries = listed as JsonArray;
            if (entries is not null)
            {
                foreach (var entry in entries)
                {
                    if (entry is null)
                    {
                        continue;
                    }
                    var name = Format.Text(entry, "name");
                    var path = Format.Text(entry, "path");
                    var isDir = Format.Flag(entry, "isDir");
                    var label = new TextBlock
                    {
                        Text = isDir ? name + "/" : name,
                        FontSize = 12,
                        Opacity = Format.Flag(entry, "ignored") ? 0.5 : 1,
                    };
                    if (!isDir)
                    {
                        label.FontFamily = Fonts.Mono;
                    }
                    var pick = new Button
                    {
                        HorizontalAlignment = HorizontalAlignment.Stretch,
                        HorizontalContentAlignment = HorizontalAlignment.Left,
                        Content = label,
                    };
                    if (isDir)
                    {
                        pick.Click += async (_, _) =>
                        {
                            _directory = path;
                            await LoadTreeAsync();
                        };
                    }
                    else
                    {
                        pick.Click += async (_, _) => await OpenAsync(path);
                    }
                    _tree.Children.Add(pick);
                }
            }
            if (_tree.Children.Count == 0)
            {
                _tree.Children.Add(new TextBlock { Text = "This folder is empty.", Opacity = 0.7 });
            }
        }
        catch (Exception ex)
        {
            _pageStatus.Children.Add(Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important));
        }
    }

    private async Task OpenAsync(string path)
    {
        var existing = _open.FirstOrDefault(t => t.Path == path);
        if (existing is not null)
        {
            Select(existing);
            return;
        }
        string content;
        try
        {
            var read = await AppServices.Host.CallAsync(
                "workspace.read",
                new JsonObject { ["id"] = _workspaceId, ["path"] = path });
            content = Format.Text(read, "content");
        }
        catch (Exception ex)
        {
            _pageStatus.Children.Clear();
            _pageStatus.Children.Add(Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important));
            return;
        }
        var tab = new EditorTab(this, _workspaceId, path, content);
        _open.Add(tab);
        var item = new TabViewItem
        {
            Header = tab.Title,
            Content = tab.View,
            IsClosable = true,
        };
        tab.HeaderChanged = () => item.Header = tab.Title;
        item.Tag = tab;
        _tabs.TabItems.Add(item);
        _tabs.SelectedItem = item;
        _ = tab.HighlightAsync();
    }

    private void Select(EditorTab tab)
    {
        foreach (var entry in _tabs.TabItems)
        {
            if (entry is TabViewItem item && item.Tag == tab)
            {
                _tabs.SelectedItem = item;
                return;
            }
        }
    }

    /// <summary>
    /// Dirty buffers need explicit discard. An in-flight save cannot be
    /// closed.
    /// </summary>
    private async Task CloseTabAsync(EditorTab tab)
    {
        if (tab.IsSaving)
        {
            PageBanner("Wait for the save to finish, then close the tab.");
            return;
        }
        if (tab.IsDirty)
        {
            var dialog = new ContentDialog
            {
                Title = $"Discard changes to {tab.Name}?",
                Content = "Unsaved edits are lost.",
                PrimaryButtonText = "Discard",
                CloseButtonText = "Cancel",
                DefaultButton = ContentDialogButton.Close,
            };
            if (await Chrome.ShowDialog(this, dialog) != ContentDialogResult.Primary)
            {
                return;
            }
        }
        _open.Remove(tab);
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
    }

    private void PageBanner(string text)
    {
        _pageStatus.Children.Clear();
        _pageStatus.Children.Add(Chrome.Banner(text, Theme.Warning, Symbol.Important));
    }

    /// <summary>
    /// One file open in the editor. What is on screen versus what was last
    /// read from or written to disk: dirty is the difference between the
    /// two, so undoing back to the original stops reporting unsaved.
    /// </summary>
    private sealed class EditorTab
    {
        private readonly Page _owner;
        private readonly string _workspaceId;
        private readonly RichEditBox _box = new()
        {
            FontFamily = Fonts.Mono,
            FontSize = 13,
            AcceptsReturn = true,
        };
        private readonly StackPanel _conflict = new()
        {
            Spacing = Theme.SpaceS,
            Visibility = Visibility.Collapsed,
        };
        private readonly Grid _find = new() { Visibility = Visibility.Collapsed };
        private readonly TextBox _findQuery = new() { PlaceholderText = "Find in file", MinWidth = 200 };
        private readonly TextBox _replaceBox = new() { PlaceholderText = "Replace with", MinWidth = 200 };
        private readonly TextBlock _findCount = new() { Opacity = 0.7, VerticalAlignment = VerticalAlignment.Center };
        private readonly TextBlock _status = new() { Opacity = 0.7, FontSize = 12 };
        private readonly Grid _view = new();
        private readonly List<(int Start, int Length)> _matches = [];

        private string _text;
        private string _savedText;
        private string? _highlightNote;
        private string? _language;
        private int _indent = 4;
        private bool _applying;
        private CancellationTokenSource? _highlightTimer;
        private int _matchIndex;

        public Action? HeaderChanged { get; set; }

        public string Path { get; }

        public string Name => Path.Contains('/') ? Path[(Path.LastIndexOf('/') + 1)..] : Path;

        public string Title => Name + (IsDirty ? " •" : "");

        /// <summary>
        /// Line endings normalized: the edit box speaks carriage returns
        /// and the host speaks newlines, and that difference is not an edit.
        /// </summary>
        public bool IsDirty => Norm(_text) != Norm(_savedText);

        private static string Norm(string text) =>
            text.Replace("\r\n", "\n").Replace('\r', '\n');

        public bool IsSaving { get; private set; }

        public string? ConflictHost { get; private set; }

        public UIElement View => _view;

        public EditorTab(Page owner, string workspaceId, string path, string content)
        {
            _owner = owner;
            _workspaceId = workspaceId;
            Path = path;
            _text = content;
            _savedText = content;

            var chrome = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = Theme.SpaceS,
                Padding = new Thickness(0, 0, 0, Theme.SpaceS),
            };
            chrome.Children.Add(ActionIconGlyph.Button("Save", ActionIcon.Save, async (_, _) => await SaveAsync()));
            chrome.Children.Add(ActionIconGlyph.Button("Find", ActionIcon.Search, (_, _) => ToggleFind()));
            chrome.Children.Add(_status);

            BuildFindBar();
            BuildConflictCard();

            _view.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            _view.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            _view.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            _view.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            Grid.SetRow(chrome, 0);
            Grid.SetRow(_conflict, 1);
            Grid.SetRow(_find, 2);
            Grid.SetRow(_box, 3);
            _view.Children.Add(chrome);
            _view.Children.Add(_conflict);
            _view.Children.Add(_find);
            _view.Children.Add(_box);

            _applying = true;
            _box.Document.SetText(TextSetOptions.None, content);
            _applying = false;
            _box.TextChanged += (_, _) => OnEdited();
            _findQuery.TextChanged += (_, _) => RefreshMatches();
            _box.KeyDown += BoxOnKeyDown;
            RefreshStatus();
        }

        private void BoxOnKeyDown(object sender, KeyRoutedEventArgs e)
        {
            if (e.Key == VirtualKey.Tab)
            {
                e.Handled = true;
                try
                {
                    _box.Document.Selection.Text = new string(' ', _indent);
                }
                catch
                {
                }
                return;
            }
            if (e.Key == VirtualKey.F && Microsoft.UI.Input.InputKeyboardSource
                .GetKeyStateForCurrentThread(VirtualKey.Control)
                .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down))
            {
                e.Handled = true;
                ToggleFind();
            }
        }

        private void ToggleFind()
        {
            _find.Visibility = _find.Visibility == Visibility.Visible ? Visibility.Collapsed : Visibility.Visible;
            if (_find.Visibility == Visibility.Visible)
            {
                RefreshMatches();
                _findQuery.Focus(FocusState.Programmatic);
            }
        }

        private void OnEdited()
        {
            if (_applying)
            {
                return;
            }
            _box.Document.GetText(TextGetOptions.None, out var current);
            if (current == _text)
            {
                return;
            }
            _text = current;
            HeaderChanged?.Invoke();
            RefreshStatus();
            RefreshMatches();
            _highlightTimer?.Cancel();
            _highlightTimer = new CancellationTokenSource();
            var token = _highlightTimer.Token;
            _ = Task.Run(async () =>
            {
                try
                {
                    await Task.Delay(300, token);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
                _owner.DispatcherQueue.TryEnqueue(async () => await HighlightAsync());
            });
        }

        private void BuildFindBar()
        {
            var queryRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
            queryRow.Children.Add(_findQuery);
            queryRow.Children.Add(_findCount);
            queryRow.Children.Add(ActionIconGlyph.Button("Previous", ActionIcon.Back, (_, _) => MoveMatch(-1)));
            queryRow.Children.Add(ActionIconGlyph.Button("Next", ActionIcon.Next, (_, _) => MoveMatch(1)));
            queryRow.Children.Add(ActionIconGlyph.Button("Close find", ActionIcon.Dismiss, (_, _) =>
            {
                _find.Visibility = Visibility.Collapsed;
            }));
            var replaceRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
            replaceRow.Children.Add(_replaceBox);
            replaceRow.Children.Add(ActionIconGlyph.Button("Replace", ActionIcon.Edit, (_, _) => ReplaceCurrent()));
            replaceRow.Children.Add(ActionIconGlyph.Button("Replace all", ActionIcon.Edit, (_, _) => ReplaceAll()));
            replaceRow.Children.Add(new TextBlock
            {
                Text = "Replace all is one undo, in this file only.",
                Opacity = 0.7,
                FontSize = 12,
                VerticalAlignment = VerticalAlignment.Center,
            });
            var stack = new StackPanel { Spacing = Theme.SpaceS };
            stack.Children.Add(queryRow);
            stack.Children.Add(replaceRow);
            _find.Children.Add(stack);
            _findQuery.KeyDown += (_, e) =>
            {
                if (e.Key == VirtualKey.Enter)
                {
                    e.Handled = true;
                    MoveMatch(1);
                }
            };
        }

        private void BuildConflictCard()
        {
            _conflict.Children.Add(new TextBlock
            {
                Text = "This file changed on the host.",
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            });
            var summary = new TextBlock { TextWrapping = TextWrapping.Wrap, Opacity = 0.8 };
            summary.Tag = "summary";
            _conflict.Children.Add(summary);
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
            actions.Children.Add(ActionIconGlyph.Button(
                "Reload host", ActionIcon.Restore, async (_, _) => await ResolveConflictAsync(keepMine: false)));
            actions.Children.Add(ActionIconGlyph.Button(
                "Keep my draft", ActionIcon.Edit, async (_, _) => await ResolveConflictAsync(keepMine: true)));
            _conflict.Children.Add(actions);
        }

        /// <summary>
        /// Literal, case-insensitive matches over the buffer, wrapping in
        /// both directions. Bounded so a pathological query cannot mint
        /// unbounded ranges.
        /// </summary>
        private void RefreshMatches()
        {
            _matches.Clear();
            _matchIndex = 0;
            var query = _findQuery.Text ?? "";
            if (_find.Visibility == Visibility.Visible && query.Length > 0 && _text.Length > 0)
            {
                var at = 0;
                while (at < _text.Length && _matches.Count < 2000)
                {
                    var found = _text.IndexOf(query, at, StringComparison.OrdinalIgnoreCase);
                    if (found < 0)
                    {
                        break;
                    }
                    _matches.Add((found, query.Length));
                    at = found + Math.Max(query.Length, 1);
                }
            }
            if (_matches.Count == 0)
            {
                _findCount.Text = query.Length > 0 ? "No results" : "";
            }
            else
            {
                var truncated = _matches.Count >= 2000 ? "+" : "";
                _findCount.Text = $"{_matchIndex + 1} of {_matches.Count}{truncated}";
            }
        }

        private void MoveMatch(int step)
        {
            if (_matches.Count == 0)
            {
                return;
            }
            _matchIndex = (_matchIndex + step + _matches.Count * 1000) % _matches.Count;
            var truncated = _matches.Count >= 2000 ? "+" : "";
            _findCount.Text = $"{_matchIndex + 1} of {_matches.Count}{truncated}";
            var (start, length) = _matches[_matchIndex];
            try
            {
                _box.Document.Selection.SetRange(start, start + length);
                _box.Focus(FocusState.Programmatic);
            }
            catch
            {
            }
        }

        private void ReplaceCurrent()
        {
            if (_matches.Count == 0)
            {
                return;
            }
            var (start, length) = _matches[_matchIndex];
            var next = _text[..start] + (_replaceBox.Text ?? "") + _text[(start + length)..];
            SetBuffer(next);
            RefreshMatches();
        }

        private void ReplaceAll()
        {
            var query = _findQuery.Text ?? "";
            if (query.Length == 0 || _matches.Count == 0)
            {
                return;
            }
            SetBuffer(_text.Replace(query, _replaceBox.Text ?? "", StringComparison.OrdinalIgnoreCase));
            RefreshMatches();
        }

        private void SetBuffer(string next)
        {
            if (next == _text)
            {
                return;
            }
            _text = next;
            _applying = true;
            try
            {
                var selection = _box.Document.Selection;
                var start = selection.StartPosition;
                _box.Document.SetText(TextSetOptions.None, next);
                _box.Document.Selection.SetRange(Math.Min(start, next.Length), Math.Min(start, next.Length));
            }
            catch
            {
            }
            finally
            {
                _applying = false;
            }
            HeaderChanged?.Invoke();
            RefreshStatus();
            _ = HighlightAsync();
        }

        /// <summary>
        /// Colour the buffer once it stops changing. The host sends kinds
        /// and never colours, in UTF-16 units that drop straight into
        /// ranges. A result measured against older text is dropped, not
        /// painted over the wrong ranges.
        /// </summary>
        public async Task HighlightAsync()
        {
            var source = _text;
            JsonNode answer;
            try
            {
                answer = await AppServices.Host.CallAsync(
                    "highlight",
                    new JsonObject { ["path"] = Path, ["text"] = source });
            }
            catch
            {
                return;
            }
            if (source != _text)
            {
                return;
            }
            _language = Format.Text(answer, "language");
            _highlightNote = Format.Text(answer, "note");
            var syntax = answer["syntax"];
            var indent = (int)Format.Long(syntax, "indent");
            _indent = indent > 0 ? indent : 4;
            var spans = answer["spans"] as JsonArray;
            try
            {
                _applying = true;
                var doc = _box.Document;
                doc.GetText(TextGetOptions.None, out var current);
                var length = current.Length;
                var plain = doc.GetRange(0, length);
                plain.CharacterFormat.ForegroundColor = Theme.DefaultText;
                if (spans is not null)
                {
                    foreach (var span in spans)
                    {
                        if (span is null)
                        {
                            continue;
                        }
                        var start = (int)Format.Long(span, "start");
                        var len = (int)Format.Long(span, "len");
                        if (start < 0 || len <= 0 || start + len > length)
                        {
                            continue;
                        }
                        if (!Enum.TryParse<SyntaxKind>(Format.Text(span, "kind"), ignoreCase: true, out var kind))
                        {
                            kind = SyntaxKind.Unknown;
                        }
                        doc.GetRange(start, start + len).CharacterFormat.ForegroundColor = Theme.Syntax(kind);
                    }
                }
            }
            catch
            {
            }
            finally
            {
                _applying = false;
            }
            RefreshStatus();
        }

        /// <summary>
        /// The host file may have moved since this buffer opened: another
        /// window, or a run writing output. Re-read before writing so a
        /// stale draft cannot silently overwrite newer host content.
        /// </summary>
        public async Task SaveAsync()
        {
            if (IsSaving || !IsDirty || ConflictHost is not null)
            {
                return;
            }
            IsSaving = true;
            StatusError(null);
            try
            {
                string host;
                try
                {
                    var read = await AppServices.Host.CallAsync(
                        "workspace.read",
                        new JsonObject { ["id"] = _workspaceId, ["path"] = Path });
                    host = Format.Text(read, "content");
                }
                catch
                {
                    StatusError("Could not re-read this file on the host, so the save waits. Your edits are kept.");
                    return;
                }
                var draft = Norm(_text);
                var saved = Norm(_savedText);
                if (host != draft && host != saved)
                {
                    ConflictHost = host;
                    ShowConflict();
                    return;
                }
                if (host == draft)
                {
                    // Already there: a lost acknowledgement or a matching
                    // remote edit. Mark it saved without writing again.
                    MarkSaved(draft);
                    return;
                }
                var sent = draft;
                try
                {
                    await AppServices.Host.CallAsync(
                        "workspace.write",
                        new JsonObject { ["id"] = _workspaceId, ["path"] = Path, ["content"] = sent });
                    MarkSaved(sent);
                }
                catch (Exception ex)
                {
                    StatusError(ex.Message);
                }
            }
            finally
            {
                IsSaving = false;
                RefreshStatus();
            }
        }

        /// <summary>
        /// Choose a copy after a conflict. Reloading adopts the host and
        /// clears the draft; keeping writes the draft through explicitly.
        /// </summary>
        private async Task ResolveConflictAsync(bool keepMine)
        {
            var host = ConflictHost;
            if (IsSaving || host is null)
            {
                return;
            }
            if (!keepMine)
            {
                Adopt(host);
                ConflictHost = null;
                ShowConflict();
                return;
            }
            ConflictHost = null;
            ShowConflict();
            StatusError(null);
            var sent = Norm(_text);
            IsSaving = true;
            try
            {
                await AppServices.Host.CallAsync(
                    "workspace.write",
                    new JsonObject { ["id"] = _workspaceId, ["path"] = Path, ["content"] = sent });
                MarkSaved(sent);
            }
            catch (Exception ex)
            {
                StatusError(ex.Message);
            }
            finally
            {
                IsSaving = false;
                RefreshStatus();
            }
        }

        private void MarkSaved(string content)
        {
            // A save acknowledges the submitted version. Edits made while
            // that request was in flight stay dirty.
            _savedText = content;
            HeaderChanged?.Invoke();
        }

        private void Adopt(string content)
        {
            _text = content;
            _savedText = Norm(content);
            StatusError(null);
            _applying = true;
            try
            {
                _box.Document.SetText(TextSetOptions.None, content);
            }
            catch
            {
            }
            finally
            {
                _applying = false;
            }
            HeaderChanged?.Invoke();
            RefreshStatus();
            _ = HighlightAsync();
        }

        private void ShowConflict()
        {
            var host = ConflictHost;
            if (host is null)
            {
                _conflict.Visibility = Visibility.Collapsed;
                return;
            }
            _conflict.Visibility = Visibility.Visible;
            var mineText = Norm(_text);
            var mine = LineCount(mineText);
            var theirs = LineCount(host);
            var summary = $"Yours has {mine} lines, the host has {theirs}. Saving is off until you choose.";
            var first = FirstDifference(mineText, host);
            if (first.HasValue)
            {
                summary += $" First difference: line {first}.";
            }
            foreach (var child in _conflict.Children)
            {
                if (child is TextBlock block && block.Tag as string == "summary")
                {
                    block.Text = summary;
                }
            }
        }

        /// <summary>
        /// One-based number of the first line where two texts differ, or
        /// null when they match. Names where to look instead of eyeballing
        /// two full files.
        /// </summary>
        private static int? FirstDifference(string mine, string other)
        {
            if (mine == other)
            {
                return null;
            }
            var mineLines = mine.Split('\n');
            var otherLines = other.Split('\n');
            var shared = Math.Min(mineLines.Length, otherLines.Length);
            for (var i = 0; i < shared; i++)
            {
                if (mineLines[i] != otherLines[i])
                {
                    return i + 1;
                }
            }
            return shared + 1;
        }

        private static int LineCount(string text)
        {
            if (text.Length == 0)
            {
                return 0;
            }
            var lines = 1;
            foreach (var ch in text)
            {
                if (ch == '\n')
                {
                    lines++;
                }
            }
            return lines;
        }

        private string? _error;

        private void StatusError(string? message)
        {
            _error = message;
            RefreshStatus();
        }

        private void RefreshStatus()
        {
            var parts = new List<string>();
            if (!string.IsNullOrEmpty(_language))
            {
                parts.Add(_language);
            }
            else if (!string.IsNullOrEmpty(_highlightNote))
            {
                parts.Add(_highlightNote);
            }
            if (IsDirty)
            {
                parts.Add("Unsaved changes");
            }
            if (!string.IsNullOrEmpty(_error))
            {
                parts.Add(_error);
            }
            _status.Text = string.Join(" · ", parts);
        }
    }
}
