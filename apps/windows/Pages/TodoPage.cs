// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Text.Json.Nodes;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Tokenstat.Navigation;
using Tokenstat.Notifications;
using Windows.ApplicationModel.DataTransfer;

namespace Tokenstat.Pages;

/// <summary>
/// Three-column task board with a full detail editor. Matches the Mac
/// workbench: the same columns, filters, run placement, receipts, and the
/// rule that a lost answer is checked before anything runs twice.
/// </summary>
internal sealed class TodoPage : Page, IInspectorContent, IToolbarItems
{
    private readonly string? _scopeWorkspaceId;
    private readonly StackPanel _root = new() { Spacing = Theme.SpaceL };
    private readonly StackPanel _bannerHost = new() { Spacing = Theme.SpaceS };
    private readonly StackPanel _boardHost = new() { Spacing = Theme.SpaceL };
    private readonly StackPanel _detailHost = new()
    {
        Spacing = Theme.SpaceL,
        Padding = new Thickness(Theme.SpaceM),
    };
    private readonly TextBox _quickTitle = new() { PlaceholderText = "New task" };
    private readonly Button _quickAdd;
    private readonly ComboBox _folderFilter = new()
    {
        MinWidth = 160,
        VerticalAlignment = VerticalAlignment.Center,
    };
    private readonly ComboBox _agentFilter = new() { MinWidth = 140 };
    private readonly ComboBox _attentionFilter = new() { MinWidth = 150 };
    private readonly TextBox _search = new() { PlaceholderText = "Search tasks", MinWidth = 180 };

    private JsonArray _cards = new();
    private JsonArray _runs = new();
    private List<(string Id, string Name)> _folders = new();
    private List<(string Id, string Label)> _backends = new();
    private long? _protocol;
    private ulong _defaultBudgetSeconds = 10_800;
    private string _query = "";
    private bool _showArchive;
    private bool _newestFirst = true;
    private bool _working;
    private string? _selectedId;
    private string? _pendingCreateOp;
    private string? _pendingRunOp;
    private string? _runError;
    private string? _conflictId;
    private bool _confirmDelete;
    private bool _detailDirty;
    private ulong? _detailRevision;
    private TaskDraft? _draft;
    private TextBox? _dTitle;
    private TextBox? _dPrompt;
    private ComboBox? _dFolder;
    private ComboBox? _dPriority;
    private ComboBox? _dBackend;
    private TextBox? _dModel;
    private TextBox? _dEffort;
    private TextBox? _dBudget;
    private ComboBox? _dUnit;
    private CheckBox? _dNoLimit;
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? _poll;

    /// <summary>
    /// The user's unsent field values. Kept across a conflict reload so Save
    /// anyway retries the same draft and Take saved throws it away.
    /// </summary>
    private sealed class TaskDraft
    {
        public string Title = "";
        public string Prompt = "";
        public string FolderId = "";
        public string Priority = "normal";
        public string BackendId = "";
        public string Model = "";
        public string Effort = "";
        public string BudgetText = "180";
        public string BudgetUnit = "minutes";
        public bool NoLimit;
    }

    private static readonly string[] Columns = ["backlog", "doing", "done"];
    private static readonly string[] ColumnTitles = ["To Do", "Doing", "Done"];

    public TodoPage(string? workspaceId = null)
    {
        _scopeWorkspaceId = workspaceId;
        _quickAdd = ActionIconGlyph.Button("Add", ActionIcon.Create, async (_, _) => await CreateAsync());

        _attentionFilter.ItemsSource = new[] { "All tasks", "Running", "Needs attention", "High priority" };
        _attentionFilter.SelectedIndex = 0;
        _attentionFilter.SelectionChanged += (_, _) => RenderBoard();
        _agentFilter.SelectionChanged += (_, _) => RenderBoard();
        _folderFilter.SelectionChanged += (_, _) => RenderBoard();
        _search.TextChanged += (_, _) =>
        {
            _query = _search.Text ?? "";
            RenderBoard();
        };

        var quick = new Grid { ColumnSpacing = Theme.SpaceS };
        quick.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        quick.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(_quickAdd, 1);
        quick.Children.Add(_quickTitle);
        quick.Children.Add(_quickAdd);

        _root.Children.Add(quick);
        _root.Children.Add(FilterBar());
        _root.Children.Add(_bannerHost);
        _root.Children.Add(_boardHost);
        // A wireframe until the first load lands. RenderBoard clears the
        // host, so real content replaces it, like Home's skeleton.
        _boardHost.Children.Add(Motion.SkeletonCard());
        Content = new ScrollViewer
        {
            Padding = new Thickness(Theme.SpaceM),
            Content = _root,
        };
        RenderDetail();
        Loaded += async (_, _) =>
        {
            await LoadAsync();
            StartPolling();
        };
        Unloaded += (_, _) => StopPolling();
    }

    /// <summary>
    /// The inspector column content: the selected task's detail, history, and
    /// run views. Selection and reloads replace its children, so the column
    /// stays live without the shell asking again.
    /// </summary>
    public UIElement? Inspector => _detailHost;

    public event Action? ToolbarChanged;

    /// <summary>
    /// The folder this board belongs to, or null on the global board, which
    /// gets the folder picker in the actions instead.
    /// </summary>
    public UIElement? ToolbarScope
    {
        get
        {
            if (_scopeWorkspaceId is null)
            {
                return null;
            }
            return Chrome.ScopeChip(FolderLabel(_scopeWorkspaceId));
        }
    }

