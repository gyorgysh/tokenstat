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
            Buttons.ToolbarIcon(ActionIcon.Refresh, "Reload automations", async (_, _) => { LogoRefresh.Began(); await LoadAsync(); }),
        };
        if (!_showingRuns)
        {
            var menu = new MenuFlyout();
            var labels = new[] { "All automations", "Enabled", "Paused", "Last run failed" };
            for (var index = 0; index < labels.Length; index++)
            {
                var value = (AutomationJobFilter)index;
                ContextMenus.Add(menu, labels[index] + (_jobFilter == value ? " ✓" : ""), () => { _jobFilter = value; RenderList(); RaiseToolbarChanged(); });
            }
            var filter = Buttons.ToolbarIcon(ActionIcon.Filter, "Filter: " + labels[(int)_jobFilter], (_, _) => { });
            filter.Flyout = menu;
            actions.Add(filter);
        }
        actions.Add(SegmentedCapsule.View(new List<(string Value, string Label, ActionIcon? Glyph)>
        { ("jobs", "Jobs", ActionIcon.Scheduled), ("runs", "Runs", ActionIcon.History) }, _showingRuns ? "runs" : "jobs", value =>
        {
            SnapshotDraft();
            _showingRuns = value == "runs";
            _historyJobId = null;
            _searchBox.PlaceholderText = _showingRuns ? "Search runs" : "Search automations";
            RenderList(); RenderDetail(); RaiseToolbarChanged();
            return Task.CompletedTask;
        }));
        var templates = new MenuFlyout();
        AddTemplate(templates, "Daily brief", "Summarise yesterday's usage and flag anything that needs attention.", "claude", "daily", 600, 8);
        AddTemplate(templates, "System health check", "Check disk, memory and CPU, and confirm the tokenstat daemon is running. Report anything abnormal.", "sh", "interval", 120);
        AddTemplate(templates, "Dependency check", "Check for outdated or vulnerable dependencies (npm audit and the package managers this project uses) and summarise what needs a bump.", "sh", "weekly", 900);
        AddTemplate(templates, "Weekday standup", "Summarise open work and anything that blocked progress yesterday. Keep it short.", "claude", "weekdays", 600);
        AddTemplate(templates, "Release", ReleaseTemplate, "claude", "once", 1800);
        var templateButton = Buttons.ToolbarIcon(ActionIcon.Source, "Templates", (_, _) => { });
        templateButton.Flyout = templates;
        templateButton.IsEnabled = _folders.Count > 0;
        actions.Add(templateButton);
        var scheduler = Buttons.ToolbarIcon(ActionIcon.Settings, "Scheduler: time limit and jobs at once", (_, _) => { });
        scheduler.Flyout = new Flyout { Content = new ScrollViewer { Content = QueueCard(), MaxHeight = 540, MaxWidth = 400 } };
        actions.Add(scheduler);
        var create = ActionIconGlyph.Button("New automation", ActionIcon.Create, (_, _) =>
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

    private const string ReleaseTemplate = """
        Ship a release of this repository.

        1. Read how this repo versions itself (workspace manifests, lockfile, app marketing version, changelog if one exists). Bump to the next version the same way the last release did. Refresh the lockfile if this project requires it.
        2. Commit the bump only. Match this repository's commit style (CONTRIBUTING, commitlint, or recent subjects). Do not mix other work into the bump.
        3. Push the branch to GitHub. Do not force. Do not amend published history.
        4. Wait for CI on that commit. Poll until it finishes. If anything fails, read the failing job, fix it, commit the fix, push, and wait again. Repeat until CI is green.
        5. Only then create an annotated version tag on that commit and push the tag. Do not tag a red commit. Do not move an existing tag.

        If the working tree is dirty with unrelated changes, stop and say so. If you cannot see CI, say what you could not check and stop before the tag.
        """;

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
            _listHost.Children.Add(EmptyState.View("No automations match", "Create an automation, clear the search, or show all jobs.", EmptyArtKind.Automations,
                ActionIconGlyph.Button("Show all", ActionIcon.Filter, (_, _) => { _jobFilter = AutomationJobFilter.All; _searchBox.Text = ""; RenderList(); RaiseToolbarChanged(); })));
            return;
        }
        double[] widths = [120, 90, 70, 90, 80, 64];
        var header = TableRow(widths);
        AddCell(header, 0, SortHeader("Name", _jobSort == AutomationJobSort.Name, _jobDescending, () => SortJobsBy(AutomationJobSort.Name)));
        AddCell(header, 1, Cell("Schedule")); AddCell(header, 2, Cell("Project"));
        AddCell(header, 3, SortHeader("Next run", _jobSort == AutomationJobSort.NextRun, _jobDescending, () => SortJobsBy(AutomationJobSort.NextRun)));
        AddCell(header, 4, SortHeader("Last run", _jobSort == AutomationJobSort.LastRun, _jobDescending, () => SortJobsBy(AutomationJobSort.LastRun)));
        var list = TableList();
        foreach (var job in jobs)
        {
            var id = Format.Text(job, "id");
            var row = TableRow(widths);
            var name = Cell(Format.Text(job, "name", "Automation"));
            name.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
            name.Opacity = Format.Flag(job, "enabled") ? 1 : 0.65;
            ToolTipService.SetToolTip(name, Format.Text(job, "prompt"));
            AddCell(row, 0, name); AddCell(row, 1, Cell(Format.Cadence(job)));
            AddCell(row, 2, Cell(FolderLabel(Format.Text(job, "workspaceId"))));
            var enabled = Format.Flag(job, "enabled");
            AddCell(row, 3, Cell(!enabled ? "Paused" : Format.Long(job, "nextRunAtMs") > 0 ? HostTime(Format.Long(job, "nextRunAtMs")) : "When you run it"));
            var last = AutomationListLogic.LastRun(job, _runs);
            var outcome = last is null ? "Never" : WorkbenchOps.RunLabel(Format.Text(last, "status"));
            var lastCell = Cell(outcome);
            if (last is not null) { lastCell.Foreground = RunBrush(last); ToolTipService.SetToolTip(lastCell, outcome + " · " + HostTime(Format.Long(last, "startedAtMs"))); }
            AddCell(row, 4, lastCell);
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 0 };
            var live = JobRuns(id).FirstOrDefault(WorkbenchOps.IsRunning);
            var run = live is null ? Buttons.ToolbarIcon(ActionIcon.Run, "Run now", async (_, _) => await RunAsync(id))
                : Buttons.ToolbarIcon(ActionIcon.Stop, "Stop this run", async (_, _) => await KillAsync(Format.Text(live, "id")));
            run.IsEnabled = !_working && _pendingRunOp is null;
            actions.Children.Add(run); actions.Children.Add(ActionIconGlyph.MoreButton("Actions for " + Format.Text(job, "name"), JobMenu(job)));
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
        if (runs.Count == 0) { _listHost.Children.Add(Chrome.Empty("No matching runs", "Runs appear here when an automation starts.", ActionIcon.History)); return; }
        double[] widths = [120, 70, 70, 120, 65, 80];
        var header = TableRow(widths);
        AddCell(header, 0, SortHeader("Automation", _runSort == AutomationRunSort.Name, _runDescending, () => SortRunsBy(AutomationRunSort.Name)));
        AddCell(header, 1, Cell("Agent")); AddCell(header, 2, Cell("Project"));
        AddCell(header, 3, SortHeader("Started", _runSort == AutomationRunSort.Started, _runDescending, () => SortRunsBy(AutomationRunSort.Started)));
        AddCell(header, 4, Cell("Duration"));
        AddCell(header, 5, SortHeader("Result", _runSort == AutomationRunSort.Result, _runDescending, () => SortRunsBy(AutomationRunSort.Result)));
        var list = TableList();
        foreach (var run in runs)
        {
            var id = Format.Text(run, "id");
            var row = TableRow(widths);
            AddCell(row, 0, Cell(Format.Text(run, "name", "Run"))); AddCell(row, 1, Cell(BackendLabel(Format.Text(run, "backend"))));
            AddCell(row, 2, Cell(FolderLabel(Format.Text(run, "workspaceId")))); AddCell(row, 3, Cell(HostTime(Format.Long(run, "startedAtMs"))));
            var ended = Format.Long(run, "endedAtMs"); var started = Format.Long(run, "startedAtMs");
            var duration = ended > started && started > 0 ? AutomationListLogic.Duration(started, ended) : WorkbenchOps.IsRunning(run) ? "Running" : "—";
            AddCell(row, 4, Cell(duration));
            var result = Cell(WorkbenchOps.RunLabel(Format.Text(run, "status"))); result.Foreground = RunBrush(run); AddCell(row, 5, result);
            var menu = new MenuFlyout();
            ContextMenus.AddAsync(menu, "Transcript", async () => { _selectedRunId = id; RenderDetail(); await LoadTranscriptAsync(id, 0); });
            if (WorkbenchOps.IsRunning(run)) ContextMenus.AddAsync(menu, "Stop", async () => await KillAsync(id));
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
        ContextMenus.Add(menu, "Edit", () => SelectJob(job));
        ContextMenus.AddAsync(menu, "Run now", async () => await RunAsync(id));
        ContextMenus.AddAsync(menu, Format.Flag(job, "enabled") ? "Pause" : "Resume", async () => await SetEnabledAsync(id, !Format.Flag(job, "enabled")));
        ContextMenus.Add(menu, "Run history", () => { SnapshotDraft(); _showingRuns = true; _historyJobId = id; _searchBox.PlaceholderText = "Search runs"; _searchBox.Text = ""; RenderList(); RenderDetail(); RaiseToolbarChanged(); });
        ContextMenus.Add(menu, "Delete…", () => { SelectJob(job); _confirmDelete = true; RenderDetail(); });
        return menu;
    }

    private void SortJobsBy(AutomationJobSort sort) { _jobDescending = _jobSort == sort && !_jobDescending; _jobSort = sort; RenderList(); }
    private void SortRunsBy(AutomationRunSort sort) { _runDescending = _runSort == sort ? !_runDescending : sort == AutomationRunSort.Started; _runSort = sort; RenderList(); }
    private string BackendLabel(string id) => _backends.FirstOrDefault(backend => backend.Id == id).Label ?? id;
    private static Brush RunBrush(JsonNode run) => Format.Text(run, "status") switch
    { "error" => Theme.Brush(Theme.Danger), "ok" => Theme.AccentBrush, "running" or "starting" or "queued" or "stopping" => Theme.AccentBrush, _ => Theme.Brush(Theme.ControlGlyph) };
    private string HostTime(long milliseconds)
    {
        if (milliseconds <= 0) return "Never";
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
        catch (ArgumentOutOfRangeException) { return "Unknown"; }
    }
    private static TextBlock Cell(string text)
    {
        var cell = new TextBlock { Text = text, FontSize = 12, Opacity = 0.78, TextTrimming = TextTrimming.CharacterEllipsis, MaxLines = 1, VerticalAlignment = VerticalAlignment.Center };
        ToolTipService.SetToolTip(cell, text); return cell;
    }
    private static Button SortHeader(string title, bool selected, bool descending, Action sort)
    {
        var button = new Button { Content = title + (selected ? descending ? " ↓" : " ↑" : ""), BorderThickness = new Thickness(0), Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), Padding = new Thickness(0, 6, 0, 6), HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left };
        button.Click += (_, _) => sort(); ToolTipService.SetToolTip(button, "Sort by " + title); return button;
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
