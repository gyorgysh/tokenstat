// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Tokenstat.Design;

namespace Tokenstat.Pages;

internal sealed partial class AutomationsPage
{
    private bool _showingRuns;
    private string? _selectedRunId;
    private string? _historyJobId;
    private AutomationJobFilter _jobFilter;
    private AutomationJobSort _jobSort = AutomationJobSort.Name;
    private bool _jobDescending;
    private AutomationRunSort _runSort = AutomationRunSort.Started;
    private bool _runDescending = true;

    private IList<UIElement> TableToolbarActions()
    {
        var actions = new List<UIElement>
        {
            Buttons.ToolbarIcon(ActionIcon.Refresh, L10n.Text("windows.automationspage_table.reload_automations.465e2a11"), async (_, _) => { LogoRefresh.Began(); await LoadAsync(); }),
        };
        if (!_showingRuns)
        {
            var menu = new MenuFlyout();
            var labels = new[] { L10n.Text("windows.automationspage_table.all_automations.f64b2431"), L10n.Text("common.enabled"), L10n.Text("common.paused"), L10n.Text("windows.automationspage_table.last_run_failed.d86e53b5") };
            for (var index = 0; index < labels.Length; index++)
            {
                var value = (AutomationJobFilter)index;
                ContextMenus.Add(menu, labels[index] + (_jobFilter == value ? " ✓" : ""), () => { _jobFilter = value; RenderList(); RaiseToolbarChanged(); });
            }
            var filter = Buttons.ToolbarIcon(ActionIcon.Filter, L10n.Text("windows.automationspage_table.filter_0.af82fa7d", $"{labels[(int)_jobFilter]}"), (_, _) => { });
            filter.Flyout = menu;
            actions.Add(filter);
        }
        actions.Add(SegmentedCapsule.View(new List<(string Value, string Label, ActionIcon? Glyph)>
        { ("jobs", L10n.Text("windows.automationspage_table.jobs.2f17a0f8"), ActionIcon.Scheduled), ("runs", L10n.Text("windows.automationspage_table.runs.848f54e8"), ActionIcon.History) }, _showingRuns ? "runs" : "jobs", value =>
        {
            SnapshotDraft();
            _showingRuns = value == "runs";
            _historyJobId = null;
            _searchBox.PlaceholderText = _showingRuns ? L10n.Text("windows.automationspage_table.search_runs.26d6d37f") : L10n.Text("windows.automationspage_table.search_automations.bdff71b2");
            RenderList(); RenderDetail(); RaiseToolbarChanged();
            return Task.CompletedTask;
        }));
        var templates = new MenuFlyout();
        AddTemplate(templates, L10n.Text("windows.automationspage_table.daily_brief.ba6a6869"), L10n.Text("windows.automationspage_table.summarise_yesterday_s_usage_and_flag_anyth.46ae43e4"), "claude", "daily", 600, 8);
        AddTemplate(templates, L10n.Text("windows.automationspage_table.system_health_check.04b44a8a"), L10n.Text("windows.automationspage_table.check_disk_memory_and_cpu_and_confirm_the.1eeb5edf"), "sh", "interval", 120);
        AddTemplate(templates, L10n.Text("windows.automationspage_table.dependency_check.cb31b5a0"), L10n.Text("windows.automationspage_table.dependency_prompt"), "sh", "weekly", 900);
        AddTemplate(templates, L10n.Text("windows.automationspage_table.weekday_standup.26dadcac"), L10n.Text("windows.automationspage_table.summarise_open_work_and_anything_that_bloc.52f7cb29"), "claude", "weekdays", 600);
        AddTemplate(templates, L10n.Text("windows.automationspage_table.release.e020e3c6"), ReleaseTemplate, "claude", "once", 1800);
        var templateButton = Buttons.ToolbarIcon(ActionIcon.Source, L10n.Text("windows.automationspage_table.templates.56b564b7"), (_, _) => { });
        templateButton.Flyout = templates;
        templateButton.IsEnabled = _folders.Count > 0;
        actions.Add(templateButton);
        var scheduler = Buttons.ToolbarIcon(ActionIcon.Settings, L10n.Text("windows.automationspage_table.scheduler_time_limit_and_jobs_at_once.66a28d33"), (_, _) => { });
        scheduler.Flyout = new Flyout { Content = new ScrollViewer { Content = QueueCard(), MaxHeight = 540, MaxWidth = 400 } };
        actions.Add(scheduler);
        var create = ActionIconGlyph.Button(L10n.Text("windows.automationspage_table.new_automation.db87a63d"), ActionIcon.Create, (_, _) =>
        { _showingRuns = false; StartCreating(); RenderList(); RaiseToolbarChanged(); });
        create.IsEnabled = _folders.Count > 0;
        actions.Add(create);
        return actions;
    }