    /// <summary>
    /// The Mac board's bar: the folder picker on the global board only, then
    /// new, the newest-or-board sort, and the archive, with this screen's
    /// reload first.
    /// </summary>
    public IList<UIElement> ToolbarActions()
    {
        var actions = new List<UIElement>
        {
            Buttons.ToolbarIcon(
                ActionIcon.Refresh,
                "Reload tasks",
                async (_, _) =>
                {
                    LogoRefresh.Began();
                    await LoadAsync();
                }),
        };
        if (_scopeWorkspaceId is null)
        {
            actions.Add(_folderFilter);
        }
        actions.Add(Buttons.ToolbarIcon(
            ActionIcon.Create,
            "Add a card to To Do",
            (_, _) => _quickTitle.Focus(FocusState.Programmatic)));
        var sort = SegmentedCapsule.View(
            new List<(string Value, string Label, ActionIcon? Glyph)>
            {
                ("newest", "Newest", null),
                ("board", "Your order", null),
            },
            _newestFirst ? "newest" : "board",
            value =>
            {
                _newestFirst = value == "newest";
                RenderBoard();
                RaiseToolbarChangedIfNeeded();
                return Task.CompletedTask;
            });
        sort.Width = 220;
        sort.VerticalAlignment = VerticalAlignment.Center;
        actions.Add(sort);
        int archived = ArchivedCount();
        var archive = Buttons.ToolbarIcon(
            _showArchive ? ActionIcon.Restore : ActionIcon.Archive,
            _showArchive ? "Show Done"
                : archived == 0 ? "No archived cards"
                : "Show " + archived + " archived card" + (archived == 1 ? "" : "s"),
            (_, _) =>
            {
                _showArchive = !_showArchive;
                RenderBoard();
                RaiseToolbarChangedIfNeeded();
            },
            _showArchive);
        archive.IsEnabled = archived > 0 || _showArchive;
        actions.Add(archive);
        return actions;
    }

    private string _toolbarKey = "";

    /// <summary>
    /// Rebuild the bar only when something on it changed. The folder filter
    /// lives in the bar and holds its selection there, and the quiet poll
    /// re-reads every two seconds while a run is live: rebuilding around an
    /// open dropdown would collapse it under the reader's hand.
    /// </summary>
    private void RaiseToolbarChangedIfNeeded()
    {
        var key = _showArchive + "|" + _newestFirst + "|" + _folders.Count + "|" + ArchivedCount();
        if (key == _toolbarKey)
        {
            return;
        }
        _toolbarKey = key;
        ToolbarChanged?.Invoke();
    }

    private int ArchivedCount()
    {
        int count = 0;
        foreach (var card in _cards)
        {
            if (Format.Text(card, "kind") != "note" && Format.Text(card, "column") == "archive")
            {
                count++;
            }
        }
        return count;
    }

