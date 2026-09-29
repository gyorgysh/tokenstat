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
using Tokenstat.Navigation;
using Windows.System;

namespace Tokenstat.Pages;

/// <summary>
/// Small things worth keeping, and nothing else. Matches the Mac NotesView:
/// a quick-note composer that stays ready, scope chips on the global list,
/// search and newest-or-title sort, cards or a list, an archive, and a detail
/// inspector where the full text can be read and copied. A note is a todo
/// card whose kind is note, so every action here is a todo method that
/// already existed. Pass a workspace id to scope the screen to that folder.
/// </summary>
internal sealed class NotesPage : Page, IInspectorContent, IToolbarItems
{
    private readonly string? _workspaceId;
    private readonly Grid _split = new();
    private readonly ScrollViewer _listScroll = new();
    private readonly ScrollViewer _detailScroll = new();
    private readonly NoteDraftStore _noteDrafts = new();
    private readonly Dictionary<string, CancellationTokenSource> _saveDelays = new();
    private Action<string>? _draftStatusChanged;
    private readonly StackPanel _root = new() { Spacing = Theme.SpaceL };
    private readonly StackPanel _bannerHost = new() { Spacing = Theme.SpaceS };
    private readonly StackPanel _composerHost = new() { Spacing = Theme.SpaceS };
    private readonly StackPanel _libraryHost = new() { Spacing = Theme.SpaceS };
    private readonly StackPanel _scopeHost = new() { Spacing = Theme.SpaceS };
    private readonly StackPanel _listHost = new() { Spacing = Theme.SpaceL };
    private readonly StackPanel _detailHost = new()
    {
        Spacing = Theme.SpaceM,
        Padding = new Thickness(Theme.SpaceM),
    };
    private readonly TextBox _draft = new()
    {
        PlaceholderText = "Capture an idea, a decision, or something to follow up…",
    };
    private TextBlock? _countText;

    private JsonArray _cards = new();
    private List<(string Id, string Name)> _folders = new();
    private string _search = "";
    private bool _sortByTitle;
    private bool _gridLayout = false;
    private bool _showingArchive;
    private bool _showingComposer;
    private bool _previewNote;
    private string _picked = "";
    private string? _selectedId;
    private bool _confirmDelete;
    private bool _saving;
    private bool _loaded;

    private const string UnassignedPick = "__unassigned__";

