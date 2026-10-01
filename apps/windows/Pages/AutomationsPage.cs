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
using Tokenstat.Notifications;

namespace Tokenstat.Pages;

/// <summary>
/// Scheduled jobs on this host. Matches the Mac workbench: a Writing and
/// Settings editor, the host scheduler timezone on every wall-clock time,
/// host-level queue settings, live-first run history, and revision-checked
/// saves with receipts on protocol 21 and later.
/// </summary>
internal sealed partial class AutomationsPage : Page, IInspectorContent, IToolbarItems
{
    private readonly string? _scopeWorkspaceId;
    private readonly Grid _root = new() { RowSpacing = Theme.SpaceM };
    private readonly StackPanel _bannerHost = new() { Spacing = Theme.SpaceS };
    private readonly Grid _listHost = new();
    private readonly StackPanel _detailHost = new()
    {
        Spacing = Theme.SpaceL,
        Padding = new Thickness(Theme.SpaceM),
    };
    private readonly TextBox _searchBox;

    private JsonArray _jobs = new();
    private JsonArray _runs = new();
    private List<(string Id, string Name)> _folders = new();
    private List<(string Id, string Label)> _backends = new();
    private Dictionary<string, JsonObject> _rawJobs = new();
    private long? _protocol;
    private ulong _queueBudget = 10_800;
    private uint _queueConcurrent = 1;
    private string _queueTimezone = "";
    private string _query = "";
    private bool _working;
    private string? _selectedId;
    private bool _creating;
    private readonly AutomationEditorState<JobDraft> _editorState = new();
    private JobDraft? _draft { get => _editorState.Draft; set => _editorState.Draft = value; }
    private bool _detailDirty;
    private ulong? _detailRevision { get => _editorState.Revision; set => _editorState.Revision = value; }
    private string? _conflictId;
    private bool _confirmDelete;
    private string? _pendingCreateOp;
    private string? _pendingRunOp;
    private string? _pendingRunJob;
    private string? _runError;
    private int _historyShown = WorkbenchOps.RunPreviewCount;
    private Dictionary<string, (string Text, ulong Next)> _transcripts = new();

    private TextBox? _dName;
    private TextBox? _dPrompt;
    private ComboBox? _dFolder;
    private ComboBox? _dBackend;
    private TextBox? _dModel;
    private TextBox? _dEffort;
    private TextBox? _dBudget;
    private ComboBox? _dBudgetUnit;
    private CheckBox? _dNoLimit;
    private CheckBox? _dEnabled;
    private ComboBox? _dKind;
    private TextBox? _dInterval;
    private ComboBox? _dHour;
    private ComboBox? _dMinute;
    private ComboBox? _dWeekday;
    private CheckBox[] _dDays = new CheckBox[7];

    /// <summary>
    /// The user's unsent field values. Kept across reloads so Save anyway
    /// retries the same draft and Take saved throws it away.
    /// </summary>
    private sealed class JobDraft
    {
        public string Name = "";
        public string Prompt = "";
        public string FolderId = "";
        public string BackendId = "";
        public string Model = "";
        public string Effort = "";
        public string BudgetText = "180";
        public string BudgetUnit = "minutes";
        public bool NoLimit;
        public bool Enabled = true;
        public string Kind = "once";
        public string IntervalMinutes = "60";
        public int Hour = 9;
        public int Minute;
        public int Weekday;
        public int CustomDays = 31;
    }

    public AutomationsPage(string? workspaceId = null)
    {
        _scopeWorkspaceId = workspaceId;
        _searchBox = Chrome.SearchField(L10n.Text("windows.automationspage.search_automations.bdff71b2"), text =>
        {
            _query = text ?? "";
            RenderList();
        });
        // Full width, like the Mac search box: a capped field stops halfway
        // across its column and leaves dead background beside itself.
        _searchBox.HorizontalAlignment = HorizontalAlignment.Stretch;
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _root.Children.Add(_bannerHost);
        Grid.SetRow(_searchBox, 1);
        _root.Children.Add(_searchBox);
        Grid.SetRow(_listHost, 2);
        _root.Children.Add(_listHost);
        // A wireframe until the first load lands. RenderList clears the host,
        // so real content replaces it, like Home's skeleton.
        _listHost.Children.Add(Motion.SkeletonCard());
        Content = new Border { Padding = new Thickness(Theme.SpaceM), Child = _root };
        RenderDetail();
        Loaded += async (_, _) =>
        {
            var mounted = _tableMount.Capture();
            await LoadAsync();
            if (mounted.IsCurrent && IsLoaded) StartTablePolling();
        };
        Unloaded += (_, _) => { _tableMount.Advance(); StopTablePolling(); };
    }

    public event Action? ToolbarChanged;

    /// <summary>
    /// The folder this screen belongs to, or null on the global list.
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
    /// The inspector column content: the selected job's detail, history, and
    /// run views. Selection and reloads replace its children, so the column
    /// stays live without the shell asking again.
    /// </summary>
    public UIElement? Inspector => _detailHost;
    public double MinimumContentWidth => 640;

    public IList<UIElement> ToolbarActions()
    {
        return TableToolbarActions();
    }

    private void RaiseToolbarChanged() => ToolbarChanged?.Invoke();