    private UIElement FilterBar()
    {
        var bar = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceM };
        bar.Children.Add(Labeled("Agent", _agentFilter));
        bar.Children.Add(Labeled("Showing", _attentionFilter));
        bar.Children.Add(Labeled("Search", _search));
        return bar;
    }

    private static UIElement Labeled(string label, UIElement content)
    {
        var stack = new StackPanel { Spacing = Theme.SpaceXs };
        stack.Children.Add(new TextBlock
        {
            Text = label.ToUpperInvariant(),
            FontSize = 11,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Opacity = 0.58,
        });
        stack.Children.Add(content);
        return stack;
    }

    private void StartPolling()
    {
        StopPolling();
        _poll = DispatcherQueue.CreateTimer();
        _poll.Interval = TimeSpan.FromSeconds(2);
        _poll.Tick += (_, _) =>
        {
            if (AnyRunning() && !_working)
            {
                _ = LoadAsync(quiet: true);
            }
        };
        _poll.Start();
    }

    private void StopPolling()
    {
        if (_poll is not null)
        {
            _poll.Stop();
            _poll = null;
        }
    }

    private bool AnyRunning()
    {
        foreach (var card in _cards)
        {
            if (WorkbenchOps.IsRunning(card?["delegate"]))
            {
                return true;
            }
        }
        return false;
    }

    /// <summary>
    /// One board method against this screen's folder, local or remote. A
    /// remote folder travels as remote.call with the peer's own folder id.
    /// Params are copied, never mutated, so a retry cannot forward an already
    /// rewritten id. The global board has no folder and always stays local.
    /// </summary>
    private Task<JsonNode> CallTodoAsync(string method, JsonNode? parameters = null)
    {
        if (_scopeWorkspaceId is null
            || !RemoteWorkspaces.TrySplit(_scopeWorkspaceId, out var peer, out var inner))
        {
            return AppServices.Host.CallAsync(method, parameters);
        }
        var forwarded = parameters is null
            ? new JsonObject()
            : (JsonObject)JsonNode.Parse(parameters.ToJsonString())!;
        if (Format.Text(forwarded, "workspaceId") == _scopeWorkspaceId)
        {
            forwarded["workspaceId"] = inner;
        }
        return RemoteWorkspaces.CallOnPeerAsync(peer, method, forwarded);
    }

    /// <summary>
    /// The protocol of the host that owns these cards: the peer's sessionless
    /// protocol for a remote folder, the local one otherwise. Null means
    /// unknown, and unknown means assume the feature is there.
    /// </summary>
    private async Task<long?> ProtocolAsync()
    {
        if (_scopeWorkspaceId is not null
            && RemoteWorkspaces.TrySplit(_scopeWorkspaceId, out var peer, out _))
        {
            return await RemoteFeatureGate.PeerProtocolAsync(peer);
        }
        return await WorkbenchOps.ProtocolAsync();
    }

    private async Task LoadAsync(bool quiet = false)
    {
        if (!quiet)
        {
            _working = true;
        }
        try
        {
            _protocol = await ProtocolAsync();
            var cardsTask = CallTodoAsync(
                "todo.list", new JsonObject { ["includeArchived"] = true });
            var runsTask = CallTodoAsync("automation.runs", new JsonObject());
            var foldersTask = AppServices.Host.CallAsync("workspace.list", new JsonObject());
            var backendsTask = CallTodoAsync("automation.backends", new JsonObject());
            var queueTask = CallTodoAsync("automation.queue", new JsonObject());
            await Task.WhenAll(cardsTask, runsTask, foldersTask, backendsTask, queueTask);
            _cards = cardsTask.Result as JsonArray
                ?? cardsTask.Result["cards"] as JsonArray
                ?? new JsonArray();
            _runs = Format.Items(runsTask.Result) ?? new JsonArray();
            RunNotifications.Shared.SettleAutomations(_runs);
            _folders = ReadFolders(foldersTask.Result);
            if (_scopeWorkspaceId is not null
                && RemoteWorkspaces.TrySplit(_scopeWorkspaceId, out _, out var inner))
            {
                // Cards from the peer carry its own folder id. Namespace them
                // to this page's folder id so the scope filter below keeps
                // matching, and list the folder itself so its name resolves.
                foreach (var card in _cards)
                {
                    if (card is JsonObject obj && Format.Text(obj, "workspaceId") == inner)
                    {
                        obj["workspaceId"] = _scopeWorkspaceId;
                    }
                }
                if (RemoteWorkspaces.CachedFolder(_scopeWorkspaceId) is RemoteFolder cached
                    && _folders.All(f => f.Id != _scopeWorkspaceId))
                {
                    _folders.Add((_scopeWorkspaceId, cached.DisplayName));
                }
            }
            _backends = ReadBackends(backendsTask.Result);
            var budget = queueTask.Result["defaultBudgetSeconds"];
            if (budget is not null)
            {
                try { _defaultBudgetSeconds = budget.GetValue<ulong>(); } catch { /* keep */ }
            }
            RefreshFilterLists();
            RaiseToolbarChangedIfNeeded();
            RenderBoard();
            RenderDetailSafe(quiet);
        }
        catch (Exception ex)
        {
            if (!quiet)
            {
                Banner(ex.Message);
            }
        }
        finally
        {
            if (!quiet)
            {
                _working = false;
            }
        }
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

    private static List<(string Id, string Label)> ReadBackends(JsonNode? listed)
    {
        var outList = new List<(string Id, string Label)>();
        foreach (var backend in Format.Items(listed) ?? new JsonArray())
        {
            var id = Format.Text(backend, "id");
            if (string.IsNullOrEmpty(id))
            {
                continue;
            }
            outList.Add((id, Format.Text(backend, "label", Format.Text(backend, "name", id))));
        }
        return outList;
    }

    private void RefreshFilterLists()
    {
        var folderNames = new List<string> { "All folders", "Uncategorized" };
        folderNames.AddRange(_folders.Select(f => f.Name));
        _folderFilter.ItemsSource = folderNames;
        if (_scopeWorkspaceId is not null)
        {
            var index = _folders.FindIndex(f => f.Id == _scopeWorkspaceId);
            _folderFilter.SelectedIndex = index >= 0 ? index + 2 : 0;
            _folderFilter.IsEnabled = false;
        }
        else if (_folderFilter.SelectedIndex < 0)
        {
            _folderFilter.SelectedIndex = 0;
        }
        var agentNames = new List<string> { "All agents" };
        agentNames.AddRange(_backends.Select(b => b.Label));
        _agentFilter.ItemsSource = agentNames;
        if (_agentFilter.SelectedIndex < 0)
        {
            _agentFilter.SelectedIndex = 0;
        }
    }

    private string SelectedFolderId()
    {
        if (_scopeWorkspaceId is not null)
        {
            return _scopeWorkspaceId;
        }
        var index = _folderFilter.SelectedIndex;
        if (index == 1)
        {
            return "";
        }
        if (index >= 2 && index - 2 < _folders.Count)
        {
            return _folders[index - 2].Id;
        }
        return "\0all";
    }

    private string SelectedBackendId()
    {
        var index = _agentFilter.SelectedIndex;
        if (index >= 1 && index - 1 < _backends.Count)
        {
            return _backends[index - 1].Id;
        }
        return "";
    }

    private List<JsonNode?> VisibleCards(string column)
    {
        var folder = SelectedFolderId();
        var backend = SelectedBackendId();
        var attention = _attentionFilter.SelectedIndex;
        var words = _query.Split((char[])[' ', '\t'], StringSplitOptions.RemoveEmptyEntries);
        var list = new List<JsonNode?>();
        foreach (var card in _cards)
        {
            if (Format.Text(card, "kind") == "note")
            {
                continue;
            }
            if (Format.Text(card, "column") != column)
            {
                continue;
            }
            var workspaceId = Format.Text(card, "workspaceId");
            if (folder == "")
            {
                if (!string.IsNullOrEmpty(workspaceId))
                {
                    continue;
                }
            }
            else if (folder != "\0all" && workspaceId != folder)
            {
                continue;
            }
            if (!string.IsNullOrEmpty(backend) && Format.Text(card, "backend") != backend)
            {
                continue;
            }
            var status = Format.Text(card?["delegate"], "status");
            var matchesAttention = attention switch
            {
                1 => WorkbenchOps.IsRunning(card?["delegate"]),
                2 => status == "error",
                3 => Format.Text(card, "priority") == "high",
                _ => true,
            };
            if (!matchesAttention)
            {
                continue;
            }
            var haystack = Format.Text(card, "title") + "\n" + Format.Text(card, "notes");
            if (!words.All(w => haystack.Contains(w, StringComparison.OrdinalIgnoreCase)))
            {
                continue;
            }
            list.Add(card);
        }
        list.Sort((a, b) =>
        {
            if (_newestFirst && Format.Long(a, "createdAtMs") != Format.Long(b, "createdAtMs"))
            {
                return Format.Long(b, "createdAtMs").CompareTo(Format.Long(a, "createdAtMs"));
            }
            return Format.Long(a, "order").CompareTo(Format.Long(b, "order"));
        });
        return list;
    }

    private void Banner(string text)
    {
        _bannerHost.Children.Insert(0, Chrome.Banner(text, Theme.Danger, Symbol.Important));
        while (_bannerHost.Children.Count > 3)
        {
            _bannerHost.Children.RemoveAt(_bannerHost.Children.Count - 1);
        }
    }

    private void Notice(string text)
    {
        _bannerHost.Children.Insert(0, Chrome.Toast(text, BannerSeverity.Success));
        while (_bannerHost.Children.Count > 3)
        {
            _bannerHost.Children.RemoveAt(_bannerHost.Children.Count - 1);
        }
    }

    private void RenderBoard()
    {
        _boardHost.Children.Clear();
        if (_cards.Count == 0)
        {
            _boardHost.Children.Add(EmptyState.View(
                _showArchive ? "No archived tasks" : "No tasks yet",
                "Create a task or adjust the filters to see more work.",
                EmptyArtKind.Tasks,
                ActionIconGlyph.Button("New task", ActionIcon.Create, (_, _) =>
                    _quickTitle.Focus(FocusState.Programmatic))));
            return;
        }
        if (_showArchive)
        {
            _boardHost.Children.Add(Column("archive", "Archive"));
            return;
        }
        var grid = new Grid { ColumnSpacing = Theme.SpaceM };
        for (var i = 0; i < Columns.Length; i++)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        }
        for (var i = 0; i < Columns.Length; i++)
        {
            var column = Column(Columns[i], ColumnTitles[i]);
            Grid.SetColumn(column, i);
            grid.Children.Add(column);
        }
        _boardHost.Children.Add(grid);
    }

    private FrameworkElement Column(string column, string title)
    {
        var cards = VisibleCards(column);
        var list = new StackPanel { Spacing = Theme.SpaceS };
        foreach (var card in cards)
        {
            if (card is null)
            {
                continue;
            }
            list.Children.Add(CardRow(card));
        }
        if (list.Children.Count == 0)
        {
            list.Children.Add(new TextBlock
            {
                Text = _cards.Count == 0 ? "No tasks yet" : "No tasks",
                Opacity = 0.6,
            });
        }
        var body = new StackPanel { Spacing = Theme.SpaceS };
        body.Children.Add(new TextBlock
        {
            Text = $"{title} ({cards.Count})",
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        body.Children.Add(list);
        var frame = new Border
        {
            Background = Theme.PanelBrush,
            BorderBrush = Theme.BorderBrush,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(Theme.CardRadius),
            Padding = new Thickness(Theme.CardPadding),
            Child = body,
            AllowDrop = true,
            MinHeight = 120,
        };
        frame.DragOver += (_, e) =>
        {
            if (e.DataView.Contains(StandardDataFormats.Text))
            {
                e.AcceptedOperation = DataPackageOperation.Move;
            }
        };
        frame.Drop += async (_, e) =>
        {
            if (!e.DataView.Contains(StandardDataFormats.Text))
            {
                return;
            }
            var id = await e.DataView.GetTextAsync();
            await MoveAsync(id, column);
        };
        return frame;
    }

    private UIElement CardRow(JsonNode card)
    {
        var id = Format.Text(card, "id");
        var title = Format.Text(card, "title", "(untitled)");
        var backend = Format.Text(card, "backend");
        var priority = Format.Text(card, "priority");
        var status = Format.Text(card?["delegate"], "status");
        var line = string.IsNullOrEmpty(backend) ? FolderLabel(Format.Text(card, "workspaceId")) : backend;
        if (!string.IsNullOrEmpty(status))
        {
            line += " · " + WorkbenchOps.RunLabel(status);
        }
        if (priority == "high")
        {
            line += " · High priority";
        }
        var body = new StackPanel { Spacing = 2 };
        body.Children.Add(new TextBlock
        {
            Text = title,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
        });
        body.Children.Add(new TextBlock
        {
            Text = line,
            FontSize = 12,
            Opacity = 0.68,
            TextWrapping = TextWrapping.Wrap,
        });
        var frame = new Border
        {
            Background = Theme.AccentSoftBrush,
            BorderBrush = Theme.BorderBrush,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(Theme.CardRadius),
            Padding = new Thickness(Theme.SpaceM),
            Child = body,
            CanDrag = true,
        };
        frame.DragStarting += (_, e) =>
        {
            e.Data.SetText(id);
            e.Data.RequestedOperation = DataPackageOperation.Move;
        };
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
            _conflictId = null;
            _runError = null;
            _detailDirty = false;
            _draft = null;
            _detailRevision = WorkbenchOps.Revision(card);
            RenderDetail();
        };
        return button;
    }

    private string FolderLabel(string workspaceId)
    {
        if (string.IsNullOrEmpty(workspaceId))
        {
            return "Uncategorized";
        }
        return _folders.FirstOrDefault(f => f.Id == workspaceId).Name ?? "Folder";
    }

    private async Task CreateAsync()
    {
        var title = _quickTitle.Text.Trim();
        if (title.Length == 0 || _working)
        {
            return;
        }
        _working = true;
        _quickAdd.IsEnabled = false;
        try
        {
            var folder = SelectedFolderId();
            var parameters = new JsonObject
            {
                ["title"] = title,
                ["column"] = "backlog",
                ["workspaceId"] = folder == "\0all" ? "" : folder,
                ["budgetSeconds"] = _defaultBudgetSeconds,
            };
            if (WorkbenchOps.TaskCreation(_protocol))
            {
                // One operation id for the whole action. A lost answer is
                // checked with creationReceipt, never repeated as a new task.
                _pendingCreateOp = WorkbenchOps.NewOperationId("task-create");
                parameters["operationId"] = _pendingCreateOp;
                try
                {
                    await CallTodoAsync("todo.createOnce", parameters);
                    _pendingCreateOp = null;
                    _quickTitle.Text = "";
                    Notice("Task added.");
                }
                catch (Exception ex)
                {
                    Banner("The task may already exist. Check this request before adding another. " + ex.Message);
                    RenderDetail();
                    return;
                }
            }
            else
            {
                await CallTodoAsync("todo.create", parameters);
                _quickTitle.Text = "";
                Notice("Task added.");
            }
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
            return;
        }
        finally
        {
            _working = false;
            _quickAdd.IsEnabled = true;
        }
        await LoadAsync(quiet: true);
        RenderBoard();
    }

    private async Task CheckCreationAsync()
    {
        if (_pendingCreateOp is null)
        {
            return;
        }
        try
        {
            var receipt = await CallTodoAsync(
                "todo.creationReceipt", new JsonObject { ["operationId"] = _pendingCreateOp });
            if (receipt is JsonObject receiptObject && receiptObject.Count > 0)
            {
                _pendingCreateOp = null;
                _quickTitle.Text = "";
                Notice("Task added.");
                await LoadAsync(quiet: true);
                RenderBoard();
            }
            else
            {
                Banner("The computer has not accepted this task yet. Check again when the connection is ready.");
            }
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
        }
        RenderDetail();
    }

    private async Task MoveAsync(string id, string column)
    {
        SnapshotDraft();
        if (string.IsNullOrEmpty(id) || _working)
        {
            return;
        }
        _working = true;
        try
        {
            // Column moves are last-writer-wins like the Mac board. A checked
            // edit would refuse a move whose revision the poller already
            // advanced, so moves stay on the unchecked update.
            await CallTodoAsync(
                "todo.update", new JsonObject { ["id"] = id, ["column"] = column });
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
            _working = false;
            return;
        }
        _working = false;
        await LoadAsync(quiet: true);
        RenderBoard();
        RenderDetail();
    }

    private JsonNode? SelectedCard()
    {
        if (_selectedId is null)
        {
            return null;
        }
        foreach (var card in _cards)
        {
            if (Format.Text(card, "id") == _selectedId)
            {
                return card;
            }
        }
        return null;
    }

    /// <summary>
    /// A background refresh must never clobber an edit in progress. When the
    /// detail is dirty it stays untouched, and a revision that moved under it
    /// surfaces as a banner instead of a rebuild.
    /// </summary>
    private void RenderDetailSafe(bool quiet)
    {
        if (quiet && _detailDirty)
        {
            var card = SelectedCard();
            if (card is not null
                && WorkbenchOps.Revision(card) != _detailRevision
                && _conflictId is null
                && _selectedId is not null)
            {
                _conflictId = _selectedId;
                Banner("This task changed since you opened it. Compare the saved task before replacing it.");
            }
            return;
        }
        if (!_detailDirty && SelectedCard() is JsonNode fresh)
        {
            _detailRevision = WorkbenchOps.Revision(fresh);
        }
        RenderDetail();
    }

    private void RenderDetail()
    {
        if (!_detailDirty && SelectedCard() is JsonNode fresh)
        {
            _detailRevision = WorkbenchOps.Revision(fresh);
        }
        _detailHost.Children.Clear();
        if (_pendingCreateOp is not null)
        {
            var pending = new StackPanel { Spacing = Theme.SpaceS };
            pending.Children.Add(new TextBlock
            {
                Text = "The task may already exist. Check this request before adding another.",
                TextWrapping = TextWrapping.Wrap,
            });
            var checkRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
            checkRow.Children.Add(ActionIconGlyph.Button(
                "Check again", ActionIcon.Refresh, async (_, _) => await CheckCreationAsync()));
            pending.Children.Add(checkRow);
            _detailHost.Children.Add(Chrome.Card("Saving task", pending));
        }
        var card = SelectedCard();
        if (card is null)
        {
            if (_pendingCreateOp is null)
            {
                _detailHost.Children.Add(new TextBlock
                {
                    Text = "Select a task",
                    FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                });
                _detailHost.Children.Add(new TextBlock
                {
                    Text = "Pick a card on the board to edit it, run it, or read its result.",
                    Opacity = 0.66,
                    TextWrapping = TextWrapping.Wrap,
                });
            }
            return;
        }
        _detailHost.Children.Add(DetailCard(card));
        _detailHost.Children.Add(RunCard(card));
    }

    /// <summary>
    /// Copy the on-screen field values into the draft so a re-render keeps
    /// the user's unsent edits. Called before any action that reloads.
    /// </summary>
    private void SnapshotDraft()
    {
        if (_dTitle is null)
        {
            return;
        }
        _draft = new TaskDraft
        {
            Title = _dTitle.Text,
            Prompt = _dPrompt?.Text ?? "",
            FolderId = ComboFolderId(_dFolder),
            Priority = _dPriority?.SelectedItem as string ?? "normal",
            BackendId = ComboBackendId(_dBackend),
            Model = _dModel?.Text ?? "",
            Effort = _dEffort?.Text ?? "",
            BudgetText = _dBudget?.Text ?? "180",
            BudgetUnit = _dUnit?.SelectedItem as string ?? "minutes",
            NoLimit = _dNoLimit?.IsChecked == true,
        };
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

    private string ComboBackendId(ComboBox? box)
    {
        var index = box?.SelectedIndex ?? 0;
        if (index >= 1 && index - 1 < _backends.Count)
        {
            return _backends[index - 1].Id;
        }
        return "";
    }

    private UIElement DetailCard(JsonNode card)
    {
        var id = Format.Text(card, "id");
        var body = new StackPanel { Spacing = Theme.SpaceM };
        var draft = _draft;

        var title = new TextBox
        {
            Text = draft?.Title ?? Format.Text(card, "title"),
            PlaceholderText = "Title",
        };
        title.TextChanged += (_, _) => _detailDirty = true;
        body.Children.Add(Labeled("Title", title));
        _dTitle = title;

        var prompt = new TextBox
        {
            Text = draft?.Prompt ?? Format.Text(card, "notes"),
            PlaceholderText = "What should the agent do?",
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            MinHeight = 96,
        };
        prompt.TextChanged += (_, _) => _detailDirty = true;
        body.Children.Add(Labeled("Prompt", prompt));
        _dPrompt = prompt;

        var folderBox = new ComboBox { MinWidth = 200 };
        var folderNames = new List<string> { "Uncategorized" };
        folderNames.AddRange(_folders.Select(f => f.Name));
        folderBox.ItemsSource = folderNames;
        var workspaceId = draft?.FolderId ?? Format.Text(card, "workspaceId");
        var folderIndex = _folders.FindIndex(f => f.Id == workspaceId);
        folderBox.SelectedIndex = folderIndex >= 0 ? folderIndex + 1 : 0;
        folderBox.SelectionChanged += (_, _) => _detailDirty = true;
        body.Children.Add(Labeled("Folder", folderBox));
        _dFolder = folderBox;

        var priorityBox = new ComboBox { MinWidth = 140 };
        priorityBox.ItemsSource = new[] { "low", "normal", "high" };
        priorityBox.SelectedItem = (draft?.Priority ?? Format.Text(card, "priority", "normal")) switch
        {
            "low" => "low",
            "high" => "high",
            _ => "normal",
        };
        priorityBox.SelectionChanged += (_, _) => _detailDirty = true;
        body.Children.Add(Labeled("Priority", priorityBox));
        _dPriority = priorityBox;

        var backendBox = new ComboBox { MinWidth = 200 };
        var backendNames = new List<string> { "Choose an agent" };
        backendNames.AddRange(_backends.Select(b => b.Label));
        backendBox.ItemsSource = backendNames;
        var backendId = draft?.BackendId ?? Format.Text(card, "backend");
        var backendIndex = _backends.FindIndex(b => b.Id == backendId);
        backendBox.SelectedIndex = backendIndex >= 0 ? backendIndex + 1 : 0;
        backendBox.SelectionChanged += (_, _) => _detailDirty = true;
        body.Children.Add(Labeled("Agent", backendBox));
        _dBackend = backendBox;

        var model = new TextBox
        {
            Text = draft?.Model ?? Format.Text(card, "model"),
            PlaceholderText = "Default model",
        };
        model.TextChanged += (_, _) => _detailDirty = true;
        body.Children.Add(Labeled("Model", model));
        _dModel = model;

        var effort = new TextBox
        {
            Text = draft?.Effort ?? Format.Text(card, "effort"),
            PlaceholderText = "Default effort",
        };
        effort.TextChanged += (_, _) => _detailDirty = true;
        body.Children.Add(Labeled("Effort", effort));
        _dEffort = effort;

        var (budgetValue, budgetUnit, noLimit) = draft is not null
            ? (draft.BudgetText, draft.BudgetUnit, draft.NoLimit)
            : WorkbenchOps.SplitBudget((ulong)Format.Long(card, "budgetSeconds"));
        var budget = new TextBox { Text = budgetValue, MinWidth = 100 };
        budget.TextChanged += (_, _) => _detailDirty = true;
        var unit = new ComboBox { MinWidth = 110 };
        unit.ItemsSource = new[] { "minutes", "seconds" };
        // Selection first, handler after: the initial pick is not an edit.
        unit.SelectedItem = budgetUnit;
        unit.SelectionChanged += (_, _) => _detailDirty = true;
        var noLimitBox = new CheckBox { Content = "No limit", IsChecked = noLimit };
        noLimitBox.Click += (_, _) => _detailDirty = true;
        var budgetRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        budgetRow.Children.Add(budget);
        budgetRow.Children.Add(unit);
        budgetRow.Children.Add(noLimitBox);
        body.Children.Add(Labeled("Time limit", budgetRow));
        _dBudget = budget;
        _dUnit = unit;
        _dNoLimit = noLimitBox;

        if (_conflictId == id)
        {
            body.Children.Add(Chrome.Banner(
                "This task changed since you opened it. Compare the saved task before replacing it.",
                Theme.Warning,
                Symbol.Important));
            var conflictRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
            conflictRow.Children.Add(ActionIconGlyph.PrimaryButton(
                "Save anyway", ActionIcon.Save, async (_, _) =>
                {
                    SnapshotDraft();
                    await SaveDraftAsync(id, force: true);
                }));
            conflictRow.Children.Add(ActionIconGlyph.Button(
                "Take saved", ActionIcon.Restore, async (_, _) =>
                {
                    _conflictId = null;
                    _detailDirty = false;
                    _draft = null;
                    await LoadAsync(quiet: true);
                    RenderBoard();
                    RenderDetail();
                }));
            body.Children.Add(conflictRow);
        }

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        actions.Children.Add(ActionIconGlyph.PrimaryButton(
            "Save", ActionIcon.Save, async (_, _) =>
            {
                SnapshotDraft();
                await SaveDraftAsync(id, force: false);
            }));
        foreach (var (column, label) in Columns.Zip(ColumnTitles))
        {
            if (Format.Text(card, "column") != column)
            {
                var target = column;
                var caption = label;
                actions.Children.Add(ActionIconGlyph.Button(
                    $"Move to {caption}", ActionIcon.Move, async (_, _) => await MoveAsync(id, target)));
            }
        }
        if (Format.Text(card, "column") == "archive")
        {
            actions.Children.Add(ActionIconGlyph.Button(
                "Restore", ActionIcon.Restore, async (_, _) => await MoveAsync(id, "backlog")));
        }
        else
        {
            actions.Children.Add(ActionIconGlyph.Button(
                "Archive", ActionIcon.Archive, async (_, _) => await MoveAsync(id, "archive")));
        }
        if (!_confirmDelete)
        {
            actions.Children.Add(ActionIconGlyph.Button(
                "Delete", ActionIcon.Delete, (_, _) =>
                {
                    SnapshotDraft();
                    _confirmDelete = true;
                    RenderDetail();
                }));
        }
        else
        {
            actions.Children.Add(ActionIconGlyph.Button(
                "Back", ActionIcon.Back, (_, _) =>
                {
                    SnapshotDraft();
                    _confirmDelete = false;
                    RenderDetail();
                }));
        }
        body.Children.Add(actions);

        if (_confirmDelete)
        {
            var confirm = new StackPanel { Spacing = Theme.SpaceS };
            confirm.Children.Add(new TextBlock
            {
                Text = $"Delete \"{Format.Text(card, "title")}\"? This removes the task from this computer's board.",
                TextWrapping = TextWrapping.Wrap,
            });
            var confirmRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
            confirmRow.Children.Add(ActionIconGlyph.Button(
                "Delete task", ActionIcon.Delete, async (_, _) => await DeleteAsync(id)));
            confirm.Children.Add(confirmRow);
            body.Children.Add(confirm);
        }

        return Chrome.Card(
            Format.Text(card, "title", "Task"),
            body,
            $"Revision {_detailRevision?.ToString() ?? "unknown"} · {FolderLabel(workspaceId)}");
    }

    private async Task SaveDraftAsync(string id, bool force)
    {
        var draft = _draft;
        if (draft is null)
        {
            return;
        }
        var cleanTitle = draft.Title.Trim();
        if (cleanTitle.Length == 0)
        {
            Banner("Give this task a title.");
            return;
        }
        if (cleanTitle.Length > 4096)
        {
            Banner("Shorten the title to 4 KiB or less.");
            return;
        }
        if (draft.Prompt.Length > 1024 * 1024)
        {
            Banner("Shorten the prompt to 1 MiB or less.");
            return;
        }
        if (draft.Priority is not ("low" or "normal" or "high"))
        {
            Banner("Choose a task priority.");
            return;
        }
        var seconds = WorkbenchOps.BudgetSeconds(draft.BudgetText, draft.BudgetUnit, draft.NoLimit);
        if (seconds is null)
        {
            Banner("Enter a positive time limit, or choose No limit.");
            return;
        }
        _working = true;
        try
        {
            var parameters = new JsonObject
            {
                ["id"] = id,
                ["title"] = cleanTitle,
                ["notes"] = draft.Prompt,
                ["workspaceId"] = draft.FolderId,
                ["priority"] = draft.Priority,
                ["backend"] = draft.BackendId,
                ["model"] = draft.Model.Trim(),
                ["effort"] = draft.Effort.Trim(),
                ["budgetSeconds"] = seconds.Value,
            };
            var revision = force ? await FreshRevisionAsync(id) : _detailRevision;
            if (WorkbenchOps.TaskEditing(_protocol))
            {
                if (revision is null)
                {
                    Banner("Reload this task before saving its settings.");
                    return;
                }
                parameters["expectedRevision"] = revision.Value;
                try
                {
                    await CallTodoAsync("todo.edit", parameters);
                }
                catch (Exception ex) when (WorkbenchOps.IsConflict(ex))
                {
                    _conflictId = id;
                    Banner("This task changed since you opened it. Compare the saved task before replacing it.");
                    await LoadAsync(quiet: true);
                    if (SelectedCard() is JsonNode conflicted)
                    {
                        _detailRevision = WorkbenchOps.Revision(conflicted);
                    }
                    RenderBoard();
                    RenderDetail();
                    return;
                }
            }
            else
            {
                await CallTodoAsync("todo.update", parameters);
            }
            _detailDirty = false;
            _conflictId = null;
            _draft = null;
            Notice($"Saved \"{cleanTitle}\".");
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
            return;
        }
        finally
        {
            _working = false;
        }
        await LoadAsync(quiet: true);
        RenderBoard();
        RenderDetail();
    }

    private async Task<ulong?> FreshRevisionAsync(string id)
    {
        try
        {
            var fresh = await CallTodoAsync("todo.get", new JsonObject { ["id"] = id });
            return WorkbenchOps.Revision(fresh);
        }
        catch
        {
            return null;
        }
    }

    private async Task DeleteAsync(string id)
    {
        SnapshotDraft();
        _working = true;
        try
        {
            if (WorkbenchOps.TaskDeletion(_protocol))
            {
                var revision = _detailRevision ?? await FreshRevisionAsync(id);
                if (revision is null)
                {
                    Banner("Reload this task before deleting it.");
                    return;
                }
                await CallTodoAsync(
                    "todo.delete", new JsonObject { ["id"] = id, ["expectedRevision"] = revision.Value });
            }
            else
            {
                await CallTodoAsync("todo.remove", new JsonObject { ["id"] = id });
            }
            _selectedId = null;
            _confirmDelete = false;
            _draft = null;
            _detailDirty = false;
            Notice("Task deleted.");
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
            return;
        }
        finally
        {
            _working = false;
        }
        await LoadAsync(quiet: true);
        RenderBoard();
        RenderDetail();
    }

    private UIElement RunCard(JsonNode card)
    {
        var id = Format.Text(card, "id");
        var body = new StackPanel { Spacing = Theme.SpaceM };
        var delegateNode = card["delegate"];
        var runId = Format.Text(delegateNode, "runId");
        var status = Format.Text(delegateNode, "status");
        var running = WorkbenchOps.IsRunning(delegateNode);

        if (!string.IsNullOrEmpty(_runError))
        {
            body.Children.Add(Chrome.Banner(_runError, Theme.Warning, Symbol.Important));
            if (_pendingRunOp is not null)
            {
                var retryRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
                retryRow.Children.Add(ActionIconGlyph.Button(
                    "Check again", ActionIcon.Refresh, async (_, _) => await CheckRunAsync()));
                retryRow.Children.Add(ActionIconGlyph.Button(
                    "Retry", ActionIcon.Run, async (_, _) => await RetryRunAsync()));
                body.Children.Add(retryRow);
            }
        }

        if (!string.IsNullOrEmpty(status))
        {
            var line = new TextBlock
            {
                Text = string.IsNullOrEmpty(runId)
                    ? WorkbenchOps.RunLabel(status)
                    : $"{WorkbenchOps.RunLabel(status)} · run {runId}",
                TextWrapping = TextWrapping.Wrap,
            };
            body.Children.Add(line);
        }

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        var canRun = !running && _pendingRunOp is null && !_working;
        var backButton = ActionIconGlyph.Button(
            "Run in background", ActionIcon.Run, async (_, _) => await RunAsync(id, "background"));
        backButton.IsEnabled = canRun;
        var frontButton = ActionIconGlyph.Button(
            "Run in foreground", ActionIcon.Run, async (_, _) => await RunAsync(id, "foreground"));
        frontButton.IsEnabled = canRun;
        actions.Children.Add(backButton);
        actions.Children.Add(frontButton);
        if (running && !string.IsNullOrEmpty(runId))
        {
            actions.Children.Add(ActionIconGlyph.Button(
                "Stop", ActionIcon.Stop, async (_, _) => await StopAsync(id, runId)));
        }
        body.Children.Add(actions);

        if (!string.IsNullOrEmpty(runId))
        {
            var run = FindRun(runId);
            body.Children.Add(RunResult(run, runId, card));
        }
        else if (!running)
        {
            body.Children.Add(new TextBlock
            {
                Text = "No run yet. Run this task to see its result here.",
                Opacity = 0.66,
                TextWrapping = TextWrapping.Wrap,
            });
        }
        return Chrome.Card("Run", body, FolderLabel(Format.Text(card, "workspaceId")));
    }

    private JsonNode? FindRun(string runId)
    {
        foreach (var run in _runs)
        {
            if (Format.Text(run, "id") == runId)
            {
                return run;
            }
        }
        return null;
    }

    private UIElement RunResult(JsonNode? run, string runId, JsonNode card)
    {
        var body = new StackPanel { Spacing = Theme.SpaceS };
        if (run is null)
        {
            body.Children.Add(new TextBlock
            {
                Text = "The run is not in this host's history yet. Refresh to look again.",
                Opacity = 0.66,
                TextWrapping = TextWrapping.Wrap,
            });
            return body;
        }
        var status = Format.Text(run, "status");
        body.Children.Add(new TextBlock
        {
            Text = $"{Format.Text(run, "name", "Run")} · {WorkbenchOps.RunLabel(status)}",
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
        });
        var started = Format.Long(run, "startedAtMs");
        if (started > 0)
        {
            body.Children.Add(new TextBlock
            {
                Text = DateTimeOffset.FromUnixTimeMilliseconds(started).LocalDateTime.ToString("g"),
                FontSize = 12,
                Opacity = 0.68,
            });
        }
        var transcript = Format.Text(run, "transcript");
        if (string.IsNullOrEmpty(transcript))
        {
            transcript = RunTranscriptCache(runId);
        }
        if (!string.IsNullOrEmpty(transcript))
        {
            body.Children.Add(new TextBlock
            {
                Text = transcript,
                TextWrapping = TextWrapping.Wrap,
                IsTextSelectionEnabled = true,
                Opacity = 0.9,
            });
        }
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        row.Children.Add(ActionIconGlyph.Button(
            "View transcript", ActionIcon.History, async (_, _) => await LoadTranscriptAsync(runId)));
        body.Children.Add(row);
        var workspaceId = Format.Text(card, "workspaceId");
        body.Children.Add(new TextBlock
        {
            Text = string.IsNullOrEmpty(workspaceId)
                ? "This task has no folder. Assign one to review files and history."
                : $"Review {FolderLabel(workspaceId)}: uncommitted files in Changes, previous commits in History.",
            FontSize = 12,
            Opacity = 0.68,
            TextWrapping = TextWrapping.Wrap,
        });
        return body;
    }

    private readonly Dictionary<string, string> _transcripts = new();

    private string RunTranscriptCache(string runId) =>
        _transcripts.TryGetValue(runId, out var text) ? text : "";

    private async Task LoadTranscriptAsync(string runId)
    {
        SnapshotDraft();
        try
        {
            var answer = await CallTodoAsync(
                "automation.transcript",
                new JsonObject { ["id"] = runId, ["offset"] = 0 });
            var text = Format.Text(answer, "text");
            _transcripts[runId] = string.IsNullOrEmpty(text) ? "(empty transcript)" : text;
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
        }
        RenderDetail();
    }

    private string? RunReadiness(JsonNode card)
    {
        if (string.IsNullOrEmpty(Format.Text(card, "workspaceId").Trim()))
        {
            return "Assign a folder before running this task.";
        }
        if (string.IsNullOrEmpty(Format.Text(card, "backend").Trim()))
        {
            return "Choose an agent before running this task.";
        }
        var prompt = Format.Text(card, "notes").Trim();
        if (string.IsNullOrEmpty(prompt) && string.IsNullOrEmpty(Format.Text(card, "title").Trim()))
        {
            return "Write a prompt before running this task.";
        }
        return null;
    }

    private async Task RunAsync(string id, string placement)
    {
        SnapshotDraft();
        if (_working || _pendingRunOp is not null)
        {
            return;
        }
        // A run starts from saved values. Save first like the Mac editor,
        // which refuses to run while the draft is dirty.
        if (_detailDirty)
        {
            await SaveDraftAsync(id, force: false);
            if (_detailDirty)
            {
                _runError = "Save the task before running it.";
                RenderDetail();
                return;
            }
        }
        var card = SelectedCard();
        if (card is null)
        {
            return;
        }
        var readiness = RunReadiness(card);
        if (readiness is not null)
        {
            _runError = readiness;
            RenderDetail();
            return;
        }
        _working = true;
        try
        {
            if (WorkbenchOps.TaskExecution(_protocol))
            {
                var revision = _detailRevision ?? await FreshRevisionAsync(id);
                if (revision is null)
                {
                    _runError = "Reload this task before running it.";
                    RenderDetail();
                    return;
                }
                // One operation id for the whole launch. Retry and Check again
                // reuse it, so a lost answer can never start a second run.
                _pendingRunOp = WorkbenchOps.NewOperationId("task-run");
                _runError = null;
                try
                {
                    await CallTodoAsync("todo.runTask", new JsonObject
                    {
                        ["id"] = id,
                        ["expectedRevision"] = revision.Value,
                        ["operationId"] = _pendingRunOp,
                        ["placement"] = placement,
                    });
                    _pendingRunOp = null;
                    Notice(placement == "foreground"
                        ? "Foreground run started in a terminal."
                        : "Handed the task to an agent.");
                }
                catch (Exception ex)
                {
                    _runError = "The run result is not confirmed. Check this request before starting another run. " + ex.Message;
                    RenderDetail();
                    return;
                }
            }
            else
            {
                await CallTodoAsync("todo.delegate", new JsonObject { ["id"] = id });
                Notice("Handed the task to an agent.");
            }
        }
        catch (Exception ex)
        {
            _runError = ex.Message;
            RenderDetail();
            return;
        }
        finally
        {
            _working = false;
        }
        await LoadAsync(quiet: true);
        RenderBoard();
        RenderDetail();
    }

    private async Task CheckRunAsync()
    {
        SnapshotDraft();
        if (_pendingRunOp is null)
        {
            return;
        }
        try
        {
            var receipt = await CallTodoAsync(
                "todo.runReceipt", new JsonObject { ["operationId"] = _pendingRunOp });
            if (receipt?["run"] is not null)
            {
                _pendingRunOp = null;
                _runError = null;
                Notice("The run is confirmed.");
                await LoadAsync(quiet: true);
                RenderBoard();
            }
            else
            {
                _runError = "The computer has not accepted this run request. Retry the same request when the connection is ready.";
            }
        }
        catch (Exception ex)
        {
            _runError = "The run result is still unavailable. Your request is kept on this device. " + ex.Message;
        }
        RenderDetail();
    }

    private async Task RetryRunAsync()
    {
        SnapshotDraft();
        if (_pendingRunOp is null || _selectedId is null)
        {
            return;
        }
        var card = SelectedCard();
        if (card is null)
        {
            return;
        }
        _working = true;
        try
        {
            var revision = _detailRevision ?? await FreshRevisionAsync(_selectedId);
            if (revision is null)
            {
                _runError = "Reload this task before retrying the run.";
                RenderDetail();
                return;
            }
            // Same operation id as the first attempt: the host answers from
            // the receipt when it already accepted the run.
            await CallTodoAsync("todo.runTask", new JsonObject
            {
                ["id"] = _selectedId,
                ["expectedRevision"] = revision.Value,
                ["operationId"] = _pendingRunOp,
                ["placement"] = "background",
            });
            _pendingRunOp = null;
            _runError = null;
            Notice("The run is confirmed.");
        }
        catch (Exception ex)
        {
            _runError = "The run result is not confirmed. Check this request before starting another run. " + ex.Message;
            RenderDetail();
            return;
        }
        finally
        {
            _working = false;
        }
        await LoadAsync(quiet: true);
        RenderBoard();
        RenderDetail();
    }

    private async Task StopAsync(string id, string runId)
    {
        SnapshotDraft();
        _working = true;
        try
        {
            if (WorkbenchOps.TaskExecution(_protocol))
            {
                var revision = _detailRevision ?? await FreshRevisionAsync(id);
                if (revision is null)
                {
                    Banner("Reload this task before stopping it.");
                    return;
                }
                await CallTodoAsync("todo.stopTask", new JsonObject
                {
                    ["id"] = id,
                    ["expectedRevision"] = revision.Value,
                    ["runId"] = runId,
                });
            }
            else
            {
                await CallTodoAsync("todo.stop", new JsonObject { ["id"] = id });
            }
            Notice("Stopped.");
        }
        catch (Exception ex)
        {
            Banner("The stop was not confirmed. Reload this task before trying again. " + ex.Message);
            return;
        }
        finally
        {
            _working = false;
        }
        await LoadAsync(quiet: true);
        RenderBoard();
        RenderDetail();
    }
}