    public NotesPage(string? workspaceId = null)
    {
        _workspaceId = workspaceId;
        _draft.KeyDown += async (_, e) =>
        {
            if (e.Key == VirtualKey.Enter)
            {
                await SaveAsync();
            }
        };
        _root.Children.Add(_bannerHost);
        _root.Children.Add(_composerHost);
        _root.Children.Add(_libraryHost);
        _listHost.Children.Add(Motion.SkeletonCard());
        _root.Padding = new Thickness(Theme.SpaceM);
        _split.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(300) });
        _split.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _listScroll.Content = _listHost;
        _listScroll.Padding = new Thickness(Theme.SpaceM);
        _detailScroll.Content = _detailHost;
        Grid.SetColumn(_detailScroll, 1);
        _split.Children.Add(_listScroll);
        _split.Children.Add(_detailScroll);
        var page = new Grid();
        page.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        page.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        page.Children.Add(_root);
        Grid.SetRow(_split, 1);
        page.Children.Add(_split);
        Content = page;
        SizeChanged += (_, _) => UpdateNoteLayout();
        RenderDetail();
        Loaded += async (_, _) => await LoadAsync();
    }

    public event Action? ToolbarChanged;

    /// <summary>
    /// The folder this screen belongs to, or null on the global list, where
    /// the scope chips in content say which folder each note is in.
    /// </summary>
    public UIElement? ToolbarScope
    {
        get
        {
            if (_workspaceId is null)
            {
                return null;
            }
            var folder = _folders.FirstOrDefault(f => f.Id == _workspaceId);
            return Chrome.ScopeChip(string.IsNullOrEmpty(folder.Name) ? "Folder" : folder.Name);
        }
    }

    /// <summary>
    /// The inspector column content. Selection and reloads replace its
    /// children, so the column stays live without the shell asking again.
    /// </summary>
    public UIElement? Inspector => null;

    public IList<UIElement> ToolbarActions()
    {
        var archive = Buttons.ToolbarIcon(
            _showingArchive ? ActionIcon.Restore : ActionIcon.Archive,
            _showingArchive ? "Show current notes" : "Show archived notes",
            (_, _) =>
            {
                _showingArchive = !_showingArchive;
                _selectedId = null;
                _confirmDelete = false;
                RenderAll();
            },
            _showingArchive);
        archive.IsEnabled = ArchivedCount() > 0 || _showingArchive;
        return new List<UIElement>
        {
            Buttons.ToolbarIcon(
                ActionIcon.Refresh,
                "Reload notes",
                async (_, _) =>
                {
                    LogoRefresh.Began();
                    await LoadAsync();
                }),
            Buttons.ToolbarIcon(
                ActionIcon.Create,
                "Write a note",
                (_, _) =>
                {
                    _showingArchive = false;
                    _showingComposer = true;
                    RenderAll();
                    _draft.Focus(FocusState.Programmatic);
                }),
            Buttons.ToolbarIcon(
                ActionIcon.Layout,
                _gridLayout ? "Show notes as a list" : "Show notes as cards",
                (_, _) =>
                {
                    _gridLayout = !_gridLayout;
                    RenderAll();
                }),
            archive,
        };
    }

    private void RaiseToolbarChanged() => ToolbarChanged?.Invoke();

    /// <summary>
    /// One todo method against this screen's folder, local or remote. A
    /// remote folder travels as remote.call with the peer's own folder id,
    /// the way the folder page already routes its task list. Params are
    /// copied, never mutated, so a retry cannot forward an already rewritten
    /// id. The global list has no folder and always stays local.
    /// </summary>
    private Task<JsonNode> CallTodoAsync(string method, JsonNode? parameters = null)
    {
        if (_workspaceId is null
            || !RemoteWorkspaces.TrySplit(_workspaceId, out var peer, out var inner))
        {
            return AppServices.Host.CallAsync(method, parameters);
        }
        var forwarded = parameters is null
            ? new JsonObject()
            : (JsonObject)JsonNode.Parse(parameters.ToJsonString())!;
        if (Format.Text(forwarded, "workspaceId") == _workspaceId)
        {
            forwarded["workspaceId"] = inner;
        }
        return RemoteWorkspaces.CallOnPeerAsync(peer, method, forwarded);
    }

    private async Task LoadAsync()
    {
        try
        {
            var cardsTask = CallTodoAsync(
                "todo.list", new JsonObject { ["includeArchived"] = true });
            var foldersTask = CallTodoAsync("workspace.list", new JsonObject());
            await Task.WhenAll(cardsTask, foldersTask);
            _cards = cardsTask.Result as JsonArray
                ?? cardsTask.Result["cards"] as JsonArray
                ?? new JsonArray();
            _folders = ReadFolders(foldersTask.Result);
            if (_workspaceId is not null
                && RemoteWorkspaces.TrySplit(_workspaceId, out _, out var inner))
            {
                // Cards from the peer carry its own folder id. Namespace them
                // to this page's folder id so the scope filter below keeps
                // matching, and list the folder itself so its name resolves.
                foreach (var card in _cards)
                {
                    if (card is JsonObject obj && Format.Text(obj, "workspaceId") == inner)
                    {
                        obj["workspaceId"] = _workspaceId;
                    }
                }
                // Folder choices must belong to the same host as the cards.
                // Keep this page's selected folder in the shell namespace;
                // other choices already carry the owning peer's native ids.
                _folders = _folders.Select(folder =>
                    (Id: folder.Id == inner ? _workspaceId : folder.Id, Name: folder.Name)).ToList();
                if (RemoteWorkspaces.CachedFolder(_workspaceId) is RemoteFolder cached
                    && _folders.All(f => f.Id != _workspaceId))
                {
                    _folders.Add((_workspaceId, cached.DisplayName));
                }
            }
            _loaded = true;
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
            return;
        }
        RaiseToolbarChanged();
        RenderAll();
    }

    private static List<(string Id, string Name)> ReadFolders(JsonNode? listed)
    {
        var outList = new List<(string Id, string Name)>();
        var array = listed as JsonArray ?? listed?["workspaces"] as JsonArray;
        if (array is null)
        {
            return outList;
        }
        foreach (var folder in array)
        {
            var id = Format.Text(folder, "id");
            if (string.IsNullOrEmpty(id))
            {
                continue;
            }
            outList.Add((id, Format.Text(folder, "name", Format.Text(folder, "path", id))));
        }
        return outList;
    }

    private void Banner(string text)
    {
        _bannerHost.Children.Insert(0, Chrome.Banner(text, Theme.Danger, Symbol.Important));
        while (_bannerHost.Children.Count > 3)
        {
            _bannerHost.Children.RemoveAt(_bannerHost.Children.Count - 1);
        }
    }

    private void RenderAll()
    {
        RaiseToolbarChanged();
        RenderComposer();
        RenderLibrary();
        RenderScopes();
        RenderList();
        RenderDetail();
    }

    /// <summary>
    /// What the list is showing: the folder this screen belongs to, or the
    /// chip picked on the global one.
    /// </summary>
    private string ScopePick => _workspaceId ?? _picked;

    private string DestinationId()
    {
        var scope = ScopePick;
        if (scope == "" || scope == UnassignedPick)
        {
            return "";
        }
        return scope;
    }

    private string DestinationName()
    {
        var id = DestinationId();
        if (string.IsNullOrEmpty(id))
        {
            return "Unassigned";
        }
        return _folders.FirstOrDefault(f => f.Id == id).Name ?? "this folder";
    }

    private string PlaceName(JsonNode? note)
    {
        var id = Format.Text(note, "workspaceId");
        if (string.IsNullOrEmpty(id))
        {
            return "Unassigned";
        }
        return _folders.FirstOrDefault(f => f.Id == id).Name ?? "Folder";
    }

    private bool InScope(JsonNode? note)
    {
        var scope = ScopePick;
        var id = Format.Text(note, "workspaceId");
        if (scope == "")
        {
            return true;
        }
        if (scope == UnassignedPick)
        {
            return string.IsNullOrEmpty(id);
        }
        return id == scope;
    }

    private int CountIn(string scope, bool archived)
    {
        var count = 0;
        foreach (var card in _cards)
        {
            if (Format.Text(card, "kind") != "note")
            {
                continue;
            }
            if ((Format.Text(card, "column") == "archive") != archived)
            {
                continue;
            }
            var id = Format.Text(card, "workspaceId");
            var match = scope switch
            {
                "" => true,
                UnassignedPick => string.IsNullOrEmpty(id),
                _ => id == scope,
            };
            if (match)
            {
                count++;
            }
        }
        return count;
    }

    private int ArchivedCount() => CountIn(ScopePick, archived: true);

    private List<JsonNode?> ShownNotes()
    {
        var term = _search.Trim();
        var list = new List<JsonNode?>();
        foreach (var card in _cards)
        {
            if (Format.Text(card, "kind") != "note")
            {
                continue;
            }
            if ((Format.Text(card, "column") == "archive") != _showingArchive)
            {
                continue;
            }
            if (!InScope(card))
            {
                continue;
            }
            if (!string.IsNullOrEmpty(term)
                && !Format.Text(card, "title").Contains(term, StringComparison.OrdinalIgnoreCase)
                && !Format.Text(card, "notes").Contains(term, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }
            list.Add(card);
        }
        if (_sortByTitle)
        {
            list.Sort((a, b) =>
            {
                var comparison = string.Compare(
                    Format.Text(a, "title"), Format.Text(b, "title"),
                    StringComparison.CurrentCultureIgnoreCase);
                return comparison == 0
                    ? string.CompareOrdinal(Format.Text(a, "id"), Format.Text(b, "id"))
                    : comparison;
            });
        }
        else
        {
            list.Sort((a, b) => Format.Long(b, "createdAtMs").CompareTo(Format.Long(a, "createdAtMs")));
        }
        return list;
    }

    private static string Ago(long ms)
    {
        if (ms <= 0)
        {
            return "";
        }
        var span = DateTimeOffset.UtcNow - DateTimeOffset.FromUnixTimeMilliseconds(ms);
        if (span.TotalMinutes < 1)
        {
            return "just now";
        }
        if (span.TotalHours < 1)
        {
            return $"{(int)span.TotalMinutes}m ago";
        }
        if (span.TotalDays < 1)
        {
            return $"{(int)span.TotalHours}h ago";
        }
        if (span.TotalDays < 7)
        {
            return $"{(int)span.TotalDays}d ago";
        }
        return DateTimeOffset.FromUnixTimeMilliseconds(ms).LocalDateTime.ToString("d");
    }

    /// <summary>
    /// Opened from the toolbar. Closing it retains the draft for next time.
    /// </summary>
    private void RenderComposer()
    {
        if (_draft.Parent is Panel draftParent) draftParent.Children.Remove(_draft);
        _composerHost.Children.Clear();
        if (_showingArchive || !_showingComposer)
        {
            return;
        }
        var body = new StackPanel { Spacing = Theme.SpaceS };
        var head = new Grid();
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        head.Children.Add(new TextBlock
        {
            Text = "Quick note",
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        var destination = new TextBlock
        {
            Text = DestinationName(),
            FontSize = 12,
            Opacity = 0.66,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(destination, 1);
        head.Children.Add(destination);
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var close = Buttons.ToolbarIcon(ActionIcon.Dismiss, "Close composer; your draft stays here", (_, _) =>
        {
            _showingComposer = false;
            RenderComposer();
        });
        Grid.SetColumn(close, 2);
        head.Children.Add(close);
        body.Children.Add(head);
        var row = new Grid { ColumnSpacing = Theme.SpaceS };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.Children.Add(_draft);
        var save = Buttons.Primary("Save note", ActionIcon.Create, async (_, _) => await SaveAsync());
        save.IsEnabled = !_saving;
        Grid.SetColumn(save, 1);
        row.Children.Add(save);
        body.Children.Add(row);
        body.Children.Add(new TextBlock
        {
            Text = "Return to save · Select a note to edit its full text",
            FontSize = 12,
            Opacity = 0.55,
        });
        _composerHost.Children.Add(Chrome.Card("Notes", body, $"Saves to {DestinationName()}."));
    }

    private void RenderLibrary()
    {
        if (_scopeHost.Parent is Panel scopeParent) scopeParent.Children.Remove(_scopeHost);
        _libraryHost.Children.Clear();
        var bar = new FlowPanel { Spacing = Theme.SpaceS };
        var search = Chrome.SearchField("Search notes", text =>
        {
            _search = text ?? "";
            if (_countText is not null) _countText.Text = ShownNotes().Count.ToString();
            RenderList();
        });
        search.Text = _search;
        search.Width = 260;
        search.VerticalAlignment = VerticalAlignment.Center;
        bar.Children.Add(search);
        bar.Children.Add(_scopeHost);
        var sort = new ComboBox { MinWidth = 130, VerticalAlignment = VerticalAlignment.Center };
        sort.ItemsSource = new[] { "Newest first", "Title A–Z" };
        sort.SelectedIndex = _sortByTitle ? 1 : 0;
        sort.SelectionChanged += (_, _) =>
        {
            _sortByTitle = sort.SelectedIndex == 1;
            RenderList();
        };
        bar.Children.Add(sort);
        _countText = new TextBlock { Text = ShownNotes().Count.ToString(), Opacity = 0.66,
            VerticalAlignment = VerticalAlignment.Center };
        bar.Children.Add(_countText);
        _libraryHost.Children.Add(bar);
    }

    private void RenderScopes()
    {
        _scopeHost.Children.Clear();
        if (_workspaceId is not null) return;
        var choices = new List<(string Id, string Name)> { ("", "All projects"), (UnassignedPick, "Unassigned") };
        choices.AddRange(_folders);
        var picker = new ComboBox { MinWidth = 160, MaxWidth = 240,
            ItemsSource = choices.Select(choice => choice.Name).ToList(),
            SelectedIndex = Math.Max(0, choices.FindIndex(choice => choice.Id == _picked)) };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(picker, "Filter notes by project");
        picker.SelectionChanged += (_, _) =>
        {
            if (picker.SelectedIndex < 0) return;
            _picked = choices[picker.SelectedIndex].Id;
            _selectedId = null;
            RenderAll();
        };
        _scopeHost.Children.Add(picker);
    }

    private void RenderList()
    {
        _listHost.Children.Clear();
        if (!_loaded)
        {
            _listHost.Children.Add(Motion.SkeletonCard());
            return;
        }
        var shown = ShownNotes();
        if (shown.Count == 0)
        {
            if (!string.IsNullOrEmpty(_search.Trim()))
            {
                _listHost.Children.Add(Chrome.Empty(
                    "No matching notes",
                    "No note in this list matches that search.",
                    ActionIcon.Search,
                    ActionIconGlyph.Button("Clear search", ActionIcon.Dismiss, (_, _) =>
                    {
                        _search = "";
                        RenderAll();
                    })));
            }
            else
            {
                _listHost.Children.Add(EmptyState.View(
                    _showingArchive ? "Nothing archived" : EmptyTitle(),
                    _showingArchive
                        ? $"Notes you put away in {DestinationName()} show up here."
                        : "Capture your first note above. You can turn it into a task later.",
                    EmptyArtKind.Notes));
            }
            return;
        }
        if (_gridLayout && shown.Count > 1)
        {
            var grid = new Grid { ColumnSpacing = Theme.SpaceM, RowSpacing = Theme.SpaceM };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            for (var i = 0; i < shown.Count; i++)
            {
                if (i % 2 == 0)
                {
                    grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                }
                var card = NoteCard(shown[i]);
                Grid.SetRow(card, i / 2);
                Grid.SetColumn(card, i % 2);
                grid.Children.Add(card);
            }
            _listHost.Children.Add(grid);
            return;
        }
        var list = new StackPanel { Spacing = Theme.SpaceS };
        foreach (var note in shown)
        {
            list.Children.Add(NoteCard(note));
        }
        _listHost.Children.Add(list);
    }

    private string EmptyTitle()
    {
        var scope = ScopePick;
        if (scope == UnassignedPick)
        {
            return "No unassigned notes";
        }
        if (scope != "")
        {
            return $"No notes in {DestinationName()}";
        }
        return "No notes yet";
    }

    private FrameworkElement NoteCard(JsonNode? note)
    {
        var id = Format.Text(note, "id");
        var selected = id == _selectedId;
        var body = new StackPanel { Spacing = Theme.SpaceS };
        var head = new Grid();
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        head.Children.Add(new TextBlock
        {
            Text = PlaceName(note),
            FontSize = 12,
            Opacity = 0.66,
        });
        var ago = new TextBlock
        {
            Text = Ago(Format.Long(note, "createdAtMs")),
            FontSize = 12,
            Opacity = 0.55,
        };
        Grid.SetColumn(ago, 1);
        head.Children.Add(ago);
        body.Children.Add(head);
        body.Children.Add(new TextBlock
        {
            Text = Format.Text(note, "title", "(untitled)"),
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
            MaxLines = 2,
        });
        var extra = Format.Text(note, "notes");
        if (!string.IsNullOrEmpty(extra))
        {
            body.Children.Add(new TextBlock
            {
                Text = extra,
                FontSize = 12,
                Opacity = 0.68,
                TextWrapping = TextWrapping.Wrap,
                MaxLines = _gridLayout ? 5 : 2,
            });
        }
        var foot = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Theme.SpaceS,
            HorizontalAlignment = HorizontalAlignment.Right,
        };
        if (_showingArchive)
        {
            foot.Children.Add(Buttons.Secondary(
                "Restore", ActionIcon.Restore,
                async (_, _) => await SetArchivedAsync(id, archived: false), small: true));
        }
        else
        {
            foot.Children.Add(Buttons.Secondary(
                "Make a task", ActionIcon.Move,
                async (_, _) => await ConvertAsync(id, DestinationId()), small: true));
        }
        if (_gridLayout) body.Children.Add(foot);
        var frame = new Border
        {
            Background = selected ? Theme.AccentSoftBrush : Theme.PanelBrush,
            BorderBrush = selected ? Theme.AccentBrush : Theme.BorderBrush,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(Theme.CardRadius),
            Padding = new Thickness(Theme.CardPadding),
            Child = body,
        };
        if (_gridLayout)
        {
            frame.MinHeight = 185;
        }
        var button = new Button
        {
            Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(0),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Content = frame,
        };
        button.Click += (_, _) =>
        {
            _selectedId = id;
            _confirmDelete = false;
            RenderList();
            RenderDetail();
        };
        var menu = ContextMenus.Menu(button);
        ContextMenus.AddButton(menu, button, "Edit note");
        ContextMenus.Copy(menu, "Copy note", () => Format.Text(note, "title") + "\n" + Format.Text(note, "notes"));
        ContextMenus.AddButtons(menu, foot);
        if (!_showingArchive) ContextMenus.AddAsync(menu, "Archive", async () => await SetArchivedAsync(id, true));
        ContextMenus.Add(menu, "Delete note…", () =>
        {
            _selectedId = id;
            _confirmDelete = true;
            RenderList();
            RenderDetail();
        });
        return button;
    }

    private JsonNode? SelectedNote()
    {
        if (_selectedId is null)
        {
            return null;
        }
        foreach (var card in _cards)
        {
            if (Format.Text(card, "id") == _selectedId && Format.Text(card, "kind") == "note")
            {
                return card;
            }
        }
        return null;
    }

    private void UpdateNoteLayout()
    {
        var wide = ActualWidth >= 640;
        var showList = wide || _selectedId is null;
        _split.ColumnDefinitions[0].Width = showList
            ? (wide ? new GridLength(Math.Min(320, ActualWidth * 0.36)) : new GridLength(1, GridUnitType.Star))
            : new GridLength(0);
        _split.ColumnDefinitions[1].Width = wide || _selectedId is not null
            ? new GridLength(1, GridUnitType.Star) : new GridLength(0);
        _listScroll.Visibility = showList ? Visibility.Visible : Visibility.Collapsed;
        _detailScroll.Visibility = wide || _selectedId is not null ? Visibility.Visible : Visibility.Collapsed;
    }

    private void RenderDetail()
    {
        UpdateNoteLayout();
        if (_draftStatusChanged is not null) _noteDrafts.Changed -= _draftStatusChanged;
        _draftStatusChanged = null;
        _detailHost.Children.Clear();
        var note = SelectedNote();
        if (note is null)
        {
            _detailHost.Children.Add(new TextBlock
            {
                Text = "Select a note",
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            });
            _detailHost.Children.Add(new TextBlock
            {
                Text = "Pick a note to read its full text.",
                Opacity = 0.66,
                TextWrapping = TextWrapping.Wrap,
            });
            return;
        }
        _detailHost.Children.Add(Buttons.Secondary("All notes", ActionIcon.Back, (_, _) => {
            _selectedId = null; RenderList(); RenderDetail();
        }, small: true));
        _detailHost.Children.Add(DetailCard(note));
    }

    private UIElement DetailCard(JsonNode note)
    {
        var id = Format.Text(note, "id");
        var body = new StackPanel { Spacing = Theme.SpaceM };
        body.Children.Add(new TextBlock
        {
            Text = PlaceName(note),
            FontSize = 12,
            Opacity = 0.66,
        });
        var draft = _noteDrafts.Open(id, new(Format.Text(note, "title"), Format.Text(note, "notes")));
        var text = new TextBox { Header = "Title", Text = draft.Title };
        var content = new TextBox { Header = "Note", Text = draft.Notes, AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap, MinHeight = 320 };
        var saveState = new TextBlock { FontSize = 12, Opacity = 0.7, TextWrapping = TextWrapping.Wrap };
        bool applyingSavedTitle = false;
        void EditDraft()
        {
            if (applyingSavedTitle) return;
            _noteDrafts.Edit(id, new(text.Text, content.Text));
            QueueNoteSave(id);
        }
        text.TextChanged += (_, _) => EditDraft();
        content.TextChanged += (_, _) => EditDraft();
        _draftStatusChanged = changedId =>
        {
            if (changedId != id || _noteDrafts.Get(id) is not { } entry) return;
            saveState.Text = entry.Error is not null ? "Not saved: " + entry.Error
                : entry.Saving ? "Saving…" : entry.Dirty ? "Waiting to save…" : entry.HasSaved ? "Saved" : "Changes save automatically";
            if (!entry.Dirty && !entry.Saving && text.Text != entry.Value.Title)
            {
                int caret = text.SelectionStart;
                applyingSavedTitle = true;
                text.Text = entry.Value.Title;
                text.Select(Math.Min(caret, text.Text.Length), 0);
                applyingSavedTitle = false;
            }
        };
        _noteDrafts.Changed += _draftStatusChanged;
        _draftStatusChanged(id);
        body.Children.Add(text);
        var preview = new Border { MinHeight = 320, Padding = new Thickness(Theme.SpaceS) };
        var modeRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        var writeMode = new Microsoft.UI.Xaml.Controls.Primitives.ToggleButton { Content = "Write" };
        var previewMode = new Microsoft.UI.Xaml.Controls.Primitives.ToggleButton { Content = "Preview" };
        void ShowMode(bool read)
        {
            _previewNote = read;
            writeMode.IsChecked = !read; previewMode.IsChecked = read;
            content.Visibility = read ? Visibility.Collapsed : Visibility.Visible;
            preview.Visibility = read ? Visibility.Visible : Visibility.Collapsed;
            preview.Child = read ? NotePreview.Create(content.Text) : null;
        }
        writeMode.Click += (_, _) => ShowMode(false);
        previewMode.Click += (_, _) => ShowMode(true);
        modeRow.Children.Add(writeMode); modeRow.Children.Add(previewMode);
        var formatting = new MenuFlyout();
        void AddFormat(string label, string before, string after, string placeholder, bool line = false)
        {
            var item = new MenuFlyoutItem { Text = label };
            item.Click += (_, _) =>
            {
                ShowMode(false);
                var edit = NoteFormatting.Apply(content.Text, content.SelectionStart, content.SelectionLength,
                    before, after, placeholder, line);
                content.Select(edit.Start, edit.Length);
                content.SelectedText = edit.Replacement;
                content.Select(edit.SelectionStart, edit.SelectionLength);
                content.Focus(FocusState.Programmatic);
            };
            formatting.Items.Add(item);
        }
        AddFormat("Heading", "## ", "", "Heading", line: true);
        AddFormat("Bold", "**", "**", "text");
        AddFormat("Italic", "*", "*", "text");
        AddFormat("Bulleted list", "- ", "", "List item", line: true);
        AddFormat("Checklist", "- [ ] ", "", "To do", line: true);
        AddFormat("Quote", "> ", "", "Quote", line: true);
        AddFormat("Code", "`", "`", "code");
        var format = Buttons.Secondary("Format", ActionIcon.Edit, (_, _) => { }, small: true);
        format.Flyout = formatting;
        modeRow.Children.Add(format);
        var saveShortcut = new Microsoft.UI.Xaml.Input.KeyboardAccelerator
        {
            Key = VirtualKey.S, Modifiers = VirtualKeyModifiers.Control,
        };
        saveShortcut.Invoked += async (_, args) => { args.Handled = true; await SaveNoteAsync(id); };
        body.KeyboardAccelerators.Add(saveShortcut);
        body.Children.Add(modeRow);
        body.Children.Add(content);
        body.Children.Add(preview);
        body.Children.Add(saveState);
        ShowMode(_previewNote);
        var created = Format.Long(note, "createdAtMs");
        if (created > 0)
        {
            body.Children.Add(new TextBlock
            {
                Text = DateTimeOffset.FromUnixTimeMilliseconds(created).LocalDateTime.ToString("f"),
                FontSize = 12,
                Opacity = 0.66,
            });
        }
        var saveRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        saveRow.Children.Add(Buttons.Primary(
            "Save", ActionIcon.Save,
            async (_, _) => await SaveNoteAsync(id)));
        body.Children.Add(saveRow);

        var archived = Format.Text(note, "column") == "archive";
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        actions.Children.Add(ActionIconGlyph.Button(
            archived ? "Restore" : "Archive",
            archived ? ActionIcon.Restore : ActionIcon.Archive,
            async (_, _) => await SetArchivedAsync(id, archived: !archived)));
        if (!_confirmDelete)
        {
            actions.Children.Add(ActionIconGlyph.Button(
                "Delete", ActionIcon.Delete, (_, _) =>
                {
                    _confirmDelete = true;
                    RenderDetail();
                }));
        }
        else
        {
            actions.Children.Add(ActionIconGlyph.Button(
                "Keep it", ActionIcon.Back, (_, _) =>
                {
                    _confirmDelete = false;
                    RenderDetail();
                }));
        }
        body.Children.Add(actions);
        if (_confirmDelete)
        {
            body.Children.Add(new TextBlock
            {
                Text = "Archiving keeps it. Deleting does not.",
                TextWrapping = TextWrapping.Wrap,
            });
            var confirmRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
            confirmRow.Children.Add(ActionIconGlyph.Button(
                "Delete note", ActionIcon.Delete, async (_, _) => await DeleteAsync(id)));
            body.Children.Add(confirmRow);
        }

        if (!archived)
        {
            var convertBody = new StackPanel { Spacing = Theme.SpaceS };
            convertBody.Children.Add(new TextBlock
            {
                Text = "This note becomes a card on the board.",
                FontSize = 12,
                Opacity = 0.66,
                TextWrapping = TextWrapping.Wrap,
            });
            ComboBox? folderBox = null;
            if (_workspaceId is null)
            {
                folderBox = new ComboBox { MinWidth = 160 };
                var names = new List<string> { "Unassigned" };
                names.AddRange(_folders.Select(f => f.Name));
                folderBox.ItemsSource = names;
                var current = Format.Text(note, "workspaceId");
                var index = _folders.FindIndex(f => f.Id == current);
                folderBox.SelectedIndex = index >= 0 ? index + 1 : 0;
                convertBody.Children.Add(folderBox);
            }
            var box = folderBox;
            convertBody.Children.Add(Buttons.Secondary(
                "Make a task", ActionIcon.Move,
                async (_, _) =>
                {
                    var folderId = _workspaceId ?? ComboFolderId(box);
                    await ConvertAsync(id, folderId);
                }));
            body.Children.Add(convertBody);
        }
        return Chrome.Card("Note", body, PlaceName(note));
    }

    private string ComboFolderId(ComboBox? box)
    {
        var index = box?.SelectedIndex ?? 0;
        if (index >= 1 && index - 1 < _folders.Count)
        {
            return _folders[index - 1].Id;
        }
        return "";
    }

    private async Task SaveAsync()
    {
        var text = _draft.Text.Trim();
        if (text.Length == 0 || _saving)
        {
            return;
        }
        _saving = true;
        try
        {
            await CallTodoAsync(
                "todo.create",
                new JsonObject
                {
                    ["title"] = text,
                    ["kind"] = "note",
                    ["notes"] = "",
                    ["column"] = "backlog",
                    ["backend"] = "",
                    ["workspaceId"] = DestinationId(),
                    ["budgetSeconds"] = 0,
                });
            _draft.Text = "";
            _draft.Focus(FocusState.Programmatic);
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
            return;
        }
        finally
        {
            _saving = false;
        }
        await LoadAsync();
    }

    private async void QueueNoteSave(string id)
    {
        if (_saveDelays.Remove(id, out var previous)) previous.Cancel();
        using var delay = new CancellationTokenSource();
        _saveDelays[id] = delay;
        try
        {
            await Task.Delay(650, delay.Token);
            if (_saveDelays.GetValueOrDefault(id) == delay) _saveDelays.Remove(id);
            await SaveNoteAsync(id);
        }
        catch (OperationCanceledException) { }
        finally
        {
            if (_saveDelays.GetValueOrDefault(id) == delay) _saveDelays.Remove(id);
        }
    }

    private async Task SaveNoteAsync(string id)
    {
        if (_saveDelays.Remove(id, out var delay)) delay.Cancel();
        await _noteDrafts.SaveAsync(id, async value =>
        {
            await CallTodoAsync("todo.update", new JsonObject { ["id"] = id, ["title"] = value.Title, ["notes"] = value.Notes });
            var card = _cards.FirstOrDefault(card => Format.Text(card, "id") == id);
            if (card is JsonObject saved)
            {
                saved["title"] = value.Title;
                saved["notes"] = value.Notes;
            }
        });
        // Keep the mounted editor and its selection intact during autosave.
        RenderList();
    }

    private async Task SetArchivedAsync(string id, bool archived)
    {
        try
        {
            await CallTodoAsync(
                "todo.update",
                new JsonObject { ["id"] = id, ["column"] = archived ? "archive" : "backlog" });
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
            return;
        }
        await LoadAsync();
    }

    private async Task ConvertAsync(string id, string folderId)
    {
        await SaveNoteAsync(id);
        if (_noteDrafts.Get(id)?.Error is { } saveError) { Banner(saveError); return; }
        var note = SelectedNote();
        string prompt;
        if (note is not null && Format.Text(note, "id") == id)
        {
            var extra = Format.Text(note, "notes");
            prompt = string.IsNullOrEmpty(extra) ? Format.Text(note, "title") : extra;
        }
        else
        {
            prompt = "";
            foreach (var card in _cards)
            {
                if (Format.Text(card, "id") == id)
                {
                    var extra = Format.Text(card, "notes");
                    prompt = string.IsNullOrEmpty(extra) ? Format.Text(card, "title") : extra;
                    break;
                }
            }
        }
        try
        {
            await CallTodoAsync(
                "todo.update",
                new JsonObject
                {
                    ["id"] = id,
                    ["column"] = "backlog",
                    ["kind"] = "task",
                    ["notes"] = prompt,
                    ["workspaceId"] = folderId,
                });
            if (_selectedId == id)
            {
                _selectedId = null;
            }
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
            return;
        }
        await LoadAsync();
    }

    private async Task DeleteAsync(string id)
    {
        if (_saveDelays.Remove(id, out var delay)) delay.Cancel();
        if (_noteDrafts.Get(id)?.Pending is Task pending) await pending;
        try
        {
            await CallTodoAsync("todo.remove", new JsonObject { ["id"] = id });
            _selectedId = null;
            _confirmDelete = false;
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
            return;
        }
        await LoadAsync();
    }
}
