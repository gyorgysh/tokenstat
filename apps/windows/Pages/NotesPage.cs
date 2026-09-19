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
internal sealed class NotesPage : Page, IInspectorContent
{
    private readonly string? _workspaceId;
    private readonly ContentControl _barSlot = new()
    {
        HorizontalAlignment = HorizontalAlignment.Stretch,
        HorizontalContentAlignment = HorizontalAlignment.Stretch,
    };
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
    private bool _gridLayout = true;
    private bool _showingArchive;
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
        _root.Children.Add(_scopeHost);
        _root.Children.Add(_listHost);
        _listHost.Children.Add(Motion.SkeletonCard());
        var scroller = new ScrollViewer
        {
            Padding = new Thickness(Theme.SpaceL),
            Content = _root,
        };
        var layout = new Grid();
        layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        layout.RowDefinitions.Add(new RowDefinition
        {
            Height = new GridLength(1, GridUnitType.Star),
        });
        layout.Children.Add(_barSlot);
        Grid.SetRow(scroller, 1);
        layout.Children.Add(scroller);
        Content = layout;
        RebuildChrome();
        RenderDetail();
        Loaded += async (_, _) => await LoadAsync();
    }

    /// <summary>
    /// The inspector column content. Selection and reloads replace its
    /// children, so the column stays live without the shell asking again.
    /// </summary>
    public UIElement? Inspector => _detailHost;

    private void RebuildChrome()
    {
        UIElement? scope = null;
        if (_workspaceId is not null)
        {
            var folder = _folders.FirstOrDefault(f => f.Id == _workspaceId);
            scope = Chrome.ScopeChip(string.IsNullOrEmpty(folder.Name) ? "Folder" : folder.Name);
        }
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
        _barSlot.Content = DetailBar.View(
            scope: scope,
            trailing: new List<UIElement>
            {
                Buttons.ToolbarIcon(
                    ActionIcon.Refresh,
                    "Reload notes",
                    async (_, _) => await LoadAsync()),
                Buttons.ToolbarIcon(
                    ActionIcon.Create,
                    "Write a note",
                    (_, _) =>
                    {
                        _showingArchive = false;
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
            });
    }

    private async Task LoadAsync()
    {
        try
        {
            var cardsTask = AppServices.Host.CallAsync(
                "todo.list", new JsonObject { ["includeArchived"] = true });
            var foldersTask = AppServices.Host.CallAsync("workspace.list", new JsonObject());
            await Task.WhenAll(cardsTask, foldersTask);
            _cards = cardsTask.Result as JsonArray
                ?? cardsTask.Result["cards"] as JsonArray
                ?? new JsonArray();
            _folders = ReadFolders(foldersTask.Result);
            _loaded = true;
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
            return;
        }
        RebuildChrome();
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
        RebuildChrome();
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
    /// One line, always at the top, always ready. The plus in the bar focuses
    /// it, and Save is always visible so the field is not the only way in.
    /// </summary>
    private void RenderComposer()
    {
        _composerHost.Children.Clear();
        if (_showingArchive)
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
        _libraryHost.Children.Clear();
        var shown = ShownNotes();
        var bar = new Grid { ColumnSpacing = Theme.SpaceM };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var title = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Theme.SpaceS,
            VerticalAlignment = VerticalAlignment.Center,
        };
        title.Children.Add(new TextBlock
        {
            Text = _showingArchive ? "Archived notes" : "Your notes",
            FontSize = Fonts.Title3,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
        });
        _countText = new TextBlock
        {
            Text = shown.Count.ToString(),
            FontSize = 12,
            Opacity = 0.66,
            VerticalAlignment = VerticalAlignment.Center,
        };
        title.Children.Add(_countText);
        bar.Children.Add(title);
        var search = Chrome.SearchField("Search notes", text =>
        {
            _search = text ?? "";
            if (_countText is not null)
            {
                _countText.Text = ShownNotes().Count.ToString();
            }
            RenderList();
        });
        search.Text = _search;
        search.MinWidth = 160;
        search.MaxWidth = 300;
        search.HorizontalAlignment = HorizontalAlignment.Right;
        search.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(search, 1);
        bar.Children.Add(search);
        var sort = new ComboBox { MinWidth = 130, VerticalAlignment = VerticalAlignment.Center };
        sort.ItemsSource = new[] { "Newest first", "Title A–Z" };
        sort.SelectedIndex = _sortByTitle ? 1 : 0;
        sort.SelectionChanged += (_, _) =>
        {
            _sortByTitle = sort.SelectedIndex == 1;
            RenderList();
        };
        Grid.SetColumn(sort, 2);
        bar.Children.Add(sort);
        _libraryHost.Children.Add(bar);
    }

    private void RenderScopes()
    {
        _scopeHost.Children.Clear();
        if (_workspaceId is not null)
        {
            return;
        }
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        row.Children.Add(Chrome.ChoiceChip(
            $"All · {CountIn("", _showingArchive)}", _picked == "",
            () =>
            {
                _picked = "";
                _selectedId = null;
                RenderAll();
                return Task.CompletedTask;
            }));
        row.Children.Add(Chrome.ChoiceChip(
            $"Unassigned · {CountIn(UnassignedPick, _showingArchive)}", _picked == UnassignedPick,
            () =>
            {
                _picked = UnassignedPick;
                _selectedId = null;
                RenderAll();
                return Task.CompletedTask;
            }));
        foreach (var folder in _folders)
        {
            var id = folder.Id;
            row.Children.Add(Chrome.ChoiceChip(
                $"{folder.Name} · {CountIn(id, _showingArchive)}", _picked == id,
                () =>
                {
                    _picked = id;
                    _selectedId = null;
                    RenderAll();
                    return Task.CompletedTask;
                }));
        }
        _scopeHost.Children.Add(new ScrollViewer
        {
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Content = row,
        });
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
        body.Children.Add(foot);
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

    private void RenderDetail()
    {
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
        var text = new TextBox
        {
            Text = Format.Text(note, "title"),
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            MinHeight = 120,
        };
        body.Children.Add(text);
        body.Children.Add(new TextBlock
        {
            Text = "A note is its text, so this is the whole of it.",
            FontSize = 12,
            Opacity = 0.55,
            TextWrapping = TextWrapping.Wrap,
        });
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
            async (_, _) => await RenameAsync(id, text.Text)));
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
            await AppServices.Host.CallAsync(
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

    private async Task RenameAsync(string id, string text)
    {
        var clean = text.Trim();
        if (clean.Length == 0)
        {
            Banner("A note needs its text. Delete it instead of emptying it.");
            return;
        }
        try
        {
            await AppServices.Host.CallAsync(
                "todo.update", new JsonObject { ["id"] = id, ["title"] = clean });
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
            return;
        }
        await LoadAsync();
    }

    private async Task SetArchivedAsync(string id, bool archived)
    {
        try
        {
            await AppServices.Host.CallAsync(
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
            await AppServices.Host.CallAsync(
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
        try
        {
            await AppServices.Host.CallAsync("todo.remove", new JsonObject { ["id"] = id });
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
