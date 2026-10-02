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
    private readonly TextBox _quickTitle = new() { PlaceholderText = L10n.Text("windows.todopage.new_task.3e992276") };
    private readonly Button _quickAdd;
    private readonly ComboBox _folderFilter = new()
    {
        MinWidth = 160,
        VerticalAlignment = VerticalAlignment.Center,
    };
    private readonly ComboBox _agentFilter = new() { MinWidth = 140 };
    private readonly ComboBox _attentionFilter = new() { MinWidth = 150 };
    private readonly TextBox _search = new() { PlaceholderText = L10n.Text("windows.todopage.search_tasks.46c6f1de"), MinWidth = 180 };

    private JsonArray _cards = new();
    private JsonArray _runs = new();
    private List<(string Id, string Name)> _folders = new();
    private List<(string Id, string Label)> _backends = new();
    private long? _protocol;
    private ulong _defaultBudgetSeconds = 10_800;
    private string _query = "";
    private bool _showArchive;
    private bool _newestFirst;
    private bool _working;
    private string? _selectedId;
    private string? _pendingCreateOp;
    private TextBox? _pendingCreateInput;
    private readonly TaskCreationDraft _backlogCreation = new();
    private readonly TaskCreationDraft _doingCreation = new();
    private TaskCreationDraft? _pendingCreateDraft;
    private long _pendingCreateRevision;
    private readonly TextBox _doingTitle = new() { PlaceholderText = L10n.Text("windows.todopage.new_task.3e992276"), HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly Button _doingAdd;
    private Grid? _backlogEntry;
    private Grid? _doingEntry;
    private bool _updatingFilters;
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
    private static readonly string[] ColumnTitles = [L10n.Text("windows.todopage.to_do.150d92c4"), L10n.Text("windows.todopage.in_progress.c1f88e9d"), L10n.Text("common.done")];

    public TodoPage(string? workspaceId = null)
    {
        _scopeWorkspaceId = workspaceId;
        _quickAdd = ActionIconGlyph.Button(L10n.Text("common.add"), ActionIcon.Create, async (_, _) => await CreateAsync());
        _doingAdd = ActionIconGlyph.Button(L10n.Text("common.add"), ActionIcon.Create, async (_, _) => await CreateAsync(_doingTitle, "doing"));
        _quickTitle.TextChanged += (_, _) => _backlogCreation.Edited();
        _doingTitle.TextChanged += (_, _) => _doingCreation.Edited();
        _quickTitle.KeyDown += async (_, key) => { if (key.Key == Windows.System.VirtualKey.Enter) { key.Handled = true; await CreateAsync(); } };
        _doingTitle.KeyDown += async (_, key) => { if (key.Key == Windows.System.VirtualKey.Enter) { key.Handled = true; await CreateAsync(_doingTitle, "doing"); } };

        _attentionFilter.ItemsSource = new[] { L10n.Text("windows.todopage.all_tasks.cb664823"), L10n.Text("common.running"), L10n.Text("windows.todopage.needs_attention.c1ebc781"), L10n.Text("windows.todopage.high_priority.b699a8c8") };
        _attentionFilter.SelectedIndex = 0;
        _attentionFilter.SelectionChanged += (_, _) => RenderBoard();
        _agentFilter.SelectionChanged += (_, _) => { if (!_updatingFilters) RenderBoard(); };
        _folderFilter.SelectionChanged += (_, _) => { if (!_updatingFilters) RenderBoard(); };
        _search.TextChanged += (_, _) =>
        {
            _query = _search.Text ?? "";
            RenderBoard();
        };

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
    public double MinimumContentWidth => 760;

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
                L10n.Text("windows.todopage.reload_tasks.8eed27ce"),
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
            L10n.Text("windows.todopage.add_a_card_to_to_do.ca83de8d"),
            (_, _) => FocusNewTask()));
        var sort = SegmentedCapsule.View(
            new List<(string Value, string Label, ActionIcon? Glyph)>
            {
                ("newest", L10n.Text("windows.todopage.newest.d15efa17"), null),
                ("board", L10n.Text("windows.todopage.board_order.a919c850"), null),
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
            _showArchive ? L10n.Text("windows.todopage.show_done.79b95d57")
                : archived == 0 ? L10n.Text("windows.todopage.no_archived_cards.ff87c4c5")
                : (archived == 1 ? L10n.Text("windows.todopage.show_0_archived_card_1.57f16789.one", archived) : L10n.Text("windows.todopage.show_0_archived_card_1.57f16789.other", archived)),
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
        var bar = new FlowPanel { Spacing = Theme.SpaceM };
        bar.Children.Add(Labeled(L10n.Text("windows.todopage.agent.11b39c93"), _agentFilter));
        bar.Children.Add(Labeled(L10n.Text("windows.todopage.showing.d604310a"), _attentionFilter));
        bar.Children.Add(Labeled(L10n.Text("common.search"), _search));
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
            var foldersTask = CallTodoAsync("workspace.list", new JsonObject());
            var backendsTask = CallTodoAsync("automation.backends", new JsonObject());
            var queueTask = CallTodoAsync("automation.queue", new JsonObject());
            await Task.WhenAll(cardsTask, runsTask, foldersTask, backendsTask, queueTask);
            _cards = cardsTask.Result as JsonArray
                ?? cardsTask.Result["cards"] as JsonArray
                ?? new JsonArray();
            _runs = Format.Items(runsTask.Result) ?? new JsonArray();
            if (_scopeWorkspaceId is null || !RemoteWorkspaces.TrySplit(_scopeWorkspaceId, out _, out _))
            {
                RunNotifications.Shared.SettleAutomations(_runs);
            }
            // Capture the current choices against the old directory before
            // replacing it. A refresh may reorder or remove its entries.
            var selectedFolderId = SelectedFolderId();
            var selectedBackendId = SelectedBackendId();
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
                // Folder choices must belong to the same host as the cards.
                // Keep this page's selected folder in the shell namespace;
                // other choices already carry the owning peer's native ids.
                _folders = _folders.Select(folder =>
                    (Id: folder.Id == inner ? _scopeWorkspaceId : folder.Id, Name: folder.Name)).ToList();
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
            RefreshFilterLists(selectedFolderId, selectedBackendId);
            RaiseToolbarChangedIfNeeded();
            RenderBoard();
            RenderDetailSafe(quiet);
        }
        catch (Exception ex)
        {
            Program.LogStartup("Tasks load/layout failed: " + ex);
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

    private void RefreshFilterLists(string selectedFolderId, string selectedBackendId)
    {
        _updatingFilters = true;
        try
        {
            var folderNames = new List<string> { L10n.Text("windows.todopage.all_projects.4b87271b"), L10n.Text("windows.todopage.uncategorized.8d40d123") };
            folderNames.AddRange(_folders.Select(f => f.Name));
            _folderFilter.ItemsSource = folderNames;
            if (_scopeWorkspaceId is not null)
            {
                var index = _folders.FindIndex(f => f.Id == _scopeWorkspaceId);
                _folderFilter.SelectedIndex = index >= 0 ? index + 2 : 0;
                _folderFilter.IsEnabled = false;
            }
            else
            {
                var index = _folders.FindIndex(folder => folder.Id == selectedFolderId);
                _folderFilter.SelectedIndex = selectedFolderId == "" ? 1 : index >= 0 ? index + 2 : 0;
            }
            var agentNames = new List<string> { L10n.Text("windows.todopage.all_agents.54c32d3e") };
            agentNames.AddRange(_backends.Select(b => b.Label));
            _agentFilter.ItemsSource = agentNames;
            _agentFilter.SelectedIndex = _backends.FindIndex(backend => backend.Id == selectedBackendId) + 1;
        }
        finally
        {
            _updatingFilters = false;
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
        if (_showArchive && _cards.Count == 0)
        {
            _boardHost.Children.Add(EmptyState.View(
                _showArchive ? L10n.Text("windows.todopage.no_archived_tasks.5cad3e05") : L10n.Text("windows.todopage.no_tasks_yet.cca8d533"),
                L10n.Text("windows.todopage.create_a_task_or_adjust_the_filters_to_see.50174b52"),
                EmptyArtKind.Tasks,
                ActionIconGlyph.Button(L10n.Text("windows.todopage.new_task.3e992276"), ActionIcon.Create, (_, _) =>
                    FocusNewTask())));
            return;
        }
        if (_showArchive)
        {
            _boardHost.Children.Add(Column("archive", L10n.Text("common.archive")));
            return;
        }
        var stages = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceM };
        for (var i = 0; i < Columns.Length; i++)
        {
            var stage = Column(Columns[i], ColumnTitles[i]);
            stage.Width = Math.Max(226, (_boardHost.ActualWidth - Theme.SpaceM * 2) / 3);
            stages.Children.Add(stage);
        }
        var board = new ScrollViewer
        {
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollMode = ScrollMode.Enabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollMode = ScrollMode.Disabled,
            Content = stages,
        };
        board.SizeChanged += (_, e) =>
        {
            var width = Math.Max(226, (e.NewSize.Width - Theme.SpaceM * 2) / 3);
            foreach (FrameworkElement stage in stages.Children)
                if (Math.Abs(stage.Width - width) > 0.5) stage.Width = width;
        };
        _boardHost.Children.Add(board);
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
                Text = !string.IsNullOrWhiteSpace(_query) || _agentFilter.SelectedIndex > 0 || _attentionFilter.SelectedIndex > 0
                    ? L10n.Text("windows.todopage.no_matching_tasks.ff36d18d") : column switch
                {
                    "backlog" => L10n.Text("windows.todopage.ready_for_your_next_task.838d6e4b"),
                    "doing" => L10n.Text("windows.todopage.nothing_in_progress.44a3cc77"),
                    "done" => L10n.Text("windows.todopage.completed_tasks_appear_here.6d7064fc"),
                    _ => L10n.Text("windows.todopage.no_archived_tasks.5cad3e05"),
                },
                TextWrapping = TextWrapping.Wrap,
                Opacity = 0.6,
            });
        }
        var body = new StackPanel { Spacing = Theme.SpaceS };
        var heading = new TextBlock
        {
            Text = $"{title} ({cards.Count})",
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(heading, "tasks.column." + column);
        body.Children.Add(heading);
        if (column is "backlog" or "doing")
        {
            var input = column == "backlog" ? _quickTitle : _doingTitle;
            var add = column == "backlog" ? _quickAdd : _doingAdd;
            // Filter initialization can redraw before the previous column has
            // entered the visual tree. Keep its owner explicitly: native
            // Parent queries alone cannot safely govern reusable controls.
            var previousEntry = column == "backlog" ? _backlogEntry : _doingEntry;
            previousEntry?.Children.Clear();
            var entry = new Grid { ColumnSpacing = Theme.SpaceXs };
            if (column == "backlog") _backlogEntry = entry; else _doingEntry = entry;
            entry.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            entry.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            Grid.SetColumn(add, 1);
            entry.Children.Add(input); entry.Children.Add(add);
            body.Children.Add(entry);
            ToolTipService.SetToolTip(input, L10n.Text("windows.todopage.new_task_in_0.77ab1dfa", $"{title}"));
        }
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
            await ReorderAsync(id, column);
        };
        return frame;
    }

    private UIElement CardRow(JsonNode card)
    {
        var id = Format.Text(card, "id");
        var title = Format.Text(card, "title", L10n.Text("windows.todopage.untitled.3bc7cc17"));
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
            line += L10n.Text("windows.todopage.high_priority.bb9eb467");
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
            AllowDrop = true,
        };
        frame.DragStarting += (_, e) =>
        {
            e.Data.SetText(id);
            e.Data.RequestedOperation = DataPackageOperation.Move;
        };
        frame.DragOver += (_, e) =>
        {
            if (!e.DataView.Contains(StandardDataFormats.Text)) return;
            e.Handled = true;
            e.AcceptedOperation = DataPackageOperation.Move;
            frame.BorderBrush = Theme.AccentBrush;
            e.DragUIOverride.Caption = e.GetPosition(frame).Y < frame.ActualHeight / 2
                ? L10n.Text("windows.todopage.move_before_this_task.76986a3b") : L10n.Text("windows.todopage.move_after_this_task.dabd62ad");
        };
        frame.DragLeave += (_, _) => frame.BorderBrush = Theme.BorderBrush;
        frame.Drop += async (_, e) =>
        {
            e.Handled = true;
            frame.BorderBrush = Theme.BorderBrush;
            if (!e.DataView.Contains(StandardDataFormats.Text)) return;
            var after = e.GetPosition(frame).Y >= frame.ActualHeight / 2;
            var dragged = await e.DataView.GetTextAsync();
            if (dragged != id) await ReorderAsync(dragged, Format.Text(card, "column"), id, after);
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
            return L10n.Text("windows.todopage.uncategorized.8d40d123");
        }
        return _folders.FirstOrDefault(f => f.Id == workspaceId).Name ?? L10n.Text("windows.todopage.folder.74ccd433");
    }

    private void FocusNewTask()
    {
        if (_showArchive) { _showArchive = false; RenderBoard(); RaiseToolbarChangedIfNeeded(); }
        _quickTitle.Focus(FocusState.Programmatic);
    }

    private void ClearAcceptedCreate()
    {
        if (_pendingCreateInput is TextBox input && _pendingCreateDraft?.Accepts(_pendingCreateRevision) == true) input.Text = "";
        _pendingCreateInput = null;
        _pendingCreateDraft = null;
    }

    private async Task CreateAsync(TextBox? input = null, string column = "backlog")
    {
        input ??= _quickTitle;
        var title = input.Text.Trim();
        var draft = ReferenceEquals(input, _doingTitle) ? _doingCreation : _backlogCreation;
        var submittedRevision = draft.Revision;
        if (title.Length == 0 || _working || _pendingCreateOp is not null)
        {
            return;
        }
        _working = true;
        _quickAdd.IsEnabled = _doingAdd.IsEnabled = false;
        try
        {
            var folder = SelectedFolderId();
            var parameters = new JsonObject
            {
                ["title"] = title,
                ["column"] = column,
                ["workspaceId"] = folder == "\0all" ? "" : folder,
                ["budgetSeconds"] = _defaultBudgetSeconds,
            };
            if (WorkbenchOps.TaskCreation(_protocol))
            {
                // One operation id for the whole action. A lost answer is
                // checked with creationReceipt, never repeated as a new task.
                _pendingCreateInput = input;
                _pendingCreateDraft = draft;
                _pendingCreateRevision = submittedRevision;
                _pendingCreateOp = WorkbenchOps.NewOperationId("task-create");
                parameters["operationId"] = _pendingCreateOp;
                try
                {
                    await CallTodoAsync("todo.createOnce", parameters);
                    _pendingCreateOp = null;
                    ClearAcceptedCreate();
                    Notice(L10n.Text("windows.todopage.task_added.d37be00e"));
                }
                catch (Exception ex)
                {
                    Banner(L10n.Text("windows.todopage.the_task_may_already_exist_check_this_requ.393dd6c6", $"{ex.Message}"));
                    RenderDetail();
                    return;
                }
            }
            else
            {
                await CallTodoAsync("todo.create", parameters);
                if (draft.Accepts(submittedRevision)) input.Text = "";
                Notice(L10n.Text("windows.todopage.task_added.d37be00e"));
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
            _quickAdd.IsEnabled = _doingAdd.IsEnabled = true;
        }
        await LoadAsync(quiet: true);
        RenderBoard();
    }

    private async Task CheckCreationAsync()
    {
        if (_pendingCreateOp is not string operationId)
        {
            return;
        }
        try
        {
            var receipt = await CallTodoAsync(
                "todo.creationReceipt", new JsonObject { ["operationId"] = operationId });
            if (_pendingCreateOp != operationId) return;
            if (receipt is JsonObject receiptObject && receiptObject.Count > 0)
            {
                _pendingCreateOp = null;
                ClearAcceptedCreate();
                Notice(L10n.Text("windows.todopage.task_added.d37be00e"));
                await LoadAsync(quiet: true);
                RenderBoard();
            }
            else
            {
                Banner(L10n.Text("windows.todopage.the_computer_has_not_accepted_this_task_ye.a1c750b8"));
            }
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
        }
        RenderDetail();
    }

    private async Task ReorderAsync(string id, string column, string? anchor = null, bool after = false)
    {
        // The host indexes the whole column, including tasks outside the
        // current project/search filter. Visible row indices would misplace it.
        var order = TaskBoardOrder.InsertionIndex(_cards, id, column, anchor, after);
        if (order is null) return;
        _newestFirst = false;
        RaiseToolbarChangedIfNeeded();
        await MoveAsync(id, column, order);
    }

    private async Task MoveAsync(string id, string column, long? order = null)
    {
        SnapshotDraft();
        if (string.IsNullOrEmpty(id) || _working
            || !_cards.Any(card => Format.Text(card, "id") == id && Format.Text(card, "kind") != "note"))
        {
            return;
        }
        _working = true;
        try
        {
            // Column moves are last-writer-wins like the Mac board. A checked
            // edit would refuse a move whose revision the poller already
            // advanced, so moves stay on the unchecked update.
            var changes = new JsonObject { ["id"] = id, ["column"] = column };
            if (order is not null) changes["order"] = order.Value;
            await CallTodoAsync("todo.update", changes);
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
                Banner(L10n.Text("windows.todopage.this_task_changed_since_you_opened_it_comp.e4a26988"));
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
                Text = L10n.Text("windows.todopage.the_task_may_already_exist_check_this_requ.0c71c77c"),
                TextWrapping = TextWrapping.Wrap,
            });
            var checkRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
            checkRow.Children.Add(ActionIconGlyph.Button(
                L10n.Text("windows.todopage.check_again.fb7099ad"), ActionIcon.Refresh, async (_, _) => await CheckCreationAsync()));
            pending.Children.Add(checkRow);
            _detailHost.Children.Add(Chrome.Card(L10n.Text("windows.todopage.saving_task.a0d363d3"), pending));
        }
        var card = SelectedCard();
        if (card is null)
        {
            if (_pendingCreateOp is null)
            {
                _detailHost.Children.Add(new TextBlock
                {
                    Text = L10n.Text("windows.todopage.select_a_task.fc354a83"),
                    FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                });
                _detailHost.Children.Add(new TextBlock
                {
                    Text = L10n.Text("windows.todopage.pick_a_card_on_the_board_to_edit_it_run_it.8bba3cca"),
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
            BudgetUnit = _dUnit?.SelectedValue as string ?? "minutes",
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
            PlaceholderText = L10n.Text("windows.todopage.title.7e8cd205"),
        };
        title.TextChanged += (_, _) => _detailDirty = true;
        body.Children.Add(Labeled(L10n.Text("windows.todopage.title.7e8cd205"), title));
        _dTitle = title;

        var prompt = new TextBox
        {
            Text = draft?.Prompt ?? Format.Text(card, "notes"),
            PlaceholderText = L10n.Text("windows.todopage.what_should_the_agent_do.99b09b41"),
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            MinHeight = 96,
        };
        prompt.TextChanged += (_, _) => _detailDirty = true;
        body.Children.Add(Labeled(L10n.Text("windows.todopage.prompt.5c391238"), prompt));
        _dPrompt = prompt;

        var folderBox = new ComboBox { MinWidth = 200 };
        var folderNames = new List<string> { L10n.Text("windows.todopage.uncategorized.8d40d123") };
        folderNames.AddRange(_folders.Select(f => f.Name));
        folderBox.ItemsSource = folderNames;
        var workspaceId = draft?.FolderId ?? Format.Text(card, "workspaceId");
        var folderIndex = _folders.FindIndex(f => f.Id == workspaceId);
        folderBox.SelectedIndex = folderIndex >= 0 ? folderIndex + 1 : 0;
        folderBox.SelectionChanged += (_, _) => _detailDirty = true;
        body.Children.Add(Labeled(L10n.Text("windows.todopage.folder.74ccd433"), folderBox));
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
        body.Children.Add(Labeled(L10n.Text("windows.todopage.priority.d60dbba0"), priorityBox));
        _dPriority = priorityBox;

        var backendBox = new ComboBox { MinWidth = 200 };
        var backendNames = new List<string> { L10n.Text("windows.todopage.choose_an_agent.b6890bc2") };
        backendNames.AddRange(_backends.Select(b => b.Label));
        backendBox.ItemsSource = backendNames;
        var backendId = draft?.BackendId ?? Format.Text(card, "backend");
        var backendIndex = _backends.FindIndex(b => b.Id == backendId);
        backendBox.SelectedIndex = backendIndex >= 0 ? backendIndex + 1 : 0;
        backendBox.SelectionChanged += (_, _) => _detailDirty = true;
        body.Children.Add(Labeled(L10n.Text("windows.todopage.agent.11b39c93"), backendBox));
        _dBackend = backendBox;

        var model = new TextBox
        {
            Text = draft?.Model ?? Format.Text(card, "model"),
            PlaceholderText = L10n.Text("windows.todopage.default_model.3840d9d2"),
        };
        model.TextChanged += (_, _) => _detailDirty = true;
        body.Children.Add(Labeled(L10n.Text("windows.todopage.model.5e2c614c"), model));
        _dModel = model;

        var effort = new TextBox
        {
            Text = draft?.Effort ?? Format.Text(card, "effort"),
            PlaceholderText = L10n.Text("windows.todopage.default_effort.58c96ef8"),
        };
        effort.TextChanged += (_, _) => _detailDirty = true;
        body.Children.Add(Labeled(L10n.Text("windows.todopage.effort.4387e5d3"), effort));
        _dEffort = effort;

        var (budgetValue, budgetUnit, noLimit) = draft is not null
            ? (draft.BudgetText, draft.BudgetUnit, draft.NoLimit)
            : WorkbenchOps.SplitBudget((ulong)Format.Long(card, "budgetSeconds"));
        var budget = new TextBox { Text = budgetValue, MinWidth = 100 };
        budget.TextChanged += (_, _) => _detailDirty = true;
        var unit = Chrome.BudgetUnits(budgetUnit);
        // Selection first, handler after: the initial pick is not an edit.
        unit.SelectionChanged += (_, _) => _detailDirty = true;
        var noLimitBox = new CheckBox { Content = L10n.Text("windows.todopage.no_limit.f7fcff0d"), IsChecked = noLimit };
        noLimitBox.Click += (_, _) => _detailDirty = true;
        var budgetRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        budgetRow.Children.Add(budget);
        budgetRow.Children.Add(unit);
        budgetRow.Children.Add(noLimitBox);
        body.Children.Add(Labeled(L10n.Text("windows.todopage.time_limit.e592a9ca"), budgetRow));
        _dBudget = budget;
        _dUnit = unit;
        _dNoLimit = noLimitBox;

        if (_conflictId == id)
        {
            body.Children.Add(Chrome.Banner(
                L10n.Text("windows.todopage.this_task_changed_since_you_opened_it_comp.e4a26988"),
                Theme.Warning,
                Symbol.Important));
            var conflictRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
            conflictRow.Children.Add(ActionIconGlyph.PrimaryButton(
                L10n.Text("windows.todopage.save_anyway.ef4c87b5"), ActionIcon.Save, async (_, _) =>
                {
                    SnapshotDraft();
                    await SaveDraftAsync(id, force: true);
                }));
            conflictRow.Children.Add(ActionIconGlyph.Button(
                L10n.Text("windows.todopage.take_saved.932c55d7"), ActionIcon.Restore, async (_, _) =>
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
            L10n.Text("common.save"), ActionIcon.Save, async (_, _) =>
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
                    L10n.Text("windows.todopage.move_to_0.699bb2f5", $"{caption}"), ActionIcon.Move, async (_, _) => await MoveAsync(id, target)));
            }
        }
        if (Format.Text(card, "column") == "archive")
        {
            actions.Children.Add(ActionIconGlyph.Button(
                L10n.Text("common.restore"), ActionIcon.Restore, async (_, _) => await MoveAsync(id, "backlog")));
        }
        else
        {
            actions.Children.Add(ActionIconGlyph.Button(
                L10n.Text("common.archive"), ActionIcon.Archive, async (_, _) => await MoveAsync(id, "archive")));
        }
        if (!_confirmDelete)
        {
            actions.Children.Add(ActionIconGlyph.Button(
                L10n.Text("common.delete"), ActionIcon.Delete, (_, _) =>
                {
                    SnapshotDraft();
                    _confirmDelete = true;
                    RenderDetail();
                }));
        }
        else
        {
            actions.Children.Add(ActionIconGlyph.Button(
                L10n.Text("common.back"), ActionIcon.Back, (_, _) =>
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
                Text = L10n.Text("windows.todopage.delete_0_this_removes_the_task_from_this_c.615625b6", $"{Format.Text(card, "title")}"),
                TextWrapping = TextWrapping.Wrap,
            });
            var confirmRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
            confirmRow.Children.Add(ActionIconGlyph.Button(
                L10n.Text("windows.todopage.delete_task.3baf5547"), ActionIcon.Delete, async (_, _) => await DeleteAsync(id)));
            confirm.Children.Add(confirmRow);
            body.Children.Add(confirm);
        }

        return Chrome.Card(
            Format.Text(card, "title", L10n.Text("windows.todopage.task.4bc74b21")),
            body,
            L10n.Text("windows.todopage.revision_0_1.5721f8ac", $"{_detailRevision?.ToString() ?? L10n.Text("windows.todopage.unknown.b23a6a84")}", $"{FolderLabel(workspaceId)}"));
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
            Banner(L10n.Text("windows.todopage.give_this_task_a_title.30531d14"));
            return;
        }
        if (cleanTitle.Length > 4096)
        {
            Banner(L10n.Text("windows.todopage.shorten_the_title_to_4_kib_or_less.f40e37a7"));
            return;
        }
        if (draft.Prompt.Length > 1024 * 1024)
        {
            Banner(L10n.Text("windows.todopage.shorten_the_prompt_to_1_mib_or_less.dba63070"));
            return;
        }
        if (draft.Priority is not ("low" or "normal" or "high"))
        {
            Banner(L10n.Text("windows.todopage.choose_a_task_priority.d4cee784"));
            return;
        }
        var seconds = WorkbenchOps.BudgetSeconds(draft.BudgetText, draft.BudgetUnit, draft.NoLimit);
        if (seconds is null)
        {
            Banner(L10n.Text("windows.todopage.enter_a_positive_time_limit_or_choose_no_l.3b7996e8"));
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
                    Banner(L10n.Text("windows.todopage.reload_this_task_before_saving_its_setting.afe9a32c"));
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
                    Banner(L10n.Text("windows.todopage.this_task_changed_since_you_opened_it_comp.e4a26988"));
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
            Notice(L10n.Text("windows.todopage.saved_0.8eb4b783", $"{cleanTitle}"));
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
                    Banner(L10n.Text("windows.todopage.reload_this_task_before_deleting_it.d6fd1986"));
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
            Notice(L10n.Text("windows.todopage.task_deleted.e954e713"));
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
                    L10n.Text("windows.todopage.check_again.fb7099ad"), ActionIcon.Refresh, async (_, _) => await CheckRunAsync()));
                retryRow.Children.Add(ActionIconGlyph.Button(
                    L10n.Text("common.retry"), ActionIcon.Run, async (_, _) => await RetryRunAsync()));
                body.Children.Add(retryRow);
            }
        }

        if (!string.IsNullOrEmpty(status))
        {
            var line = new TextBlock
            {
                Text = string.IsNullOrEmpty(runId)
                    ? WorkbenchOps.RunLabel(status)
                    : L10n.Text("windows.todopage.0_run_1.c42ad067", $"{WorkbenchOps.RunLabel(status)}", $"{runId}"),
                TextWrapping = TextWrapping.Wrap,
            };
            body.Children.Add(line);
        }

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        var canRun = !running && _pendingRunOp is null && !_working;
        var backButton = ActionIconGlyph.Button(
            L10n.Text("windows.todopage.run_in_background.c7b156d3"), ActionIcon.Run, async (_, _) => await RunAsync(id, "background"));
        backButton.IsEnabled = canRun;
        var frontButton = ActionIconGlyph.Button(
            L10n.Text("windows.todopage.run_in_foreground.a995d3eb"), ActionIcon.Run, async (_, _) => await RunAsync(id, "foreground"));
        frontButton.IsEnabled = canRun;
        actions.Children.Add(backButton);
        actions.Children.Add(frontButton);
        if (running && !string.IsNullOrEmpty(runId))
        {
            actions.Children.Add(ActionIconGlyph.Button(
                L10n.Text("common.stop"), ActionIcon.Stop, async (_, _) => await StopAsync(id, runId)));
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
                Text = L10n.Text("windows.todopage.no_run_yet_run_this_task_to_see_its_result.57e240ef"),
                Opacity = 0.66,
                TextWrapping = TextWrapping.Wrap,
            });
        }
        return Chrome.Card(L10n.Text("common.run"), body, FolderLabel(Format.Text(card, "workspaceId")));
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
                Text = L10n.Text("windows.todopage.the_run_is_not_in_this_computer_s_history.c6fd51cc"),
                Opacity = 0.66,
                TextWrapping = TextWrapping.Wrap,
            });
            return body;
        }
        var status = Format.Text(run, "status");
        body.Children.Add(new TextBlock
        {
            Text = $"{Format.Text(run, "name", L10n.Text("common.run"))} · {WorkbenchOps.RunLabel(status)}",
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
            L10n.Text("windows.todopage.view_transcript.f5190d98"), ActionIcon.History, async (_, _) => await LoadTranscriptAsync(runId)));
        body.Children.Add(row);
        var workspaceId = Format.Text(card, "workspaceId");
        body.Children.Add(new TextBlock
        {
            Text = string.IsNullOrEmpty(workspaceId)
                ? L10n.Text("windows.todopage.this_task_has_no_folder_assign_one_to_revi.ec78820b")
                : L10n.Text("windows.todopage.review_0_uncommitted_files_in_changes_prev.42175e1f", $"{FolderLabel(workspaceId)}"),
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
            _transcripts[runId] = string.IsNullOrEmpty(text) ? L10n.Text("windows.todopage.empty_transcript.5e12fcc2") : text;
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
            return L10n.Text("windows.todopage.assign_a_folder_before_running_this_task.6d7e591f");
        }
        if (string.IsNullOrEmpty(Format.Text(card, "backend").Trim()))
        {
            return L10n.Text("windows.todopage.choose_an_agent_before_running_this_task.8c283f81");
        }
        var prompt = Format.Text(card, "notes").Trim();
        if (string.IsNullOrEmpty(prompt) && string.IsNullOrEmpty(Format.Text(card, "title").Trim()))
        {
            return L10n.Text("windows.todopage.write_a_prompt_before_running_this_task.756d3037");
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
                _runError = L10n.Text("windows.todopage.save_the_task_before_running_it.8446db80");
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
                    _runError = L10n.Text("windows.todopage.reload_this_task_before_running_it.838b5311");
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
                        ? L10n.Text("windows.todopage.foreground_run_started_in_a_terminal.c4cc5790")
                        : L10n.Text("windows.todopage.handed_the_task_to_an_agent.f001c919"));
                }
                catch (Exception ex)
                {
                    _runError = L10n.Text("windows.todopage.the_run_result_is_not_confirmed_check_this.b7631660", $"{ex.Message}");
                    RenderDetail();
                    return;
                }
            }
            else
            {
                await CallTodoAsync("todo.delegate", new JsonObject { ["id"] = id });
                Notice(L10n.Text("windows.todopage.handed_the_task_to_an_agent.f001c919"));
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
                Notice(L10n.Text("windows.todopage.the_run_is_confirmed.fa711bc2"));
                await LoadAsync(quiet: true);
                RenderBoard();
            }
            else
            {
                _runError = L10n.Text("windows.todopage.the_computer_has_not_accepted_this_run_req.956da73e");
            }
        }
        catch (Exception ex)
        {
            _runError = L10n.Text("windows.todopage.the_run_result_is_still_unavailable_your_r.294ee202", $"{ex.Message}");
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
                _runError = L10n.Text("windows.todopage.reload_this_task_before_retrying_the_run.b57793dc");
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
            Notice(L10n.Text("windows.todopage.the_run_is_confirmed.fa711bc2"));
        }
        catch (Exception ex)
        {
            _runError = L10n.Text("windows.todopage.the_run_result_is_not_confirmed_check_this.b7631660", $"{ex.Message}");
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
                    Banner(L10n.Text("windows.todopage.reload_this_task_before_stopping_it.727e7588"));
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
            Notice(L10n.Text("windows.todopage.stopped.f8ec77e7"));
        }
        catch (Exception ex)
        {
            Banner(L10n.Text("windows.todopage.the_stop_was_not_confirmed_reload_this_tas.ea360237", $"{ex.Message}"));
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