    private void StartCreating()
    {
        _creating = true;
        _selectedId = null;
        _draft = DefaultDraft();
        _detailDirty = false;
        _conflictId = null;
        _confirmDelete = false;
        _runError = null;
        RenderDetail();
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

    /// <summary>
    /// One workbench method against this screen's folder, local or remote. A
    /// remote folder travels as remote.call with the peer's own folder id.
    /// Params are copied, never mutated, so a retry cannot forward an already
    /// rewritten id. The global list has no folder and always stays local.
    /// </summary>
    private Task<JsonNode> CallWorkbenchAsync(string method, JsonNode? parameters = null)
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
    /// The protocol of the host that owns these jobs: the peer's sessionless
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

    private async Task LoadAsync()
    {
        SnapshotDraft();
        _tableGeneration++;
        _working = true;
        try
        {
            _protocol = await ProtocolAsync();
            var listTask = CallWorkbenchAsync("automation.list", new JsonObject());
            var runsTask = CallWorkbenchAsync("automation.runs", new JsonObject());
            var foldersTask = CallWorkbenchAsync("workspace.list", new JsonObject());
            var backendsTask = CallWorkbenchAsync("automation.backends", new JsonObject());
            var queueTask = CallWorkbenchAsync("automation.queue", new JsonObject());
            await Task.WhenAll(listTask, runsTask, foldersTask, backendsTask, queueTask);
            _jobs = Format.Items(listTask.Result) ?? new JsonArray();
            _runs = Format.Items(runsTask.Result) ?? new JsonArray();
            if (_scopeWorkspaceId is null || !RemoteWorkspaces.TrySplit(_scopeWorkspaceId, out _, out _))
            {
                RunNotifications.Shared.SettleAutomations(_runs);
            }
            _folders = ReadFolders(foldersTask.Result);
            if (_scopeWorkspaceId is not null
                && RemoteWorkspaces.TrySplit(_scopeWorkspaceId, out _, out var inner))
            {
                // Jobs from the peer carry its own folder id. Namespace them
                // to this page's folder id so the scope filter below keeps
                // matching, and list the folder itself so its name resolves.
                foreach (var job in _jobs)
                {
                    if (job is JsonObject obj && Format.Text(obj, "workspaceId") == inner)
                    {
                        obj["workspaceId"] = _scopeWorkspaceId;
                    }
                }
                foreach (var run in _runs.OfType<JsonObject>())
                    if (Format.Text(run, "workspaceId") == inner) run["workspaceId"] = _scopeWorkspaceId;
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
            _rawJobs = new Dictionary<string, JsonObject>();
            foreach (var job in _jobs)
            {
                var id = Format.Text(job, "id");
                if (!string.IsNullOrEmpty(id) && job is JsonObject raw)
                {
                    _rawJobs[id] = (JsonObject)raw.DeepClone();
                }
            }
            var queue = queueTask.Result;
            try { _queueBudget = queue["defaultBudgetSeconds"]?.GetValue<ulong>() ?? _queueBudget; } catch { /* keep */ }
            try { _queueConcurrent = queue["maxConcurrent"]?.GetValue<uint>() ?? _queueConcurrent; } catch { /* keep */ }
            _queueTimezone = Format.Text(queue, "timezone");
            // Table action buttons must reflect the completed load. Quiet
            // polling does not repaint an unchanged host response later.
            _working = false;
            RaiseToolbarChanged();
            RenderList();
            RenderDetail();
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
        }
        finally
        {
            _working = false;
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

    private string FolderLabel(string workspaceId)
    {
        if (string.IsNullOrEmpty(workspaceId))
        {
            return L10n.Text("windows.automationspage.uncategorized.8d40d123");
        }
        return _folders.FirstOrDefault(f => f.Id == workspaceId).Name ?? L10n.Text("windows.automationspage.folder.74ccd433");
    }

    private bool MatchesQuery(JsonNode? job)
    {
        var term = _query.Trim();
        if (string.IsNullOrEmpty(term))
        {
            return true;
        }
        return Format.Text(job, "name").Contains(term, StringComparison.OrdinalIgnoreCase)
            || Format.Text(job, "prompt").Contains(term, StringComparison.OrdinalIgnoreCase)
            || Format.Text(job, "backend").Contains(term, StringComparison.OrdinalIgnoreCase)
            || FolderLabel(Format.Text(job, "workspaceId")).Contains(term, StringComparison.OrdinalIgnoreCase);
    }

    private void RenderList() => RenderTableList();

    private UIElement QueueCard()
    {
        var body = new StackPanel { Spacing = Theme.SpaceM };
        var (budgetText, _, queueNoLimit) = _queueBudget == 0
            ? ("180", "minutes", true)
            : (_queueBudget % 60 == 0
                ? ((_queueBudget / 60).ToString(), "minutes", false)
                : (_queueBudget.ToString(), "seconds", false));
        var budget = new TextBox { Text = budgetText, MinWidth = 100 };
        var noLimit = new CheckBox { Content = L10n.Text("windows.automationspage.no_limit.f7fcff0d"), IsChecked = queueNoLimit };
        var budgetRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        budgetRow.Children.Add(budget);
        budgetRow.Children.Add(new TextBlock
        {
            Text = L10n.Text("windows.automationspage.minutes.90e63d85"),
            VerticalAlignment = VerticalAlignment.Center,
            Opacity = 0.68,
        });
        budgetRow.Children.Add(noLimit);
        body.Children.Add(Labeled(L10n.Text("windows.automationspage.default_time_limit.ce8a0efe"), budgetRow));
        var concurrent = new TextBox { Text = _queueConcurrent.ToString(), MinWidth = 100 };
        body.Children.Add(Labeled(L10n.Text("windows.automationspage.jobs_at_once.66276ffd"), concurrent));
        body.Children.Add(new TextBlock
        {
            Text = WorkbenchOps.ClockCaption("", _queueTimezone, subject: L10n.Text("windows.automationspage.times_are.e9a3f2bc")),
            FontSize = 12,
            Opacity = 0.68,
            TextWrapping = TextWrapping.Wrap,
        });
        var save = ActionIconGlyph.Button(L10n.Text("common.save"), ActionIcon.Save, async (_, _) =>
        {
            ulong seconds;
            if (noLimit.IsChecked == true)
            {
                seconds = 0;
            }
            else if (!ulong.TryParse(budget.Text.Trim(), out var minutes) || minutes == 0)
            {
                Banner(L10n.Text("windows.automationspage.enter_a_positive_default_time_limit_or_cho.81c37ef8"));
                return;
            }
            else
            {
                seconds = minutes * 60;
            }
            if (!uint.TryParse(concurrent.Text.Trim(), out var atOnce) || atOnce == 0)
            {
                Banner(L10n.Text("windows.automationspage.enter_how_many_jobs_may_run_at_once.cfed4e98"));
                return;
            }
            try
            {
                await CallWorkbenchAsync("automation.setQueue", new JsonObject
                {
                    ["defaultBudgetSeconds"] = seconds,
                    ["maxConcurrent"] = atOnce,
                });
                Notice(L10n.Text("windows.automationspage.scheduler_saved.4e10688a"));
            }
            catch (Exception ex)
            {
                Banner(ex.Message);
                return;
            }
            await LoadAsync();
        });
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        row.Children.Add(save);
        body.Children.Add(row);
        return Chrome.Card(L10n.Text("windows.automationspage.scheduler.d3a27d96"), body, L10n.Text("windows.automationspage.queue_settings_for_this_computer.31a48c0f"));
    }

    private List<JsonNode?> JobRuns(string jobId)
    {
        var array = new JsonArray();
        foreach (var run in _runs)
        {
            if (Format.Text(run, "jobId") == jobId)
            {
                array.Add(run?.DeepClone());
            }
        }
        return WorkbenchOps.OrderedRuns(array);
    }

    private JobDraft DefaultDraft()
    {
        var (budgetText, budgetUnit, noLimit) = _queueBudget == 0
            ? ("180", "minutes", true)
            : WorkbenchOps.SplitBudget(_queueBudget);
        return new JobDraft
        {
            FolderId = _scopeWorkspaceId ?? "",
            BudgetText = budgetText,
            BudgetUnit = budgetUnit,
            NoLimit = noLimit,
        };
    }

    private JsonNode? SelectedJob()
    {
        if (_selectedId is null)
        {
            return null;
        }
        foreach (var job in _jobs)
        {
            if (Format.Text(job, "id") == _selectedId)
            {
                return job;
            }
        }
        return null;
    }

    private JobDraft DraftFromJob(JsonNode job)
    {
        var schedule = job?["schedule"] ?? job;
        var kind = Format.Text(schedule, "kind", "once");
        if (WorkbenchOps.ScheduleKinds.All(k => k != kind))
        {
            kind = "once";
        }
        var (budgetText, budgetUnit, noLimit) = WorkbenchOps.SplitBudget((ulong)Format.Long(job, "budgetSeconds"));
        var weekdays = (int)Format.Long(schedule, "weekdays");
        return new JobDraft
        {
            Name = Format.Text(job, "name"),
            Prompt = Format.Text(job, "prompt"),
            FolderId = Format.Text(job, "workspaceId"),
            BackendId = Format.Text(job, "backend"),
            Model = Format.Text(job, "model"),
            Effort = Format.Text(job, "effort"),
            BudgetText = budgetText,
            BudgetUnit = budgetUnit,
            NoLimit = noLimit,
            Enabled = Format.Flag(job, "enabled"),
            Kind = kind,
            IntervalMinutes = Math.Max(1, Format.Long(schedule, "everySeconds") / 60).ToString(),
            Hour = schedule?["hour"] is null ? 9 : (int)Math.Clamp(Format.Long(schedule, "hour"), 0, 23),
            Minute = (int)Math.Clamp(Format.Long(schedule, "minute"), 0, 59),
            Weekday = (int)Math.Clamp(Format.Long(schedule, "weekday"), 0, 6),
            CustomDays = weekdays != 0 ? weekdays & 0x7F : 31,
        };
    }

    private void SnapshotDraft()
    {
        if (_dName is null)
        {
            return;
        }
        var days = 0;
        for (var bit = 0; bit < 7; bit++)
        {
            if (_dDays[bit]?.IsChecked == true)
            {
                days |= 1 << bit;
            }
        }
        _draft = new JobDraft
        {
            Name = _dName.Text,
            Prompt = _dPrompt?.Text ?? "",
            FolderId = ComboFolderId(_dFolder),
            BackendId = ComboBackendId(_dBackend),
            Model = _dModel?.Text ?? "",
            Effort = _dEffort?.Text ?? "",
            BudgetText = _dBudget?.Text ?? "180",
            BudgetUnit = _dBudgetUnit?.SelectedValue as string ?? "minutes",
            NoLimit = _dNoLimit?.IsChecked == true,
            Enabled = _dEnabled?.IsChecked == true,
            Kind = _dKind is null
                ? "once"
                : WorkbenchOps.ScheduleKinds[Math.Clamp(_dKind.SelectedIndex, 0, 5)],
            IntervalMinutes = _dInterval?.Text ?? "60",
            Hour = _dHour?.SelectedIndex ?? 9,
            Minute = _dMinute?.SelectedIndex ?? 0,
            Weekday = _dWeekday?.SelectedIndex ?? 0,
            CustomDays = days,
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

    private void RenderDetail()
    {
        if (_showingRuns)
        {
            _detailHost.Children.Clear();
            var selected = _runs.FirstOrDefault(run => Format.Text(run, "id") == _selectedRunId);
            if (selected is not null) _detailHost.Children.Add(RunRow(selected));
            else _detailHost.Children.Add(new TextBlock { Text = L10n.Text("windows.automationspage.select_a_run_to_read_its_result_and_transc.4d63e81f"), TextWrapping = TextWrapping.Wrap });
            return;
        }
        if (!_detailDirty)
        {
            if (_creating)
            {
                _draft ??= DefaultDraft();
            }
            else if (SelectedJob() is JsonNode fresh)
            {
                _editorState.Refresh(DraftFromJob(fresh), WorkbenchOps.Revision(fresh), _detailDirty);
            }
        }
        _detailHost.Children.Clear();
        if (_creating)
        {
            _detailHost.Children.Add(EditorCard(null));
            return;
        }
        var job = SelectedJob();
        if (job is null)
        {
            _detailHost.Children.Add(new TextBlock
            {
                Text = L10n.Text("windows.automationspage.select_an_automation.f5ff23f7"),
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            });
            _detailHost.Children.Add(new TextBlock
            {
                Text = L10n.Text("windows.automationspage.pick_a_job_to_edit_its_schedule_run_it_or.ff95953b"),
                Opacity = 0.66,
                TextWrapping = TextWrapping.Wrap,
            });
            return;
        }
        _detailHost.Children.Add(EditorCard(job));
        _detailHost.Children.Add(HistoryCard(Format.Text(job, "id")));
    }

    private UIElement EditorCard(JsonNode? job)
    {
        var id = job is null ? "" : Format.Text(job, "id");
        var draft = _draft ?? DefaultDraft();
        var body = new StackPanel { Spacing = Theme.SpaceM };

        body.Children.Add(new TextBlock
        {
            Text = L10n.Text("windows.automationspage.writing.a8bfae3e"),
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        var name = new TextBox { Text = draft.Name, PlaceholderText = L10n.Text("windows.automationspage.name.dcd1d522") };
        name.TextChanged += (_, _) => _detailDirty = true;
        body.Children.Add(Labeled(L10n.Text("windows.automationspage.name.dcd1d522"), name));
        _dName = name;

        var prompt = new TextBox
        {
            Text = draft.Prompt,
            PlaceholderText = L10n.Text("windows.automationspage.what_should_the_agent_do.99b09b41"),
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            MinHeight = 120,
        };
        prompt.TextChanged += (_, _) => _detailDirty = true;
        body.Children.Add(Labeled(L10n.Text("windows.automationspage.prompt.5c391238"), prompt));
        _dPrompt = prompt;

        var folderBox = new ComboBox { MinWidth = 200 };
        var folderNames = new List<string> { L10n.Text("windows.automationspage.choose_a_folder.5c71b8cd") };
        folderNames.AddRange(_folders.Select(f => f.Name));
        folderBox.ItemsSource = folderNames;
        var folderIndex = _folders.FindIndex(f => f.Id == draft.FolderId);
        folderBox.SelectedIndex = folderIndex >= 0 ? folderIndex + 1 : 0;
        folderBox.SelectionChanged += (_, _) => _detailDirty = true;
        body.Children.Add(Labeled(L10n.Text("windows.automationspage.folder.74ccd433"), folderBox));
        _dFolder = folderBox;

        var backendBox = new ComboBox { MinWidth = 200 };
        var backendNames = new List<string> { L10n.Text("windows.automationspage.choose_an_agent.b6890bc2") };
        backendNames.AddRange(_backends.Select(b => b.Label));
        backendBox.ItemsSource = backendNames;
        var backendIndex = _backends.FindIndex(b => b.Id == draft.BackendId);
        backendBox.SelectedIndex = backendIndex >= 0 ? backendIndex + 1 : 0;
        backendBox.SelectionChanged += (_, _) => _detailDirty = true;
        body.Children.Add(Labeled(L10n.Text("windows.automationspage.agent.11b39c93"), backendBox));
        _dBackend = backendBox;

        var model = new TextBox { Text = draft.Model, PlaceholderText = L10n.Text("windows.automationspage.default_model.3840d9d2") };
        model.TextChanged += (_, _) => _detailDirty = true;
        body.Children.Add(Labeled(L10n.Text("windows.automationspage.model.5e2c614c"), model));
        _dModel = model;

        var effort = new TextBox { Text = draft.Effort, PlaceholderText = L10n.Text("windows.automationspage.default_effort.58c96ef8") };
        effort.TextChanged += (_, _) => _detailDirty = true;
        body.Children.Add(Labeled(L10n.Text("windows.automationspage.effort.4387e5d3"), effort));
        _dEffort = effort;

        var budget = new TextBox { Text = draft.BudgetText, MinWidth = 100 };
        budget.TextChanged += (_, _) => _detailDirty = true;
        var budgetUnit = Chrome.BudgetUnits(draft.BudgetUnit);
        budgetUnit.SelectionChanged += (_, _) => _detailDirty = true;
        var noLimit = new CheckBox { Content = L10n.Text("windows.automationspage.no_limit.f7fcff0d"), IsChecked = draft.NoLimit };
        noLimit.Click += (_, _) => _detailDirty = true;
        var budgetRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        budgetRow.Children.Add(budget);
        budgetRow.Children.Add(budgetUnit);
        budgetRow.Children.Add(noLimit);
        body.Children.Add(Labeled(L10n.Text("windows.automationspage.time_limit.e592a9ca"), budgetRow));
        _dBudget = budget;
        _dBudgetUnit = budgetUnit;
        _dNoLimit = noLimit;

        body.Children.Add(new TextBlock
        {
            Text = L10n.Text("common.settings"),
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        var enabled = new CheckBox { Content = L10n.Text("common.enabled"), IsChecked = draft.Enabled };
        enabled.Click += (_, _) => _detailDirty = true;
        body.Children.Add(enabled);
        _dEnabled = enabled;

        var kind = new ComboBox { MinWidth = 150 };
        kind.ItemsSource = new[] { L10n.Text("windows.automationspage.once.d88f6d83"), L10n.Text("windows.automationspage.interval.6f45b000"), L10n.Text("windows.automationspage.daily.b36c2611"), L10n.Text("windows.automationspage.weekdays.6f4b602b"), L10n.Text("windows.automationspage.weekly.29751324"), L10n.Text("windows.automationspage.custom.494ca78f") };
        kind.SelectedIndex = Math.Max(0, Array.IndexOf(WorkbenchOps.ScheduleKinds, draft.Kind));
        kind.SelectionChanged += (_, _) => _detailDirty = true;
        body.Children.Add(Labeled(L10n.Text("windows.automationspage.schedule.f4830a1d"), kind));
        _dKind = kind;

        var interval = new TextBox { Text = draft.IntervalMinutes, MinWidth = 100 };
        interval.TextChanged += (_, _) => _detailDirty = true;
        var intervalRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        intervalRow.Children.Add(interval);
        intervalRow.Children.Add(new TextBlock
        {
            Text = L10n.Text("windows.automationspage.minutes.90e63d85"),
            VerticalAlignment = VerticalAlignment.Center,
            Opacity = 0.68,
        });
        body.Children.Add(Labeled(L10n.Text("windows.automationspage.every.9b8617fd"), intervalRow));
        _dInterval = interval;

        var hour = new ComboBox { MinWidth = 80 };
        hour.ItemsSource = Enumerable.Range(0, 24).Select(h => h.ToString("00")).ToArray();
        hour.SelectedIndex = Math.Clamp(draft.Hour, 0, 23);
        hour.SelectionChanged += (_, _) => _detailDirty = true;
        var minute = new ComboBox { MinWidth = 80 };
        minute.ItemsSource = Enumerable.Range(0, 60).Select(m => m.ToString("00")).ToArray();
        minute.SelectedIndex = Math.Clamp(draft.Minute, 0, 59);
        minute.SelectionChanged += (_, _) => _detailDirty = true;
        var timeRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        timeRow.Children.Add(hour);
        timeRow.Children.Add(minute);
        body.Children.Add(Labeled(L10n.Text("windows.automationspage.time.33b93476"), timeRow));
        _dHour = hour;
        _dMinute = minute;

        var weekday = new ComboBox { MinWidth = 140 };
        weekday.ItemsSource = WorkbenchOps.DayNames.ToArray();
        weekday.SelectedIndex = Math.Clamp(draft.Weekday, 0, 6);
        weekday.SelectionChanged += (_, _) => _detailDirty = true;
        body.Children.Add(Labeled(L10n.Text("windows.automationspage.day.8f2364e1"), weekday));
        _dWeekday = weekday;

        var daysRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        for (var bit = 0; bit < 7; bit++)
        {
            var day = new CheckBox
            {
                Content = WorkbenchOps.DayShortNames[bit],
                IsChecked = (draft.CustomDays & (1 << bit)) != 0,
            };
            day.Click += (_, _) => _detailDirty = true;
            _dDays[bit] = day;
            daysRow.Children.Add(day);
        }
        body.Children.Add(Labeled(L10n.Text("windows.automationspage.days.e08c0aa8"), daysRow));

        // The host scheduler owns the zone. Never print a wall-clock time
        // without saying whose clock it is.
        body.Children.Add(new TextBlock
        {
            Text = WorkbenchOps.ClockCaption("", _queueTimezone),
            FontSize = 12,
            Opacity = 0.68,
            TextWrapping = TextWrapping.Wrap,
        });

        if (_conflictId == id && !_creating)
        {
            body.Children.Add(Chrome.Banner(
                L10n.Text("windows.automationspage.this_job_changed_since_you_opened_it_compa.ae02b985"),
                Theme.Warning,
                Symbol.Important));
            var conflictRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
            conflictRow.Children.Add(ActionIconGlyph.PrimaryButton(
                L10n.Text("windows.automationspage.save_anyway.ef4c87b5"), ActionIcon.Save, async (_, _) =>
                {
                    SnapshotDraft();
                    await SaveDraftAsync(force: true);
                }));
            conflictRow.Children.Add(ActionIconGlyph.Button(
                L10n.Text("windows.automationspage.take_saved.932c55d7"), ActionIcon.Restore, async (_, _) =>
                {
                    _conflictId = null;
                    _detailDirty = false;
                    _draft = null;
                    await LoadAsync();
                }));
            body.Children.Add(conflictRow);
        }

        if (_creating && _pendingCreateOp is not null)
        {
            body.Children.Add(new TextBlock
            {
                Text = L10n.Text("windows.automationspage.the_job_may_already_exist_check_this_reque.5fff3e32"),
                TextWrapping = TextWrapping.Wrap,
            });
            var checkRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
            checkRow.Children.Add(ActionIconGlyph.Button(
                L10n.Text("windows.automationspage.check_again.fb7099ad"), ActionIcon.Refresh, async (_, _) => await CheckCreationAsync()));
            body.Children.Add(checkRow);
        }

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        if (_creating)
        {
            var createButton = ActionIconGlyph.PrimaryButton(
                L10n.Text("windows.automationspage.create.4759498a"), ActionIcon.Create, async (_, _) =>
                {
                    SnapshotDraft();
                    await CreateDraftAsync();
                });
            createButton.IsEnabled = _pendingCreateOp is null && !_working;
            actions.Children.Add(createButton);
            actions.Children.Add(ActionIconGlyph.Button(
                L10n.Text("common.back"), ActionIcon.Back, (_, _) =>
                {
                    _creating = false;
                    _draft = null;
                    _detailDirty = false;
                    RenderDetail();
                }));
        }
        else
        {
            actions.Children.Add(ActionIconGlyph.PrimaryButton(
                L10n.Text("common.save"), ActionIcon.Save, async (_, _) =>
                {
                    SnapshotDraft();
                    await SaveDraftAsync(force: false);
                }));
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
        }
        body.Children.Add(actions);

        if (_confirmDelete && !_creating)
        {
            var confirm = new StackPanel { Spacing = Theme.SpaceS };
            confirm.Children.Add(new TextBlock
            {
                Text = L10n.Text("windows.automationspage.delete_0_this_removes_the_job_from_this_co.8a23ac57", $"{draft.Name}"),
                TextWrapping = TextWrapping.Wrap,
            });
            var confirmRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
            confirmRow.Children.Add(ActionIconGlyph.Button(
                L10n.Text("windows.automationspage.delete_job.be79dd9b"), ActionIcon.Delete, async (_, _) => await DeleteAsync()));
            confirm.Children.Add(confirmRow);
            body.Children.Add(confirm);
        }

        if (!string.IsNullOrEmpty(_runError) && _pendingRunJob == id)
        {
            body.Children.Add(Chrome.Banner(_runError, Theme.Warning, Symbol.Important));
            if (_pendingRunOp is not null)
            {
                var retryRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
                retryRow.Children.Add(ActionIconGlyph.Button(
                    L10n.Text("windows.automationspage.check_again.fb7099ad"), ActionIcon.Refresh, async (_, _) => await CheckRunAsync()));
                retryRow.Children.Add(ActionIconGlyph.Button(
                    L10n.Text("common.retry"), ActionIcon.Run, async (_, _) => await RetryRunAsync()));
                body.Children.Add(retryRow);
            }
        }

        var title = _creating ? L10n.Text("windows.automationspage.new_automation.db87a63d") : draft.Name;
        var subtitle = _creating
            ? null
            : L10n.Text("windows.automationspage.revision_0_1.5721f8ac", $"{_detailRevision?.ToString() ?? L10n.Text("windows.automationspage.unknown.b23a6a84")}", $"{FolderLabel(draft.FolderId)}");
        return Chrome.Card(string.IsNullOrEmpty(title) ? L10n.Text("windows.automationspage.automation.d909750b") : title, body, subtitle);
    }

    private string? ValidateDraft(JobDraft draft, out ulong budgetSeconds, out ulong everySeconds)
    {
        budgetSeconds = 0;
        everySeconds = 0;
        if (string.IsNullOrWhiteSpace(draft.Name))
        {
            return L10n.Text("windows.automationspage.give_this_job_a_name.8453c6c7");
        }
        if (draft.Name.Length > 4096)
        {
            return L10n.Text("windows.automationspage.shorten_the_name_to_4_kib_or_less.5579d8cf");
        }
        if (string.IsNullOrWhiteSpace(draft.Prompt))
        {
            return L10n.Text("windows.automationspage.write_what_the_agent_should_do.308a8211");
        }
        if (draft.Prompt.Length > 1024 * 1024)
        {
            return L10n.Text("windows.automationspage.shorten_the_prompt_to_1_mib_or_less.dba63070");
        }
        if (string.IsNullOrWhiteSpace(draft.FolderId))
        {
            return L10n.Text("windows.automationspage.choose_a_folder_for_this_job.62a1a81c");
        }
        if (string.IsNullOrWhiteSpace(draft.BackendId))
        {
            return L10n.Text("windows.automationspage.choose_an_agent_for_this_job.d585332f");
        }
        var budget = WorkbenchOps.BudgetSeconds(draft.BudgetText, draft.BudgetUnit, draft.NoLimit);
        if (budget is null)
        {
            return L10n.Text("windows.automationspage.enter_a_positive_time_limit_or_choose_no_l.3b7996e8");
        }
        budgetSeconds = budget.Value;
        if (draft.Kind == "interval")
        {
            if (!ulong.TryParse(draft.IntervalMinutes.Trim(), out var minutes) || minutes == 0)
            {
                return L10n.Text("windows.automationspage.pick_an_interval_of_at_least_one_minute.e57770a7");
            }
            try
            {
                everySeconds = checked(minutes * 60);
            }
            catch (OverflowException)
            {
                return L10n.Text("windows.automationspage.pick_a_shorter_interval.de6c6298");
            }
        }
        var scheduleError = WorkbenchOps.ScheduleValidation(draft.Kind, everySeconds, draft.CustomDays);
        if (scheduleError is not null)
        {
            return scheduleError;
        }
        return null;
    }

    private JsonObject JobPayload(JobDraft draft, string id, ulong budgetSeconds, ulong everySeconds)
    {
        var edited = new JsonObject
        {
            ["id"] = id,
            ["name"] = draft.Name.Trim(),
            ["backend"] = draft.BackendId,
            ["model"] = draft.Model.Trim(),
            ["effort"] = draft.Effort.Trim(),
            ["workspaceId"] = draft.FolderId,
            ["prompt"] = draft.Prompt.Trim(),
            ["schedule"] = WorkbenchOps.SchedulePayload(
                draft.Kind, everySeconds, draft.Hour, draft.Minute, draft.Weekday, draft.CustomDays),
            ["budgetSeconds"] = budgetSeconds,
            ["enabled"] = draft.Enabled,
        };
        // The editor holds the namespaced id; the peer stores its own.
        if (_scopeWorkspaceId is not null
            && RemoteWorkspaces.TrySplit(_scopeWorkspaceId, out _, out var inner)
            && Format.Text(edited, "workspaceId") == _scopeWorkspaceId)
        {
            edited["workspaceId"] = inner;
        }
        // Unknown host fields round-trip untouched.
        _rawJobs.TryGetValue(id, out var raw);
        return WorkbenchOps.PreserveUnknown(raw, edited);
    }

    private async Task CreateDraftAsync()
    {
        var draft = _draft;
        if (draft is null)
        {
            return;
        }
        var error = ValidateDraft(draft, out var budgetSeconds, out var everySeconds);
        if (error is not null)
        {
            Banner(error);
            return;
        }
        _working = true;
        try
        {
            var payload = JobPayload(draft, "", budgetSeconds, everySeconds);
            if (WorkbenchOps.AutomationReceipts(_protocol))
            {
                // One operation id for the whole creation. A lost answer is
                // checked with creationReceipt, never repeated as a new job.
                _pendingCreateOp = WorkbenchOps.NewOperationId("automation-create");
                try
                {
                    await CallWorkbenchAsync("automation.createOnce", new JsonObject
                    {
                        ["job"] = payload,
                        ["operationId"] = _pendingCreateOp,
                    });
                    _pendingCreateOp = null;
                    Notice(L10n.Text("windows.automationspage.automation_added.b6e2be6a"));
                    ResetEditor();
                }
                catch (Exception ex)
                {
                    Banner(L10n.Text("windows.automationspage.the_job_may_already_exist_check_this_reque.bae6162a", $"{ex.Message}"));
                    return;
                }
            }
            else
            {
                await CallWorkbenchAsync("automation.create", new JsonObject { ["job"] = payload });
                Notice(L10n.Text("windows.automationspage.automation_added.b6e2be6a"));
                ResetEditor();
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
        }
        await LoadAsync();
    }

    private async Task CheckCreationAsync()
    {
        if (_pendingCreateOp is null)
        {
            return;
        }
        try
        {
            var receipt = await CallWorkbenchAsync(
                "automation.creationReceipt", new JsonObject { ["operationId"] = _pendingCreateOp });
            if (receipt is JsonObject obj && obj.Count > 0 && receipt["job"] is not null)
            {
                _pendingCreateOp = null;
                Notice(L10n.Text("windows.automationspage.automation_added.b6e2be6a"));
                ResetEditor();
                await LoadAsync();
            }
            else
            {
                Banner(L10n.Text("windows.automationspage.the_computer_has_not_accepted_this_job_yet.a0003912"));
            }
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
        }
        RenderDetail();
    }

    private async Task SaveDraftAsync(bool force)
    {
        var draft = _draft;
        if (draft is null || _selectedId is null)
        {
            return;
        }
        var id = _selectedId;
        var error = ValidateDraft(draft, out var budgetSeconds, out var everySeconds);
        if (error is not null)
        {
            Banner(error);
            return;
        }
        _working = true;
        try
        {
            var payload = JobPayload(draft, id, budgetSeconds, everySeconds);
            if (WorkbenchOps.AutomationReceipts(_protocol))
            {
                var revision = force ? await FreshRevisionAsync(id) : _detailRevision;
                if (revision is null)
                {
                    Banner(L10n.Text("windows.automationspage.reload_this_job_before_saving_it.9425ae64"));
                    return;
                }
                payload["revision"] = revision.Value;
                try
                {
                    await CallWorkbenchAsync("automation.edit", new JsonObject
                    {
                        ["job"] = payload,
                        ["expectedRevision"] = revision.Value,
                    });
                }
                catch (Exception ex) when (WorkbenchOps.IsConflict(ex))
                {
                    _conflictId = id;
                    Banner(L10n.Text("windows.automationspage.this_job_changed_since_you_opened_it_compa.ae02b985"));
                    await LoadAsync();
                    RenderDetail();
                    return;
                }
            }
            else
            {
                await CallWorkbenchAsync("automation.update", new JsonObject { ["job"] = payload });
            }
            _detailDirty = false;
            _conflictId = null;
            _draft = null;
            Notice(L10n.Text("windows.automationspage.saved_0.8eb4b783", $"{draft.Name.Trim()}"));
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
        await LoadAsync();
    }

    private async Task<ulong?> FreshRevisionAsync(string id)
    {
        await LoadAsync();
        foreach (var job in _jobs)
        {
            if (Format.Text(job, "id") == id)
            {
                return WorkbenchOps.Revision(job);
            }
        }
        return null;
    }

    private void ResetEditor()
    {
        _creating = false;
        _selectedId = null;
        _draft = null;
        _detailDirty = false;
        _conflictId = null;
        _confirmDelete = false;
        _historyShown = WorkbenchOps.RunPreviewCount;
    }

    private async Task DeleteAsync()
    {
        SnapshotDraft();
        if (_selectedId is null)
        {
            return;
        }
        _working = true;
        try
        {
            await CallWorkbenchAsync(
                "automation.remove", new JsonObject { ["id"] = _selectedId });
            Notice(L10n.Text("windows.automationspage.automation_deleted.533e9bb1"));
            ResetEditor();
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
        await LoadAsync();
    }

    private async Task SetEnabledAsync(string id, bool enabled)
    {
        SnapshotDraft();
        try
        {
            await CallWorkbenchAsync(
                enabled ? "automation.enable" : "automation.disable",
                new JsonObject { ["id"] = id });
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
            return;
        }
        await LoadAsync();
    }

    private async Task RunAsync(string id)
    {
        SnapshotDraft();
        if (_working || _pendingRunOp is not null)
        {
            return;
        }
        _working = true;
        try
        {
            if (WorkbenchOps.AutomationReceipts(_protocol))
            {
                // One operation id for the whole launch. Retry and Check again
                // reuse it, so a lost answer can never start a second run.
                _pendingRunOp = WorkbenchOps.NewOperationId("automation-run");
                _pendingRunJob = id;
                _runError = null;
                try
                {
                    await CallWorkbenchAsync("automation.runOnce", new JsonObject
                    {
                        ["id"] = id,
                        ["operationId"] = _pendingRunOp,
                    });
                    _pendingRunOp = null;
                    _pendingRunJob = null;
                    Notice(L10n.Text("windows.automationspage.the_run_started.26f45968"));
                }
                catch (Exception ex)
                {
                    _runError = L10n.Text("windows.automationspage.the_run_result_is_not_confirmed_check_this.b7631660", $"{ex.Message}");
                    RenderDetail();
                    return;
                }
            }
            else
            {
                await CallWorkbenchAsync("automation.run", new JsonObject { ["id"] = id });
                Notice(L10n.Text("windows.automationspage.the_run_started.26f45968"));
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
        }
        await LoadAsync();
    }

    private async Task CheckRunAsync()
    {
        if (_pendingRunOp is null)
        {
            return;
        }
        try
        {
            var receipt = await CallWorkbenchAsync(
                "automation.runReceipt", new JsonObject { ["operationId"] = _pendingRunOp });
            if (receipt?["run"] is not null)
            {
                _pendingRunOp = null;
                _pendingRunJob = null;
                _runError = null;
                Notice(L10n.Text("windows.automationspage.the_run_is_confirmed.fa711bc2"));
                await LoadAsync();
            }
            else
            {
                _runError = L10n.Text("windows.automationspage.the_computer_has_not_accepted_this_run_req.956da73e");
                RenderDetail();
            }
        }
        catch (Exception ex)
        {
            _runError = L10n.Text("windows.automationspage.the_run_result_is_still_unavailable_your_r.294ee202", $"{ex.Message}");
            RenderDetail();
        }
    }

    private async Task RetryRunAsync()
    {
        if (_pendingRunOp is null || _pendingRunJob is null)
        {
            return;
        }
        try
        {
            // Same operation id as the first attempt: the host answers from
            // the receipt when it already accepted the run.
            await CallWorkbenchAsync("automation.runOnce", new JsonObject
            {
                ["id"] = _pendingRunJob,
                ["operationId"] = _pendingRunOp,
            });
            _pendingRunOp = null;
            _pendingRunJob = null;
            _runError = null;
            Notice(L10n.Text("windows.automationspage.the_run_is_confirmed.fa711bc2"));
            await LoadAsync();
        }
        catch (Exception ex)
        {
            _runError = L10n.Text("windows.automationspage.the_run_result_is_not_confirmed_check_this.b7631660", $"{ex.Message}");
            RenderDetail();
        }
    }

    private async Task KillAsync(string runId)
    {
        SnapshotDraft();
        try
        {
            await CallWorkbenchAsync("automation.kill", new JsonObject { ["id"] = runId });
            Notice(L10n.Text("windows.automationspage.stopped.f8ec77e7"));
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
            return;
        }
        await LoadAsync();
    }

    private UIElement HistoryCard(string jobId)
    {
        var body = new StackPanel { Spacing = Theme.SpaceS };
        var runs = JobRuns(jobId);
        var shown = runs.Take(_historyShown).ToList();
        foreach (var run in shown)
        {
            if (run is null)
            {
                continue;
            }
            body.Children.Add(RunRow(run));
        }
        if (runs.Count == 0)
        {
            body.Children.Add(new TextBlock
            {
                Text = L10n.Text("windows.automationspage.no_runs_yet_run_this_job_to_see_its_histor.a1596cf6"),
                Opacity = 0.66,
                TextWrapping = TextWrapping.Wrap,
            });
        }
        else if (runs.Count > shown.Count)
        {
            var remaining = runs.Count - shown.Count;
            body.Children.Add(ActionIconGlyph.Button(
                L10n.Text("windows.automationspage.earlier_runs_0.3be9f95d", $"{remaining}"), ActionIcon.History, (_, _) =>
                {
                    _historyShown += WorkbenchOps.RunPageSize;
                    RenderDetail();
                }));
        }
        return Chrome.Card(L10n.Text("windows.automationspage.run_history.addf321b"), body, L10n.Text("windows.automationspage.0_runs.fedf94fc", $"{runs.Count}"));
    }

    private UIElement RunRow(JsonNode run)
    {
        var runId = Format.Text(run, "id");
        var status = Format.Text(run, "status");
        var live = WorkbenchOps.IsRunning(run);
        var body = new StackPanel { Spacing = Theme.SpaceXs };
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
        if (_transcripts.TryGetValue(runId, out var saved))
        {
            body.Children.Add(new TextBlock
            {
                Text = saved.Text,
                TextWrapping = TextWrapping.Wrap,
                IsTextSelectionEnabled = true,
                Opacity = 0.9,
            });
            if (saved.Next > 0)
            {
                var offset = saved.Next;
                body.Children.Add(ActionIconGlyph.Button(
                    L10n.Text("windows.automationspage.more.d47d7cb0"), ActionIcon.More, async (_, _) => await LoadTranscriptAsync(runId, offset)));
            }
        }
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        row.Children.Add(ActionIconGlyph.Button(
            L10n.Text("windows.automationspage.transcript.721164f0"), ActionIcon.History, async (_, _) => await LoadTranscriptAsync(runId, 0)));
        if (live && !string.IsNullOrEmpty(runId))
        {
            var liveId = runId;
            row.Children.Add(ActionIconGlyph.Button(
                L10n.Text("common.stop"), ActionIcon.Stop, async (_, _) => await KillAsync(liveId)));
        }
        body.Children.Add(row);
        return body;
    }

    private async Task LoadTranscriptAsync(string runId, ulong offset)
    {
        SnapshotDraft();
        try
        {
            var answer = await CallWorkbenchAsync(
                "automation.transcript",
                new JsonObject { ["id"] = runId, ["offset"] = offset });
            var text = Format.Text(answer, "text");
            ulong next = 0;
            try { next = answer?["nextOffset"]?.GetValue<ulong>() ?? 0; } catch { /* keep */ }
            var previous = offset > 0 && _transcripts.TryGetValue(runId, out var kept) ? kept.Text : "";
            _transcripts[runId] = (previous + text, next);
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
        }
        RenderDetail();
    }
}