    private void AddTemplate(MenuFlyout menu, string name, string prompt, string backend, string kind, ulong budget, int hour = 9)
    {
        ContextMenus.Add(menu, name, () =>
        {
            _showingRuns = false;
            StartCreating();
            _draft = DefaultDraft();
            _draft.Name = name; _draft.Prompt = prompt; _draft.BackendId = backend;
            _draft.Kind = kind; _draft.Hour = hour; _draft.Minute = 0;
            _draft.IntervalMinutes = "60"; _draft.CustomDays = 31; _draft.Weekday = 0;
            (_draft.BudgetText, _draft.BudgetUnit, _draft.NoLimit) = WorkbenchOps.SplitBudget(budget);
            RenderDetail(); RenderList(); RaiseToolbarChanged();
        });
    }

    private static readonly string ReleaseTemplate = L10n.Text("windows.automationspage_table.ship_a_release_of_this_repository_1_read_h.ad0794e7");

    private void RenderTableList()
    {
        _listHost.Children.Clear();
        if (_showingRuns) { RenderRunsTable(); return; }
        var jobs = AutomationListLogic.SortJobs(_jobs.OfType<JsonObject>().Where(job =>
            Format.InWorkspace(job, _scopeWorkspaceId, includeUnscoped: true)
            && Format.Text(job, "id").Length > 0 && MatchesQuery(job)
            && AutomationListLogic.MatchesFilter(job, _runs, _jobFilter)), _jobSort, _jobDescending);
        if (jobs.Count == 0)
        {
            _listHost.Children.Add(EmptyState.View(L10n.Text("windows.automationspage_table.no_automations_match.f2d793e6"), L10n.Text("windows.automationspage_table.create_an_automation_clear_the_search_or_s.d5ca49af"), EmptyArtKind.Automations,
                ActionIconGlyph.Button(L10n.Text("windows.automationspage_table.show_all.2150d8df"), ActionIcon.Filter, (_, _) => { _jobFilter = AutomationJobFilter.All; _searchBox.Text = ""; RenderList(); RaiseToolbarChanged(); })));
            return;
        }
        double[] widths = [120, 90, 70, 90, 80, 64];
        var header = TableRow(widths);
        AddCell(header, 0, SortHeader(L10n.Text("windows.automationspage_table.name.dcd1d522"), _jobSort == AutomationJobSort.Name, _jobDescending, () => SortJobsBy(AutomationJobSort.Name)));
        AddCell(header, 1, Cell(L10n.Text("windows.automationspage_table.schedule.f4830a1d"))); AddCell(header, 2, Cell(L10n.Text("windows.automationspage_table.project.98595978")));
        AddCell(header, 3, SortHeader(L10n.Text("windows.automationspage_table.next_run.b3c0ab96"), _jobSort == AutomationJobSort.NextRun, _jobDescending, () => SortJobsBy(AutomationJobSort.NextRun)));
        AddCell(header, 4, SortHeader(L10n.Text("windows.automationspage_table.last_run.512a4821"), _jobSort == AutomationJobSort.LastRun, _jobDescending, () => SortJobsBy(AutomationJobSort.LastRun)));
        var list = TableList();
        foreach (var job in jobs)
        {
            var id = Format.Text(job, "id");
            var row = TableRow(widths);
            var name = Cell(Format.Text(job, "name", L10n.Text("windows.automationspage_table.automation.d909750b")));
            name.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
            name.Opacity = Format.Flag(job, "enabled") ? 1 : 0.65;
            ToolTipService.SetToolTip(name, Format.Text(job, "prompt"));
            AddCell(row, 0, name); AddCell(row, 1, Cell(Format.Cadence(job)));
            AddCell(row, 2, Cell(FolderLabel(Format.Text(job, "workspaceId"))));
            var enabled = Format.Flag(job, "enabled");
            AddCell(row, 3, Cell(!enabled ? L10n.Text("common.paused") : Format.Long(job, "nextRunAtMs") > 0 ? HostTime(Format.Long(job, "nextRunAtMs")) : L10n.Text("windows.automationspage_table.when_you_run_it.5d06a91f")));
            var last = AutomationListLogic.LastRun(job, _runs);
            var outcome = last is null ? L10n.Text("common.never") : WorkbenchOps.RunLabel(Format.Text(last, "status"));
            var lastCell = Cell(outcome);
            if (last is not null) { lastCell.Foreground = RunBrush(last); ToolTipService.SetToolTip(lastCell, outcome + " · " + HostTime(Format.Long(last, "startedAtMs"))); }
            AddCell(row, 4, lastCell);
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 0 };
            var live = JobRuns(id).FirstOrDefault(WorkbenchOps.IsRunning);
            var run = live is null ? Buttons.ToolbarIcon(ActionIcon.Run, L10n.Text("windows.automationspage_table.run_now.09913977"), async (_, _) => await RunAsync(id))
                : Buttons.ToolbarIcon(ActionIcon.Stop, L10n.Text("windows.automationspage_table.stop_this_run.7647f899"), async (_, _) => await KillAsync(Format.Text(live, "id")));
            run.IsEnabled = !_working && _pendingRunOp is null;
            actions.Children.Add(run); actions.Children.Add(ActionIconGlyph.MoreButton(L10n.Text("windows.automationspage_table.actions_for_0.29a5141b", $"{Format.Text(job, "name")}"), JobMenu(job)));
            AddCell(row, 5, actions);
            var item = new ListViewItem { Content = row, Tag = id, Padding = new Thickness(0), HorizontalContentAlignment = HorizontalAlignment.Stretch, ContextFlyout = JobMenu(job) };
            list.Items.Add(item);
            if (_selectedId == id) list.SelectedItem = item;
        }
        list.SelectionChanged += (_, _) => { if (list.SelectedItem is ListViewItem item && _rawJobs.TryGetValue((string)item.Tag, out var job)) SelectJob(job); };
        _listHost.Children.Add(TableFrame(header, list, widths.Sum() + 8 * 5));
    }

    private void RenderRunsTable()
    {
        var term = _query.Trim();
        var runs = AutomationListLogic.SortRuns(_runs.OfType<JsonObject>().Where(run =>
            Format.InWorkspace(run, _scopeWorkspaceId, includeUnscoped: true)
            && (_historyJobId is null || Format.Text(run, "jobId") == _historyJobId)
            && (term.Length == 0 || Format.Text(run, "name").Contains(term, StringComparison.OrdinalIgnoreCase)
                || FolderLabel(Format.Text(run, "workspaceId")).Contains(term, StringComparison.OrdinalIgnoreCase)
                || BackendLabel(Format.Text(run, "backend")).Contains(term, StringComparison.OrdinalIgnoreCase))), _runSort, _runDescending);
        if (runs.Count == 0) { _listHost.Children.Add(Chrome.Empty(L10n.Text("windows.automationspage_table.no_matching_runs.4178c0ba"), L10n.Text("windows.automationspage_table.runs_appear_here_when_an_automation_starts.1a991b40"), ActionIcon.History)); return; }
        double[] widths = [120, 70, 70, 120, 65, 80];
        var header = TableRow(widths);
        AddCell(header, 0, SortHeader(L10n.Text("windows.automationspage_table.automation.d909750b"), _runSort == AutomationRunSort.Name, _runDescending, () => SortRunsBy(AutomationRunSort.Name)));
        AddCell(header, 1, Cell(L10n.Text("windows.automationspage_table.agent.11b39c93"))); AddCell(header, 2, Cell(L10n.Text("windows.automationspage_table.project.98595978")));
        AddCell(header, 3, SortHeader(L10n.Text("windows.automationspage_table.started.ecbc89cd"), _runSort == AutomationRunSort.Started, _runDescending, () => SortRunsBy(AutomationRunSort.Started)));
        AddCell(header, 4, Cell(L10n.Text("windows.automationspage_table.duration.4fc52a3c")));
        AddCell(header, 5, SortHeader(L10n.Text("windows.automationspage_table.result.6e7d50e8"), _runSort == AutomationRunSort.Result, _runDescending, () => SortRunsBy(AutomationRunSort.Result)));
        var list = TableList();
        foreach (var run in runs)
        {
            var id = Format.Text(run, "id");
            var row = TableRow(widths);
            AddCell(row, 0, Cell(Format.Text(run, "name", L10n.Text("common.run")))); AddCell(row, 1, Cell(BackendLabel(Format.Text(run, "backend"))));
            AddCell(row, 2, Cell(FolderLabel(Format.Text(run, "workspaceId")))); AddCell(row, 3, Cell(HostTime(Format.Long(run, "startedAtMs"))));
            var ended = Format.Long(run, "endedAtMs"); var started = Format.Long(run, "startedAtMs");
            var duration = ended > started && started > 0 ? AutomationListLogic.Duration(started, ended) : WorkbenchOps.IsRunning(run) ? L10n.Text("common.running") : "—";
            AddCell(row, 4, Cell(duration));
            var result = Cell(WorkbenchOps.RunLabel(Format.Text(run, "status"))); result.Foreground = RunBrush(run); AddCell(row, 5, result);
            var menu = new MenuFlyout();
            ContextMenus.AddAsync(menu, L10n.Text("windows.automationspage_table.transcript.721164f0"), async () => { _selectedRunId = id; RenderDetail(); await LoadTranscriptAsync(id, 0); });
            if (WorkbenchOps.IsRunning(run)) ContextMenus.AddAsync(menu, L10n.Text("common.stop"), async () => await KillAsync(id));
            var item = new ListViewItem { Content = row, Tag = id, Padding = new Thickness(0), HorizontalContentAlignment = HorizontalAlignment.Stretch, ContextFlyout = menu };
            list.Items.Add(item); if (_selectedRunId == id) list.SelectedItem = item;
        }
        list.SelectionChanged += async (_, _) => { if (list.SelectedItem is ListViewItem item) { _selectedRunId = (string)item.Tag; RenderDetail(); if (!_transcripts.ContainsKey(_selectedRunId)) await LoadTranscriptAsync(_selectedRunId, 0); } };
        _listHost.Children.Add(TableFrame(header, list, widths.Sum() + 8 * 5));
    }

    private void SelectJob(JsonNode job)
    {
        _creating = false; _selectedId = Format.Text(job, "id"); _draft = null; _detailDirty = false;
        _detailRevision = WorkbenchOps.Revision(job); _conflictId = null; _confirmDelete = false; _runError = null;
        _historyShown = WorkbenchOps.RunPreviewCount; RenderDetail();
    }

    private MenuFlyout JobMenu(JsonNode job)
    {
        var id = Format.Text(job, "id"); var menu = new MenuFlyout();
        ContextMenus.Add(menu, L10n.Text("common.edit"), () => SelectJob(job));
        ContextMenus.AddAsync(menu, L10n.Text("windows.automationspage_table.run_now.09913977"), async () => await RunAsync(id));
        ContextMenus.AddAsync(menu, Format.Flag(job, "enabled") ? L10n.Text("windows.automationspage_table.pause.858e4ba7") : L10n.Text("common.resume"), async () => await SetEnabledAsync(id, !Format.Flag(job, "enabled")));
        ContextMenus.Add(menu, L10n.Text("windows.automationspage_table.run_history.addf321b"), () => { SnapshotDraft(); _showingRuns = true; _historyJobId = id; _searchBox.PlaceholderText = L10n.Text("windows.automationspage_table.search_runs.26d6d37f"); _searchBox.Text = ""; RenderList(); RenderDetail(); RaiseToolbarChanged(); });
        ContextMenus.Add(menu, L10n.Text("windows.automationspage_table.delete.9ce78fe3"), () => { SelectJob(job); _confirmDelete = true; RenderDetail(); });
        return menu;
    }

    private void SortJobsBy(AutomationJobSort sort) { _jobDescending = _jobSort == sort && !_jobDescending; _jobSort = sort; RenderList(); }
    private void SortRunsBy(AutomationRunSort sort) { _runDescending = _runSort == sort ? !_runDescending : sort == AutomationRunSort.Started; _runSort = sort; RenderList(); }
    private string BackendLabel(string id) => _backends.FirstOrDefault(backend => backend.Id == id).Label ?? id;
    private static Brush RunBrush(JsonNode run) => Format.Text(run, "status") switch
    { "error" => Theme.Brush(Theme.Danger), "ok" => Theme.AccentBrush, "running" or "starting" or "queued" or "stopping" => Theme.AccentBrush, _ => Theme.Brush(Theme.ControlGlyph) };
    private string HostTime(long milliseconds)
    {
        if (milliseconds <= 0) return L10n.Text("common.never");
        try
        {
            var time = DateTimeOffset.FromUnixTimeMilliseconds(milliseconds);
            if (_queueTimezone.Length > 0)
            {
                try { return TimeZoneInfo.ConvertTime(time, TimeZoneInfo.FindSystemTimeZoneById(_queueTimezone)).ToString("g"); }
                catch (TimeZoneNotFoundException) { }
                catch (InvalidTimeZoneException) { }
            }
            return time.UtcDateTime.ToString("g") + " UTC";
        }
        catch (ArgumentOutOfRangeException) { return L10n.Text("common.unknown"); }
    }
    private static TextBlock Cell(string text)
    {
        var cell = new TextBlock { Text = text, FontSize = 12, Opacity = 0.78, TextTrimming = TextTrimming.CharacterEllipsis, MaxLines = 1, VerticalAlignment = VerticalAlignment.Center };
        ToolTipService.SetToolTip(cell, text); return cell;
    }
    private static Button SortHeader(string title, bool selected, bool descending, Action sort)
    {
        var button = new Button { Content = title + (selected ? descending ? " ↓" : " ↑" : ""), BorderThickness = new Thickness(0), Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), Padding = new Thickness(0, 6, 0, 6), HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left };
        button.Click += (_, _) => sort(); ToolTipService.SetToolTip(button, L10n.Text("windows.automationspage_table.sort_by_0.c17fa279", $"{title}")); return button;
    }
    private static Grid TableRow(double[] widths)
    {
        var row = new Grid { ColumnSpacing = 8, Padding = new Thickness(8, 5, 8, 5), MinHeight = 40 };
        foreach (var width in widths) row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(width, GridUnitType.Star), MinWidth = width });
        return row;
    }
    private static void AddCell(Grid row, int column, FrameworkElement cell) { Grid.SetColumn(cell, column); row.Children.Add(cell); }
    private static ListView TableList() => new() { SelectionMode = ListViewSelectionMode.Single, HorizontalContentAlignment = HorizontalAlignment.Stretch };
    private static UIElement TableFrame(Grid header, ListView list, double minimumWidth)
    {
        var table = new Grid { MinWidth = minimumWidth + 32 };
        table.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        table.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        header.Margin = new Thickness(0, 0, 16, 0); table.Children.Add(header); Grid.SetRow(list, 1); table.Children.Add(list);
        var scroll = new ScrollViewer { Content = table, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollMode = ScrollMode.Enabled, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled, VerticalScrollMode = ScrollMode.Disabled };
        scroll.SizeChanged += (_, size) => table.Width = Math.Max(table.MinWidth, size.NewSize.Width);
        return scroll;
    }
}
