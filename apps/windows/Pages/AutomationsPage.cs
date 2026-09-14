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
using Tokenstat.Notifications;

namespace Tokenstat.Pages;

/// <summary>
/// Scheduled jobs on this host. Matches the Mac workbench: a Writing and
/// Settings editor, the host scheduler timezone on every wall-clock time,
/// host-level queue settings, live-first run history, and revision-checked
/// saves with receipts on protocol 21 and later.
/// </summary>
internal sealed class AutomationsPage : Page
{
    private readonly string? _scopeWorkspaceId;
    private readonly StackPanel _root = new() { Spacing = Theme.SpaceL };
    private readonly StackPanel _bannerHost = new() { Spacing = Theme.SpaceS };
    private readonly StackPanel _listHost = new() { Spacing = Theme.SpaceL };
    private readonly StackPanel _detailHost = new() { Spacing = Theme.SpaceL };

    private JsonArray _jobs = new();
    private JsonArray _runs = new();
    private List<(string Id, string Name)> _folders = new();
    private List<(string Id, string Label)> _backends = new();
    private Dictionary<string, JsonObject> _rawJobs = new();
    private long? _protocol;
    private ulong _queueBudget = 10_800;
    private uint _queueConcurrent = 1;
    private string _queueTimezone = "";
    private bool _working;
    private string? _selectedId;
    private bool _creating;
    private JobDraft? _draft;
    private bool _detailDirty;
    private ulong? _detailRevision;
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
        _root.Children.Add(Header());
        _root.Children.Add(_bannerHost);
        _root.Children.Add(_listHost);
        _root.Children.Add(_detailHost);
        // A wireframe until the first load lands. RenderList clears the host,
        // so real content replaces it, like Home's skeleton.
        _listHost.Children.Add(Motion.SkeletonCard());
        Content = new ScrollViewer
        {
            Padding = new Thickness(Theme.SpaceL),
            Content = _root,
        };
        Loaded += async (_, _) => await LoadAsync();
    }

    private UIElement Header()
    {
        var row = new Grid();
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var titles = new StackPanel { Spacing = 2 };
        titles.Children.Add(new TextBlock
        {
            Text = "Automations",
            FontSize = Fonts.PageTitle,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        titles.Children.Add(new TextBlock
        {
            Text = "Scheduled jobs run on this host when Always-on is on.",
            Opacity = 0.66,
            TextWrapping = TextWrapping.Wrap,
        });
        row.Children.Add(titles);
        var create = ActionIconGlyph.PrimaryButton(
            "New automation", ActionIcon.Create, (_, _) =>
            {
                _creating = true;
                _selectedId = null;
                _draft = DefaultDraft();
                _detailDirty = false;
                _conflictId = null;
                _confirmDelete = false;
                _runError = null;
                RenderDetail();
            });
        Grid.SetColumn(create, 1);
        row.Children.Add(create);
        var refresh = ActionIconGlyph.Button("Refresh", ActionIcon.Refresh, async (_, _) => await LoadAsync());
        Grid.SetColumn(refresh, 2);
        row.Children.Add(refresh);
        return row;
    }

    private static UIElement Labeled(string label, Control control)
    {
        var stack = new StackPanel { Spacing = Theme.SpaceXs };
        stack.Children.Add(new TextBlock
        {
            Text = label.ToUpperInvariant(),
            FontSize = 11,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Opacity = 0.58,
        });
        stack.Children.Add(control);
        return stack;
    }

    private async Task LoadAsync()
    {
        _working = true;
        try
        {
            _protocol = await WorkbenchOps.ProtocolAsync();
            var listTask = AppServices.Host.CallAsync("automation.list", new JsonObject());
            var runsTask = AppServices.Host.CallAsync("automation.runs", new JsonObject());
            var foldersTask = AppServices.Host.CallAsync("workspace.list", new JsonObject());
            var backendsTask = AppServices.Host.CallAsync("automation.backends", new JsonObject());
            var queueTask = AppServices.Host.CallAsync("automation.queue", new JsonObject());
            await Task.WhenAll(listTask, runsTask, foldersTask, backendsTask, queueTask);
            _jobs = Format.Items(listTask.Result) ?? new JsonArray();
            _runs = Format.Items(runsTask.Result) ?? new JsonArray();
            RunNotifications.Shared.SettleAutomations(_runs);
            _folders = ReadFolders(foldersTask.Result);
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
            return "Uncategorized";
        }
        return _folders.FirstOrDefault(f => f.Id == workspaceId).Name ?? "Folder";
    }

    private void RenderList()
    {
        _listHost.Children.Clear();
        _listHost.Children.Add(QueueCard());
        var list = new StackPanel { Spacing = Theme.SpaceS };
        foreach (var job in _jobs)
        {
            if (!Format.InWorkspace(job, _scopeWorkspaceId, includeUnscoped: true))
            {
                continue;
            }
            var id = Format.Text(job, "id");
            if (string.IsNullOrEmpty(id))
            {
                continue;
            }
            list.Children.Add(JobRow(job, id));
        }
        if (list.Children.Count == 0)
        {
            _listHost.Children.Add(EmptyState.View(
                "No automations yet",
                "Scheduled jobs run on this host when Always-on is on.",
                EmptyArtKind.Automations));
            return;
        }
        _listHost.Children.Add(Chrome.Card("Automations", list));
    }

    private UIElement QueueCard()
    {
        var body = new StackPanel { Spacing = Theme.SpaceM };
        var (budgetText, _, queueNoLimit) = _queueBudget == 0
            ? ("180", "minutes", true)
            : (_queueBudget % 60 == 0
                ? ((_queueBudget / 60).ToString(), "minutes", false)
                : (_queueBudget.ToString(), "seconds", false));
        var budget = new TextBox { Text = budgetText, MinWidth = 100 };
        var noLimit = new CheckBox { Content = "No limit", IsChecked = queueNoLimit };
        var budgetRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        budgetRow.Children.Add(budget);
        budgetRow.Children.Add(new TextBlock
        {
            Text = "minutes",
            VerticalAlignment = VerticalAlignment.Center,
            Opacity = 0.68,
        });
        budgetRow.Children.Add(noLimit);
        body.Children.Add(Labeled("Default time limit", budgetRow));
        var concurrent = new TextBox { Text = _queueConcurrent.ToString(), MinWidth = 100 };
        body.Children.Add(Labeled("Jobs at once", concurrent));
        body.Children.Add(new TextBlock
        {
            Text = WorkbenchOps.ClockCaption("", _queueTimezone, subject: "Times are"),
            FontSize = 12,
            Opacity = 0.68,
            TextWrapping = TextWrapping.Wrap,
        });
        var save = ActionIconGlyph.Button("Save", ActionIcon.Save, async (_, _) =>
        {
            ulong seconds;
            if (noLimit.IsChecked == true)
            {
                seconds = 0;
            }
            else if (!ulong.TryParse(budget.Text.Trim(), out var minutes) || minutes == 0)
            {
                Banner("Enter a positive default time limit, or choose No limit.");
                return;
            }
            else
            {
                seconds = minutes * 60;
            }
            if (!uint.TryParse(concurrent.Text.Trim(), out var atOnce) || atOnce == 0)
            {
                Banner("Enter how many jobs may run at once.");
                return;
            }
            try
            {
                await AppServices.Host.CallAsync("automation.setQueue", new JsonObject
                {
                    ["defaultBudgetSeconds"] = seconds,
                    ["maxConcurrent"] = atOnce,
                });
                Notice("Scheduler saved.");
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
        return Chrome.Card("Scheduler", body, "Host-level queue settings.");
    }

    private UIElement JobRow(JsonNode job, string id)
    {
        var name = Format.Text(job, "name", "Automation");
        var enabled = Format.Flag(job, "enabled");
        var cadence = Format.Cadence(job);
        var body = new StackPanel { Spacing = Theme.SpaceS };
        var line = new Grid { ColumnSpacing = Theme.SpaceS };
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var schedule = job?["schedule"] ?? job;
        var glyph = Chrome.CadenceGlyph(
            Format.Text(schedule, "kind", "once"),
            Format.Long(schedule, "weekdays"),
            (int)Format.Long(schedule, "weekday"),
            enabled,
            summary: cadence);
        glyph.VerticalAlignment = VerticalAlignment.Top;
        line.Children.Add(glyph);
        var texts = new StackPanel { Spacing = Theme.SpaceXs };
        texts.Children.Add(new TextBlock
        {
            Text = name,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
        });
        var status = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceXs };
        status.Children.Add(new TextBlock
        {
            Text = (enabled ? "on" : "off") + " · " + cadence,
            Opacity = 0.7,
            TextWrapping = TextWrapping.Wrap,
            VerticalAlignment = VerticalAlignment.Center,
        });
        if (enabled
            && job?["nextRunAtMs"] is JsonValue next
            && next.TryGetValue<long>(out var nextMs)
            && nextMs > 0)
        {
            long? lastMs = job?["lastRunAtMs"] is JsonValue last
                && last.TryGetValue<long>(out var lastValue)
                ? lastValue
                : null;
            var ring = Chrome.CountdownRing(lastMs, nextMs, label: "Next run");
            ring.VerticalAlignment = VerticalAlignment.Center;
            status.Children.Add(ring);
        }
        texts.Children.Add(status);
        Grid.SetColumn(texts, 1);
        line.Children.Add(texts);
        body.Children.Add(line);
        var runningHere = JobRuns(id).Any(r => WorkbenchOps.IsRunning(r));
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        actions.Children.Add(ActionIconGlyph.Button(
            enabled ? "Disable" : "Enable",
            enabled ? ActionIcon.Dismiss : ActionIcon.Approve,
            async (_, _) => await SetEnabledAsync(id, !enabled)));
        var runButton = ActionIconGlyph.Button("Run", ActionIcon.Run, async (_, _) =>
        {
            await RunAsync(id);
        });
        runButton.IsEnabled = _pendingRunOp is null && !_working;
        actions.Children.Add(runButton);
        if (runningHere)
        {
            foreach (var run in JobRuns(id))
            {
                if (!WorkbenchOps.IsRunning(run))
                {
                    continue;
                }
                var runId = Format.Text(run, "id");
                if (string.IsNullOrEmpty(runId))
                {
                    continue;
                }
                var liveId = runId;
                actions.Children.Add(ActionIconGlyph.Button(
                    "Stop", ActionIcon.Stop, async (_, _) => await KillAsync(liveId)));
                break;
            }
        }
        body.Children.Add(actions);
        var frame = new Border
        {
            Background = _selectedId == id ? Theme.AccentSoftBrush : new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(Theme.SpaceS),
            CornerRadius = new CornerRadius(Theme.CardRadius),
            Child = body,
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
            _creating = false;
            _selectedId = id;
            _draft = null;
            _detailDirty = false;
            _detailRevision = WorkbenchOps.Revision(job);
            _conflictId = null;
            _confirmDelete = false;
            _runError = null;
            _historyShown = WorkbenchOps.RunPreviewCount;
            RenderDetail();
        };
        return button;
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
            BudgetUnit = _dBudgetUnit?.SelectedItem as string ?? "minutes",
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
        if (!_detailDirty)
        {
            if (_creating)
            {
                _draft ??= DefaultDraft();
            }
            else if (SelectedJob() is JsonNode fresh)
            {
                _detailRevision = WorkbenchOps.Revision(fresh);
                _draft ??= DraftFromJob(fresh);
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
            Text = "Writing",
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        var name = new TextBox { Text = draft.Name, PlaceholderText = "Name" };
        name.TextChanged += (_, _) => _detailDirty = true;
        body.Children.Add(Labeled("Name", name));
        _dName = name;

        var prompt = new TextBox
        {
            Text = draft.Prompt,
            PlaceholderText = "What should the agent do?",
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            MinHeight = 120,
        };
        prompt.TextChanged += (_, _) => _detailDirty = true;
        body.Children.Add(Labeled("Prompt", prompt));
        _dPrompt = prompt;

        var folderBox = new ComboBox { MinWidth = 200 };
        var folderNames = new List<string> { "Choose a folder" };
        folderNames.AddRange(_folders.Select(f => f.Name));
        folderBox.ItemsSource = folderNames;
        var folderIndex = _folders.FindIndex(f => f.Id == draft.FolderId);
        folderBox.SelectedIndex = folderIndex >= 0 ? folderIndex + 1 : 0;
        folderBox.SelectionChanged += (_, _) => _detailDirty = true;
        body.Children.Add(Labeled("Folder", folderBox));
        _dFolder = folderBox;

        var backendBox = new ComboBox { MinWidth = 200 };
        var backendNames = new List<string> { "Choose an agent" };
        backendNames.AddRange(_backends.Select(b => b.Label));
        backendBox.ItemsSource = backendNames;
        var backendIndex = _backends.FindIndex(b => b.Id == draft.BackendId);
        backendBox.SelectedIndex = backendIndex >= 0 ? backendIndex + 1 : 0;
        backendBox.SelectionChanged += (_, _) => _detailDirty = true;
        body.Children.Add(Labeled("Agent", backendBox));
        _dBackend = backendBox;

        var model = new TextBox { Text = draft.Model, PlaceholderText = "Default model" };
        model.TextChanged += (_, _) => _detailDirty = true;
        body.Children.Add(Labeled("Model", model));
        _dModel = model;

        var effort = new TextBox { Text = draft.Effort, PlaceholderText = "Default effort" };
        effort.TextChanged += (_, _) => _detailDirty = true;
        body.Children.Add(Labeled("Effort", effort));
        _dEffort = effort;

        var budget = new TextBox { Text = draft.BudgetText, MinWidth = 100 };
        budget.TextChanged += (_, _) => _detailDirty = true;
        var budgetUnit = new ComboBox { MinWidth = 110 };
        budgetUnit.ItemsSource = new[] { "minutes", "seconds" };
        budgetUnit.SelectedItem = draft.BudgetUnit;
        budgetUnit.SelectionChanged += (_, _) => _detailDirty = true;
        var noLimit = new CheckBox { Content = "No limit", IsChecked = draft.NoLimit };
        noLimit.Click += (_, _) => _detailDirty = true;
        var budgetRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        budgetRow.Children.Add(budget);
        budgetRow.Children.Add(budgetUnit);
        budgetRow.Children.Add(noLimit);
        body.Children.Add(Labeled("Time limit", budgetRow));
        _dBudget = budget;
        _dBudgetUnit = budgetUnit;
        _dNoLimit = noLimit;

        body.Children.Add(new TextBlock
        {
            Text = "Settings",
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        var enabled = new CheckBox { Content = "Enabled", IsChecked = draft.Enabled };
        enabled.Click += (_, _) => _detailDirty = true;
        body.Children.Add(enabled);
        _dEnabled = enabled;

        var kind = new ComboBox { MinWidth = 150 };
        kind.ItemsSource = new[] { "Once", "Interval", "Daily", "Weekdays", "Weekly", "Custom" };
        kind.SelectedIndex = Math.Max(0, Array.IndexOf(WorkbenchOps.ScheduleKinds, draft.Kind));
        kind.SelectionChanged += (_, _) => _detailDirty = true;
        body.Children.Add(Labeled("Schedule", kind));
        _dKind = kind;

        var interval = new TextBox { Text = draft.IntervalMinutes, MinWidth = 100 };
        interval.TextChanged += (_, _) => _detailDirty = true;
        var intervalRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        intervalRow.Children.Add(interval);
        intervalRow.Children.Add(new TextBlock
        {
            Text = "minutes",
            VerticalAlignment = VerticalAlignment.Center,
            Opacity = 0.68,
        });
        body.Children.Add(Labeled("Every", intervalRow));
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
        body.Children.Add(Labeled("Time", timeRow));
        _dHour = hour;
        _dMinute = minute;

        var weekday = new ComboBox { MinWidth = 140 };
        weekday.ItemsSource = WorkbenchOps.DayNames.ToArray();
        weekday.SelectedIndex = Math.Clamp(draft.Weekday, 0, 6);
        weekday.SelectionChanged += (_, _) => _detailDirty = true;
        body.Children.Add(Labeled("Day", weekday));
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
        body.Children.Add(Labeled("Days", daysRow));

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
                "This job changed since you opened it. Compare the saved job before replacing it.",
                Theme.Warning,
                Symbol.Important));
            var conflictRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
            conflictRow.Children.Add(ActionIconGlyph.PrimaryButton(
                "Save anyway", ActionIcon.Save, async (_, _) =>
                {
                    SnapshotDraft();
                    await SaveDraftAsync(force: true);
                }));
            conflictRow.Children.Add(ActionIconGlyph.Button(
                "Take saved", ActionIcon.Restore, async (_, _) =>
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
                Text = "The job may already exist. Check this request before adding another.",
                TextWrapping = TextWrapping.Wrap,
            });
            var checkRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
            checkRow.Children.Add(ActionIconGlyph.Button(
                "Check again", ActionIcon.Refresh, async (_, _) => await CheckCreationAsync()));
            body.Children.Add(checkRow);
        }

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        if (_creating)
        {
            var createButton = ActionIconGlyph.PrimaryButton(
                "Create", ActionIcon.Create, async (_, _) =>
                {
                    SnapshotDraft();
                    await CreateDraftAsync();
                });
            createButton.IsEnabled = _pendingCreateOp is null && !_working;
            actions.Children.Add(createButton);
            actions.Children.Add(ActionIconGlyph.Button(
                "Back", ActionIcon.Back, (_, _) =>
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
                "Save", ActionIcon.Save, async (_, _) =>
                {
                    SnapshotDraft();
                    await SaveDraftAsync(force: false);
                }));
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
        }
        body.Children.Add(actions);

        if (_confirmDelete && !_creating)
        {
            var confirm = new StackPanel { Spacing = Theme.SpaceS };
            confirm.Children.Add(new TextBlock
            {
                Text = $"Delete \"{draft.Name}\"? This removes the job from this host.",
                TextWrapping = TextWrapping.Wrap,
            });
            var confirmRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
            confirmRow.Children.Add(ActionIconGlyph.Button(
                "Delete job", ActionIcon.Delete, async (_, _) => await DeleteAsync()));
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
                    "Check again", ActionIcon.Refresh, async (_, _) => await CheckRunAsync()));
                retryRow.Children.Add(ActionIconGlyph.Button(
                    "Retry", ActionIcon.Run, async (_, _) => await RetryRunAsync()));
                body.Children.Add(retryRow);
            }
        }

        var title = _creating ? "New automation" : draft.Name;
        var subtitle = _creating
            ? null
            : $"Revision {_detailRevision?.ToString() ?? "unknown"} · {FolderLabel(draft.FolderId)}";
        return Chrome.Card(string.IsNullOrEmpty(title) ? "Automation" : title, body, subtitle);
    }

    private string? ValidateDraft(JobDraft draft, out ulong budgetSeconds, out ulong everySeconds)
    {
        budgetSeconds = 0;
        everySeconds = 0;
        if (string.IsNullOrWhiteSpace(draft.Name))
        {
            return "Give this job a name.";
        }
        if (draft.Name.Length > 4096)
        {
            return "Shorten the name to 4 KiB or less.";
        }
        if (string.IsNullOrWhiteSpace(draft.Prompt))
        {
            return "Write what the agent should do.";
        }
        if (draft.Prompt.Length > 1024 * 1024)
        {
            return "Shorten the prompt to 1 MiB or less.";
        }
        if (string.IsNullOrWhiteSpace(draft.FolderId))
        {
            return "Choose a folder for this job.";
        }
        if (string.IsNullOrWhiteSpace(draft.BackendId))
        {
            return "Choose an agent for this job.";
        }
        var budget = WorkbenchOps.BudgetSeconds(draft.BudgetText, draft.BudgetUnit, draft.NoLimit);
        if (budget is null)
        {
            return "Enter a positive time limit, or choose No limit.";
        }
        budgetSeconds = budget.Value;
        if (draft.Kind == "interval")
        {
            if (!ulong.TryParse(draft.IntervalMinutes.Trim(), out var minutes) || minutes == 0)
            {
                return "Pick an interval of at least one minute.";
            }
            try
            {
                everySeconds = checked(minutes * 60);
            }
            catch (OverflowException)
            {
                return "Pick a shorter interval.";
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
                    await AppServices.Host.CallAsync("automation.createOnce", new JsonObject
                    {
                        ["job"] = payload,
                        ["operationId"] = _pendingCreateOp,
                    });
                    _pendingCreateOp = null;
                    Notice("Automation added.");
                    ResetEditor();
                }
                catch (Exception ex)
                {
                    Banner("The job may already exist. Check this request before adding another. " + ex.Message);
                    return;
                }
            }
            else
            {
                await AppServices.Host.CallAsync("automation.create", new JsonObject { ["job"] = payload });
                Notice("Automation added.");
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
            var receipt = await AppServices.Host.CallAsync(
                "automation.creationReceipt", new JsonObject { ["operationId"] = _pendingCreateOp });
            if (receipt is JsonObject obj && obj.Count > 0 && receipt["job"] is not null)
            {
                _pendingCreateOp = null;
                Notice("Automation added.");
                ResetEditor();
                await LoadAsync();
            }
            else
            {
                Banner("The computer has not accepted this job yet. Check again when the connection is ready.");
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
                    Banner("Reload this job before saving it.");
                    return;
                }
                payload["revision"] = revision.Value;
                try
                {
                    await AppServices.Host.CallAsync("automation.edit", new JsonObject
                    {
                        ["job"] = payload,
                        ["expectedRevision"] = revision.Value,
                    });
                }
                catch (Exception ex) when (WorkbenchOps.IsConflict(ex))
                {
                    _conflictId = id;
                    Banner("This job changed since you opened it. Compare the saved job before replacing it.");
                    await LoadAsync();
                    if (SelectedJob() is JsonNode conflicted)
                    {
                        _detailRevision = WorkbenchOps.Revision(conflicted);
                    }
                    RenderDetail();
                    return;
                }
            }
            else
            {
                await AppServices.Host.CallAsync("automation.update", new JsonObject { ["job"] = payload });
            }
            _detailDirty = false;
            _conflictId = null;
            _draft = null;
            Notice($"Saved \"{draft.Name.Trim()}\".");
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
            await AppServices.Host.CallAsync(
                "automation.remove", new JsonObject { ["id"] = _selectedId });
            Notice("Automation deleted.");
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
            await AppServices.Host.CallAsync(
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
                    await AppServices.Host.CallAsync("automation.runOnce", new JsonObject
                    {
                        ["id"] = id,
                        ["operationId"] = _pendingRunOp,
                    });
                    _pendingRunOp = null;
                    _pendingRunJob = null;
                    Notice("The run started.");
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
                await AppServices.Host.CallAsync("automation.run", new JsonObject { ["id"] = id });
                Notice("The run started.");
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
            var receipt = await AppServices.Host.CallAsync(
                "automation.runReceipt", new JsonObject { ["operationId"] = _pendingRunOp });
            if (receipt?["run"] is not null)
            {
                _pendingRunOp = null;
                _pendingRunJob = null;
                _runError = null;
                Notice("The run is confirmed.");
                await LoadAsync();
            }
            else
            {
                _runError = "The computer has not accepted this run request. Retry the same request when the connection is ready.";
                RenderDetail();
            }
        }
        catch (Exception ex)
        {
            _runError = "The run result is still unavailable. Your request is kept on this device. " + ex.Message;
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
            await AppServices.Host.CallAsync("automation.runOnce", new JsonObject
            {
                ["id"] = _pendingRunJob,
                ["operationId"] = _pendingRunOp,
            });
            _pendingRunOp = null;
            _pendingRunJob = null;
            _runError = null;
            Notice("The run is confirmed.");
            await LoadAsync();
        }
        catch (Exception ex)
        {
            _runError = "The run result is not confirmed. Check this request before starting another run. " + ex.Message;
            RenderDetail();
        }
    }

    private async Task KillAsync(string runId)
    {
        SnapshotDraft();
        try
        {
            await AppServices.Host.CallAsync("automation.kill", new JsonObject { ["id"] = runId });
            Notice("Stopped.");
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
                Text = "No runs yet. Run this job to see its history here.",
                Opacity = 0.66,
                TextWrapping = TextWrapping.Wrap,
            });
        }
        else if (runs.Count > shown.Count)
        {
            var remaining = runs.Count - shown.Count;
            body.Children.Add(ActionIconGlyph.Button(
                $"Earlier runs ({remaining})", ActionIcon.History, (_, _) =>
                {
                    _historyShown += WorkbenchOps.RunPageSize;
                    RenderDetail();
                }));
        }
        return Chrome.Card("Run history", body, $"{runs.Count} runs");
    }

    private UIElement RunRow(JsonNode run)
    {
        var runId = Format.Text(run, "id");
        var status = Format.Text(run, "status");
        var live = WorkbenchOps.IsRunning(run);
        var body = new StackPanel { Spacing = Theme.SpaceXs };
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
                    "More", ActionIcon.More, async (_, _) => await LoadTranscriptAsync(runId, offset)));
            }
        }
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        row.Children.Add(ActionIconGlyph.Button(
            "Transcript", ActionIcon.History, async (_, _) => await LoadTranscriptAsync(runId, 0)));
        if (live && !string.IsNullOrEmpty(runId))
        {
            var liveId = runId;
            row.Children.Add(ActionIconGlyph.Button(
                "Stop", ActionIcon.Stop, async (_, _) => await KillAsync(liveId)));
        }
        body.Children.Add(row);
        return body;
    }

    private async Task LoadTranscriptAsync(string runId, ulong offset)
    {
        SnapshotDraft();
        try
        {
            var answer = await AppServices.Host.CallAsync(
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
