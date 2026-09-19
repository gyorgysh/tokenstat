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
/// Workflow graphs stored on this host. Matches the Mac workbench: new from a
/// recipe, a blank graph, or a draft from a prompt, a step list with explicit
/// Then, Else, and Body connections, run, stop, and continue, revision-checked
/// saves on protocol 22 and later, complete run history, and unknown-field
/// preservation on every round trip.
/// </summary>
internal sealed class WorkflowsPage : Page, IInspectorContent
{
    private readonly string? _scopeWorkspaceId;
    private readonly ContentControl _barSlot = new()
    {
        HorizontalAlignment = HorizontalAlignment.Stretch,
        HorizontalContentAlignment = HorizontalAlignment.Stretch,
    };
    private readonly StackPanel _root = new() { Spacing = Theme.SpaceL };
    private readonly StackPanel _bannerHost = new() { Spacing = Theme.SpaceS };
    private readonly StackPanel _listHost = new() { Spacing = Theme.SpaceL };
    private readonly StackPanel _detailHost = new()
    {
        Spacing = Theme.SpaceL,
        Padding = new Thickness(Theme.SpaceM),
    };
    private readonly TextBox _searchBox;

    private JsonArray _graphs = new();
    private JsonArray _runs = new();
    private List<(string Id, string Name)> _folders = new();
    private List<(string Id, string Label)> _backends = new();
    private long? _protocol;
    private ulong _defaultBudget = 10_800;
    private string _queueTimezone = "";
    private string _query = "";
    private bool _working;
    private string? _selectedId;
    private bool _creating;
    private JsonObject? _graph;
    private ulong? _detailRevision;
    private bool _detailDirty;
    private string? _conflictId;
    private bool _confirmDelete;
    private string? _stepId;
    private string _runInput = "";
    private Dictionary<string, (string Text, ulong Next)> _transcripts = new();

    private const int MaxSteps = 64;
    private const int MaxConnections = 128;

    private static readonly string[] AuthorableKinds =
        ["input", "agent", "automation", "http", "command", "gate", "condition", "loop"];

    private static readonly string[] KindLabels =
        ["Input", "Agent", "Automation", "HTTP", "Command", "Gate", "If", "Loop"];

    public WorkflowsPage(string? workspaceId = null)
    {
        _scopeWorkspaceId = workspaceId;
        _searchBox = Chrome.SearchField("Search workflows", text =>
        {
            _query = text ?? "";
            RenderList();
        });
        _searchBox.MaxWidth = 340;
        _searchBox.HorizontalAlignment = HorizontalAlignment.Left;
        _root.Children.Add(_bannerHost);
        _root.Children.Add(_searchBox);
        _root.Children.Add(_listHost);
        // A wireframe until the first load lands. RenderList clears the host,
        // so real content replaces it, like Home's skeleton.
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
    /// The inspector column content: the selected graph's detail, steps, run,
    /// and history views. Selection and reloads replace its children, so the
    /// column stays live without the shell asking again.
    /// </summary>
    public UIElement? Inspector => _detailHost;

    private void RebuildChrome()
    {
        UIElement? scope = null;
        if (_scopeWorkspaceId is not null)
        {
            scope = Chrome.ScopeChip(FolderLabel(_scopeWorkspaceId));
        }
        _barSlot.Content = DetailBar.View(
            scope: scope,
            trailing: new List<UIElement>
            {
                Buttons.ToolbarIcon(
                    ActionIcon.Refresh,
                    "Reload workflows",
                    async (_, _) => await LoadAsync()),
                Buttons.ToolbarIcon(
                    ActionIcon.Create,
                    "Start a blank draft",
                    (_, _) => StartCreating()),
            });
    }

    private void StartCreating()
    {
        _creating = true;
        _selectedId = null;
        _graph = BlankGraph("Untitled");
        _detailRevision = null;
        _detailDirty = false;
        _conflictId = null;
        _confirmDelete = false;
        _stepId = null;
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

    private async Task LoadAsync()
    {
        _working = true;
        try
        {
            _protocol = await WorkbenchOps.ProtocolAsync();
            var listTask = AppServices.Host.CallAsync("workflow.list", new JsonObject());
            var runsTask = AppServices.Host.CallAsync("workflow.runs", new JsonObject());
            var foldersTask = AppServices.Host.CallAsync("workspace.list", new JsonObject());
            var backendsTask = AppServices.Host.CallAsync("automation.backends", new JsonObject());
            var queueTask = AppServices.Host.CallAsync("automation.queue", new JsonObject());
            await Task.WhenAll(listTask, runsTask, foldersTask, backendsTask, queueTask);
            _graphs = Format.Items(listTask.Result, "graphs") ?? new JsonArray();
            _runs = Format.Items(runsTask.Result) ?? new JsonArray();
            RunNotifications.Shared.SettleWorkflows(_runs);
            _folders = ReadFolders(foldersTask.Result);
            _backends = ReadBackends(backendsTask.Result);
            var queue = queueTask.Result;
            try
            {
                var budget = queue["defaultBudgetSeconds"]?.GetValue<ulong>() ?? 0;
                if (budget > 0)
                {
                    _defaultBudget = budget;
                }
            }
            catch { /* keep */ }
            _queueTimezone = Format.Text(queue, "timezone");
            if (!_detailDirty)
            {
                RefreshGraphFromHost();
            }
            RebuildChrome();
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

    private void RefreshGraphFromHost()
    {
        if (_creating || _selectedId is null)
        {
            return;
        }
        foreach (var graph in _graphs)
        {
            if (Format.Text(graph, "id") == _selectedId && graph is JsonObject raw)
            {
                _graph = (JsonObject)raw.DeepClone();
                _detailRevision = WorkbenchOps.Revision(graph);
                return;
            }
        }
        _graph = null;
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

    private List<JsonNode?> GraphRuns(string graphId)
    {
        var array = new JsonArray();
        foreach (var run in _runs)
        {
            if (Format.Text(run, "workflowId") == graphId)
            {
                array.Add(run?.DeepClone());
            }
        }
        return WorkbenchOps.OrderedRuns(array);
    }

    private static bool RunLive(JsonNode? run) =>
        WorkbenchOps.IsRunning(run) || Format.Text(run, "status") == "waiting";

    private bool MatchesQuery(JsonNode? graph)
    {
        var term = _query.Trim();
        if (string.IsNullOrEmpty(term))
        {
            return true;
        }
        if (Format.Text(graph, "name").Contains(term, StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }
        if (graph?["nodes"] is JsonArray nodes)
        {
            foreach (var node in nodes)
            {
                if (Format.Text(node, "title").Contains(term, StringComparison.OrdinalIgnoreCase)
                    || Format.Text(node, "displayTitle").Contains(term, StringComparison.OrdinalIgnoreCase)
                    || KindLabel(NodeKind(node)).Contains(term, StringComparison.OrdinalIgnoreCase))
                {
                    return true;
                }
            }
        }
        return false;
    }

    private void RenderList()
    {
        _listHost.Children.Clear();
        var visible = new List<JsonNode?>();
        foreach (var graph in _graphs)
        {
            if (!Format.InWorkspace(graph, _scopeWorkspaceId, includeUnscoped: true))
            {
                continue;
            }
            if (string.IsNullOrEmpty(Format.Text(graph, "id")))
            {
                continue;
            }
            if (MatchesQuery(graph))
            {
                visible.Add(graph);
            }
        }
        if (visible.Count == 0)
        {
            if (!string.IsNullOrEmpty(_query.Trim()))
            {
                _listHost.Children.Add(Chrome.Empty(
                    "No matching workflows",
                    $"No workflow matches \"{_query.Trim()}\".",
                    ActionIcon.Search,
                    ActionIconGlyph.Button("Clear search", ActionIcon.Dismiss, (_, _) =>
                    {
                        _searchBox.Text = "";
                    })));
            }
            else
            {
                _listHost.Children.Add(EmptyState.View(
                    "No workflows yet",
                    "Start from a blank graph, a recipe, or a draft from a prompt.",
                    EmptyArtKind.Workflows,
                    ActionIconGlyph.Button("New workflow", ActionIcon.Create, (_, _) => StartCreating())));
            }
            return;
        }
        var global = new List<JsonNode?>();
        var byFolder = new Dictionary<string, List<JsonNode?>>();
        foreach (var graph in visible)
        {
            var workspaceId = Format.Text(graph, "workspaceId");
            var folderKnown = _folders.Any(f => f.Id == workspaceId)
                || (_scopeWorkspaceId is not null && workspaceId == _scopeWorkspaceId);
            if (Format.Text(graph, "scope") == "workspace" && folderKnown)
            {
                if (!byFolder.TryGetValue(workspaceId, out var bucket))
                {
                    bucket = new List<JsonNode?>();
                    byFolder[workspaceId] = bucket;
                }
                bucket.Add(graph);
            }
            else
            {
                global.Add(graph);
            }
        }
        RenderSection("Global", global);
        if (_scopeWorkspaceId is not null)
        {
            if (byFolder.TryGetValue(_scopeWorkspaceId, out var scoped))
            {
                RenderSection(FolderLabel(_scopeWorkspaceId), scoped);
            }
            return;
        }
        foreach (var folder in _folders)
        {
            if (byFolder.TryGetValue(folder.Id, out var graphs))
            {
                RenderSection(folder.Name, graphs);
            }
        }
    }

    private void RenderSection(string title, List<JsonNode?> graphs)
    {
        if (graphs.Count == 0)
        {
            return;
        }
        var section = new StackPanel { Spacing = Theme.SpaceS };
        section.Children.Add(Chrome.SectionLabel(title, graphs.Count));
        var list = new StackPanel { Spacing = Theme.SpaceS };
        foreach (var graph in graphs)
        {
            if (graph is null)
            {
                continue;
            }
            list.Children.Add(GraphRow(graph, Format.Text(graph, "id")));
        }
        section.Children.Add(list);
        _listHost.Children.Add(section);
    }

    private UIElement GraphRow(JsonNode graph, string id)
    {
        var name = Format.Text(graph, "name", "Workflow");
        var runs = GraphRuns(id);
        var live = runs.FirstOrDefault(RunLive);
        var status = live is not null ? WorkbenchOps.RunLabel(Format.Text(live, "status")) : "idle";
        var body = new StackPanel { Spacing = Theme.SpaceS };
        body.Children.Add(new TextBlock
        {
            Text = name,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
        });
        body.Children.Add(new TextBlock { Text = status, Opacity = 0.7 });
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        actions.Children.Add(ActionIconGlyph.Button(
            "Run", ActionIcon.Run, async (_, _) => await RunAsync(id)));
        if (live is not null)
        {
            var runId = Format.Text(live, "id");
            if (!string.IsNullOrEmpty(runId))
            {
                var liveId = runId;
                actions.Children.Add(ActionIconGlyph.Button(
                    "Stop", ActionIcon.Stop, async (_, _) => await KillAsync(liveId)));
            }
        }
        body.Children.Add(actions);
        var button = new Button
        {
            Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(0),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Content = body,
        };
        button.Click += (_, _) =>
        {
            _creating = false;
            _selectedId = id;
            _detailDirty = false;
            _conflictId = null;
            _confirmDelete = false;
            _stepId = null;
            RefreshGraphFromHost();
            RenderDetail();
        };
        return button;
    }

    private static JsonObject StepNode(string id, string kind, string title, double x, double y)
    {
        return new JsonObject
        {
            ["id"] = id,
            ["kind"] = kind,
            ["x"] = x,
            ["y"] = y,
            ["title"] = title,
        };
    }

    private static JsonObject Edge(string from, string to, string when)
    {
        return new JsonObject
        {
            ["from"] = from,
            ["to"] = to,
            ["when"] = when,
        };
    }

    private static JsonObject BlankGraph(string name)
    {
        return new JsonObject
        {
            ["id"] = "",
            ["name"] = name,
            ["scope"] = "global",
            ["budgetSeconds"] = 10_800,
            ["enabled"] = false,
            ["schedule"] = WorkbenchOps.SchedulePayload("once", 0, 9, 0, 0, 0),
            ["nodes"] = new JsonArray { StepNode("in", "input", "Start", 80, 120) },
            ["edges"] = new JsonArray(),
        };
    }

    private static JsonObject RecipeGraph(string name, string backend, string recipe)
    {
        var second = recipe == "review" ? "build" : "plan";
        var secondTitle = recipe == "review" ? "Build" : "Plan";
        var third = "build";
        var thirdTitle = "Build";
        if (recipe == "review")
        {
            third = "review";
            thirdTitle = "Review";
        }
        return new JsonObject
        {
            ["id"] = "",
            ["name"] = name,
            ["scope"] = "global",
            ["budgetSeconds"] = 10_800,
            ["enabled"] = false,
            ["schedule"] = WorkbenchOps.SchedulePayload("once", 0, 9, 0, 0, 0),
            ["nodes"] = new JsonArray
            {
                StepNode("in", "input", "Start", 80, 80),
                AgentNode(second, secondTitle, backend, 80, 240),
                AgentNode(third, thirdTitle, backend, 80, 400),
            },
            ["edges"] = new JsonArray
            {
                Edge("in", second, "ok"),
                Edge(second, third, "ok"),
            },
        };
    }

    private static JsonObject AgentNode(string id, string title, string backend, double x, double y)
    {
        var node = StepNode(id, "agent", title, x, y);
        node["backend"] = backend;
        node["prompt"] = "{{input}}";
        return node;
    }

    private static string NodeKind(JsonNode? node) => Format.Text(node, "kind", "input");

    private static string KindLabel(string kind)
    {
        var index = Array.IndexOf(AuthorableKinds, kind);
        return index >= 0 ? KindLabels[index] : kind;
    }

    /// <summary>
    /// What one outgoing edge means on a step of this kind. A condition's ok
    /// edge is Then and error is Else. A loop's ok edge is the Body and always
    /// is after the last pass.
    /// </summary>
    private static string ConnectionLabel(string kind, string when) => (kind, when) switch
    {
        ("condition", "ok") => "Then",
        ("condition", "error") => "Else",
        ("loop", "ok") => "Body",
        ("loop", "always") => "After last pass",
        (_, "ok") => "Then",
        (_, "error") => "On error",
        (_, "always") => "Always",
        _ => when,
    };

    private static string ConnectionCaption(string kind) => kind switch
    {
        "condition" => "Then is success. Else is error. The test reads the previous step.",
        "loop" => "Body is the repeated work. After last pass is where the run goes when the loop is done. At most 20 passes.",
        "gate" => "The run pauses here. Continue or Stop from the run.",
        "input" => "The starting prompt fills {{input}} when you press Run.",
        _ => "Then is on success. On error is the failure path. Always runs either way.",
    };

    private JsonArray GraphNodes()
    {
        if (_graph?["nodes"] is JsonArray nodes)
        {
            return nodes;
        }
        var fresh = new JsonArray();
        if (_graph is JsonObject graph)
        {
            graph["nodes"] = fresh;
        }
        return fresh;
    }

    private JsonArray GraphEdges()
    {
        if (_graph?["edges"] is JsonArray edges)
        {
            return edges;
        }
        var fresh = new JsonArray();
        if (_graph is JsonObject graph)
        {
            graph["edges"] = fresh;
        }
        return fresh;
    }

    private JsonNode? FindStep(string stepId)
    {
        foreach (var node in GraphNodes())
        {
            if (Format.Text(node, "id") == stepId)
            {
                return node;
            }
        }
        return null;
    }

    private void RenderDetail()
    {
        if (!_creating && _selectedId is null)
        {
            _graph = null;
        }
        _detailHost.Children.Clear();
        if (_creating && _graph is null)
        {
            _graph = BlankGraph("Untitled");
        }
        if (_graph is null)
        {
            _detailHost.Children.Add(new TextBlock
            {
                Text = "Select a workflow",
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            });
            _detailHost.Children.Add(new TextBlock
            {
                Text = "Pick a graph to edit its steps, run it, or read its history.",
                Opacity = 0.66,
                TextWrapping = TextWrapping.Wrap,
            });
            return;
        }
        _detailHost.Children.Add(FormCard());
        _detailHost.Children.Add(StepsCard());
        if (_stepId is not null && FindStep(_stepId) is JsonNode step)
        {
            _detailHost.Children.Add(StepCard(step));
        }
        if (!_creating && _selectedId is not null)
        {
            _detailHost.Children.Add(RunCard());
            _detailHost.Children.Add(HistoryCard(_selectedId));
        }
    }

    private UIElement FormCard()
    {
        var graph = _graph;
        if (graph is null)
        {
            return new StackPanel();
        }
        var body = new StackPanel { Spacing = Theme.SpaceM };

        if (_creating)
        {
            body.Children.Add(new TextBlock
            {
                Text = "Start",
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            });
            var recipe = new ComboBox { MinWidth = 220 };
            recipe.ItemsSource = new[]
            {
                "Blank graph",
                "Plan then build",
                "Build with review",
                "Draft from prompt",
            };
            recipe.SelectedIndex = 0;
            body.Children.Add(Labeled("Recipe", recipe));
            var designPrompt = new TextBox
            {
                PlaceholderText = "Describe the workflow to draft",
                AcceptsReturn = true,
                TextWrapping = TextWrapping.Wrap,
                MinHeight = 72,
            };
            body.Children.Add(Labeled("Prompt", designPrompt));
            var designBackend = new ComboBox { MinWidth = 200 };
            var backendNames = new List<string> { "Default agent" };
            backendNames.AddRange(_backends.Select(b => b.Label));
            designBackend.ItemsSource = backendNames;
            designBackend.SelectedIndex = 0;
            body.Children.Add(Labeled("Agent", designBackend));
            var applyRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
            applyRow.Children.Add(ActionIconGlyph.Button(
                "Apply", ActionIcon.Apply, async (_, _) =>
                {
                    await ApplyRecipeAsync(recipe.SelectedIndex, designPrompt.Text, DesignBackendId(designBackend));
                }));
            body.Children.Add(applyRow);
        }

        var name = new TextBox
        {
            Text = Format.Text(graph, "name"),
            PlaceholderText = "Name",
        };
        name.TextChanged += (_, _) =>
        {
            if (_graph is not null)
            {
                _graph["name"] = name.Text;
            }
            _detailDirty = true;
        };
        body.Children.Add(Labeled("Name", name));

        var scope = new ComboBox { MinWidth = 160 };
        scope.ItemsSource = new[] { "Global", "This workspace" };
        scope.SelectedIndex = Format.Text(graph, "scope") == "workspace" ? 1 : 0;
        scope.SelectionChanged += (_, _) =>
        {
            if (_graph is not null)
            {
                _graph["scope"] = scope.SelectedIndex == 1 ? "workspace" : "global";
            }
            _detailDirty = true;
        };
        body.Children.Add(Labeled("Scope", scope));

        var folderBox = new ComboBox { MinWidth = 200 };
        var folderNames = new List<string> { "No folder" };
        folderNames.AddRange(_folders.Select(f => f.Name));
        folderBox.ItemsSource = folderNames;
        var workspaceId = Format.Text(graph, "workspaceId");
        var folderIndex = _folders.FindIndex(f => f.Id == workspaceId);
        folderBox.SelectedIndex = folderIndex >= 0 ? folderIndex + 1 : 0;
        folderBox.SelectionChanged += (_, _) =>
        {
            if (_graph is not null)
            {
                var pick = folderBox.SelectedIndex;
                _graph["workspaceId"] = pick >= 1 && pick - 1 < _folders.Count
                    ? _folders[pick - 1].Id
                    : "";
            }
            _detailDirty = true;
        };
        body.Children.Add(Labeled("Folder", folderBox));

        var budgetSeconds = Format.Long(graph, "budgetSeconds");
        var (budgetText, budgetUnit, noLimit) = budgetSeconds > 0
            ? WorkbenchOps.SplitBudget((ulong)budgetSeconds)
            : ("180", "minutes", true);
        var budget = new TextBox { Text = budgetText, MinWidth = 100 };
        var unit = new ComboBox { MinWidth = 110 };
        unit.ItemsSource = new[] { "minutes", "seconds" };
        unit.SelectedItem = budgetUnit;
        var noLimitBox = new CheckBox { Content = "No limit", IsChecked = noLimit };
        void WriteBudget()
        {
            if (_graph is null)
            {
                return;
            }
            if (noLimitBox.IsChecked == true)
            {
                _graph["budgetSeconds"] = 0;
                return;
            }
            var parsed = WorkbenchOps.BudgetSeconds(budget.Text, unit.SelectedItem as string ?? "minutes", false);
            if (parsed is not null)
            {
                _graph["budgetSeconds"] = parsed.Value;
            }
        }
        budget.TextChanged += (_, _) => { WriteBudget(); _detailDirty = true; };
        unit.SelectionChanged += (_, _) => { WriteBudget(); _detailDirty = true; };
        noLimitBox.Click += (_, _) => { WriteBudget(); _detailDirty = true; };
        var budgetRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        budgetRow.Children.Add(budget);
        budgetRow.Children.Add(unit);
        budgetRow.Children.Add(noLimitBox);
        body.Children.Add(Labeled("Time limit", budgetRow));

        var enabled = new CheckBox { Content = "Enabled", IsChecked = Format.Flag(graph, "enabled") };
        enabled.Click += (_, _) =>
        {
            if (_graph is not null)
            {
                _graph["enabled"] = enabled.IsChecked == true;
            }
            _detailDirty = true;
        };
        body.Children.Add(enabled);

        body.Children.Add(ScheduleEditor(graph));

        // The host scheduler owns the zone. Never print a wall-clock time
        // without saying whose clock it is.
        body.Children.Add(new TextBlock
        {
            Text = WorkbenchOps.ClockCaption("", _queueTimezone),
            FontSize = 12,
            Opacity = 0.68,
            TextWrapping = TextWrapping.Wrap,
        });

        if (_conflictId == _selectedId && !_creating)
        {
            body.Children.Add(Chrome.Banner(
                "This workflow changed since you opened it. Compare the saved graph before replacing it.",
                Theme.Warning,
                Symbol.Important));
            var conflictRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
            conflictRow.Children.Add(ActionIconGlyph.PrimaryButton(
                "Save anyway", ActionIcon.Save, async (_, _) => await SaveAsync(force: true)));
            conflictRow.Children.Add(ActionIconGlyph.Button(
                "Take saved", ActionIcon.Restore, async (_, _) =>
                {
                    _conflictId = null;
                    _detailDirty = false;
                    RefreshGraphFromHost();
                    RenderDetail();
                }));
            body.Children.Add(conflictRow);
        }

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        var saveButton = ActionIconGlyph.PrimaryButton(
            _creating ? "Create" : "Save", ActionIcon.Save, async (_, _) => await SaveAsync(force: false));
        saveButton.IsEnabled = !_working;
        actions.Children.Add(saveButton);
        if (!_creating)
        {
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
                    "Back", ActionIcon.Back, (_, _) =>
                    {
                        _confirmDelete = false;
                        RenderDetail();
                    }));
            }
        }
        else
        {
            actions.Children.Add(ActionIconGlyph.Button(
                "Back", ActionIcon.Back, (_, _) =>
                {
                    _creating = false;
                    _graph = null;
                    _detailDirty = false;
                    RenderDetail();
                }));
        }
        body.Children.Add(actions);

        if (_confirmDelete && !_creating)
        {
            var confirm = new StackPanel { Spacing = Theme.SpaceS };
            confirm.Children.Add(new TextBlock
            {
                Text = $"Delete \"{Format.Text(graph, "name")}\"? This removes the workflow from this host.",
                TextWrapping = TextWrapping.Wrap,
            });
            var confirmRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
            confirmRow.Children.Add(ActionIconGlyph.Button(
                "Delete workflow", ActionIcon.Delete, async (_, _) => await DeleteAsync()));
            confirm.Children.Add(confirmRow);
            body.Children.Add(confirm);
        }

        var title = _creating ? "New workflow" : Format.Text(graph, "name", "Workflow");
        var subtitle = _creating
            ? null
            : $"Revision {_detailRevision?.ToString() ?? "unknown"} · {GraphNodes().Count} steps";
        return Chrome.Card(title, body, subtitle);
    }

    private string DesignBackendId(ComboBox box)
    {
        var index = box.SelectedIndex;
        if (index >= 1 && index - 1 < _backends.Count)
        {
            return _backends[index - 1].Id;
        }
        return "";
    }

    private async Task ApplyRecipeAsync(int recipe, string prompt, string backend)
    {
        if (recipe == 3)
        {
            await DesignFromPromptAsync(prompt, backend);
            return;
        }
        var name = Format.Text(_graph, "name", "Untitled");
        _graph = recipe switch
        {
            1 => RecipeGraph(name, backend, "plan"),
            2 => RecipeGraph(name, backend, "review"),
            _ => BlankGraph(name),
        };
        _stepId = null;
        _detailDirty = true;
        RenderDetail();
    }

    private UIElement ScheduleEditor(JsonNode graph)
    {
        var schedule = graph?["schedule"] ?? graph;
        var body = new StackPanel { Spacing = Theme.SpaceS };
        var kind = new ComboBox { MinWidth = 150 };
        kind.ItemsSource = new[] { "Once", "Interval", "Daily", "Weekdays", "Weekly", "Custom" };
        var current = Format.Text(schedule, "kind", "once");
        kind.SelectedIndex = Math.Max(0, Array.IndexOf(WorkbenchOps.ScheduleKinds, current));
        kind.SelectionChanged += (_, _) =>
        {
            WriteSchedule(kind.SelectedIndex, null, null, null, null, null);
            _detailDirty = true;
        };
        body.Children.Add(Labeled("Schedule", kind));

        var interval = new TextBox
        {
            Text = Math.Max(1, Format.Long(schedule, "everySeconds") / 60).ToString(),
            MinWidth = 100,
        };
        interval.TextChanged += (_, _) =>
        {
            if (ulong.TryParse(interval.Text.Trim(), out var minutes) && minutes > 0)
            {
                WriteSchedule(null, minutes * 60, null, null, null, null);
            }
            _detailDirty = true;
        };
        var intervalRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        intervalRow.Children.Add(interval);
        intervalRow.Children.Add(new TextBlock
        {
            Text = "minutes",
            VerticalAlignment = VerticalAlignment.Center,
            Opacity = 0.68,
        });
        body.Children.Add(Labeled("Every", intervalRow));

        var hour = new ComboBox { MinWidth = 80 };
        hour.ItemsSource = Enumerable.Range(0, 24).Select(h => h.ToString("00")).ToArray();
        hour.SelectedIndex = schedule?["hour"] is null ? 9 : (int)Math.Clamp(Format.Long(schedule, "hour"), 0, 23);
        hour.SelectionChanged += (_, _) =>
        {
            WriteSchedule(null, null, hour.SelectedIndex, null, null, null);
            _detailDirty = true;
        };
        var minute = new ComboBox { MinWidth = 80 };
        minute.ItemsSource = Enumerable.Range(0, 60).Select(m => m.ToString("00")).ToArray();
        minute.SelectedIndex = (int)Math.Clamp(Format.Long(schedule, "minute"), 0, 59);
        minute.SelectionChanged += (_, _) =>
        {
            WriteSchedule(null, null, null, minute.SelectedIndex, null, null);
            _detailDirty = true;
        };
        var timeRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        timeRow.Children.Add(hour);
        timeRow.Children.Add(minute);
        body.Children.Add(Labeled("Time", timeRow));

        var weekday = new ComboBox { MinWidth = 140 };
        weekday.ItemsSource = WorkbenchOps.DayNames.ToArray();
        weekday.SelectedIndex = (int)Math.Clamp(Format.Long(schedule, "weekday"), 0, 6);
        weekday.SelectionChanged += (_, _) =>
        {
            WriteSchedule(null, null, null, null, weekday.SelectedIndex, null);
            _detailDirty = true;
        };
        body.Children.Add(Labeled("Day", weekday));

        var mask = (int)Format.Long(schedule, "weekdays");
        var daysRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        for (var bit = 0; bit < 7; bit++)
        {
            var day = new CheckBox
            {
                Content = WorkbenchOps.DayShortNames[bit],
                IsChecked = (mask & (1 << bit)) != 0,
            };
            var captured = bit;
            day.Click += (_, _) =>
            {
                var current = DaysMask();
                if (day.IsChecked == true)
                {
                    current |= 1 << captured;
                }
                else
                {
                    current &= ~(1 << captured);
                }
                WriteSchedule(null, null, null, null, null, current);
                _detailDirty = true;
            };
            daysRow.Children.Add(day);
        }
        body.Children.Add(Labeled("Days", daysRow));
        return body;
    }

    private void WriteSchedule(int? kind, ulong? everySeconds, int? hour, int? minute, int? weekday, int? weekdays)
    {
        if (_graph is not JsonObject graph)
        {
            return;
        }
        var schedule = graph["schedule"] as JsonObject ?? new JsonObject();
        if (kind is not null)
        {
            schedule["kind"] = WorkbenchOps.ScheduleKinds[Math.Clamp(kind.Value, 0, 5)];
        }
        if (everySeconds is not null)
        {
            schedule["everySeconds"] = everySeconds.Value;
        }
        if (hour is not null)
        {
            schedule["hour"] = Math.Clamp(hour.Value, 0, 23);
        }
        if (minute is not null)
        {
            schedule["minute"] = Math.Clamp(minute.Value, 0, 59);
        }
        if (weekday is not null)
        {
            schedule["weekday"] = Math.Clamp(weekday.Value, 0, 6);
        }
        if (weekdays is not null)
        {
            schedule["weekdays"] = weekdays.Value & 0x7F;
        }
        graph["schedule"] = schedule;
    }

    private int DaysMask()
    {
        var schedule = _graph?["schedule"];
        return (int)Format.Long(schedule, "weekdays");
    }

    private string? ValidateGraph()
    {
        if (_graph is null)
        {
            return "Open a workflow first.";
        }
        if (string.IsNullOrWhiteSpace(Format.Text(_graph, "name")))
        {
            return "Give this workflow a name.";
        }
        var nodes = GraphNodes();
        var edges = GraphEdges();
        if (nodes.Count > MaxSteps)
        {
            return $"A workflow may have at most {MaxSteps} steps.";
        }
        if (edges.Count > MaxConnections)
        {
            return $"A workflow may have at most {MaxConnections} connections.";
        }
        var ids = new HashSet<string>();
        foreach (var node in nodes)
        {
            var id = Format.Text(node, "id").Trim();
            if (string.IsNullOrEmpty(id))
            {
                return "Every step needs an id.";
            }
            if (!ids.Add(id))
            {
                return $"Two steps share the id {id}.";
            }
        }
        foreach (var edge in edges)
        {
            var from = Format.Text(edge, "from");
            var to = Format.Text(edge, "to");
            if (from == to)
            {
                return "A step cannot connect to itself.";
            }
            if (!ids.Contains(from) || !ids.Contains(to))
            {
                return "A connection points at a step that is not here.";
            }
        }
        return null;
    }

    private UIElement StepsCard()
    {
        var body = new StackPanel { Spacing = Theme.SpaceS };
        var nodes = GraphNodes();
        var edges = GraphEdges();
        body.Children.Add(new TextBlock
        {
            Text = $"{nodes.Count} steps · {edges.Count} connections",
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        foreach (var node in nodes)
        {
            if (node is null)
            {
                continue;
            }
            var id = Format.Text(node, "id");
            var kind = NodeKind(node);
            var outgoing = new List<string>();
            foreach (var edge in edges)
            {
                if (Format.Text(edge, "from") == id)
                {
                    outgoing.Add($"{ConnectionLabel(kind, Format.Text(edge, "when", "ok"))} → {Format.Text(edge, "to")}");
                }
            }
            var summary = outgoing.Count == 0 ? "no connections yet" : string.Join(", ", outgoing);
            var row = new StackPanel { Spacing = 2 };
            row.Children.Add(new TextBlock
            {
                Text = $"{KindLabel(kind)} · {Format.Text(node, "title", id)}",
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                TextWrapping = TextWrapping.Wrap,
            });
            row.Children.Add(new TextBlock
            {
                Text = summary,
                FontSize = 12,
                Opacity = 0.68,
                TextWrapping = TextWrapping.Wrap,
            });
            var button = new Button
            {
                Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent),
                BorderThickness = new Thickness(0),
                Padding = new Thickness(0),
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Stretch,
                Content = row,
            };
            var stepId = id;
            button.Click += (_, _) =>
            {
                _stepId = stepId;
                _confirmStep = false;
                RenderDetail();
            };
            body.Children.Add(button);
        }
        var addRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        var kindBox = new ComboBox { MinWidth = 130 };
        kindBox.ItemsSource = KindLabels.ToArray();
        kindBox.SelectedIndex = 1;
        var titleBox = new TextBox { PlaceholderText = "Step title", MinWidth = 160 };
        addRow.Children.Add(kindBox);
        addRow.Children.Add(titleBox);
        addRow.Children.Add(ActionIconGlyph.Button(
            "Add step", ActionIcon.Create, (_, _) => AddStep(kindBox.SelectedIndex, titleBox.Text)));
        body.Children.Add(addRow);
        return Chrome.Card("Steps", body, "Explicit connections first. The canvas stays on the Mac.");
    }

    private void AddStep(int kindIndex, string title)
    {
        var nodes = GraphNodes();
        if (nodes.Count >= MaxSteps)
        {
            Banner($"A workflow may have at most {MaxSteps} steps.");
            return;
        }
        var kind = AuthorableKinds[Math.Clamp(kindIndex, 0, AuthorableKinds.Length - 1)];
        var clean = title.Trim();
        if (string.IsNullOrEmpty(clean))
        {
            clean = KindLabel(kind);
        }
        var id = kind;
        var n = nodes.Count + 1;
        var taken = new HashSet<string>();
        foreach (var node in nodes)
        {
            taken.Add(Format.Text(node, "id"));
        }
        while (taken.Contains(id))
        {
            id = $"{kind}-{n}";
            n++;
        }
        var nodeObject = StepNode(id, kind, clean, 80 + (nodes.Count % 3) * 252, 80 + (nodes.Count / 3) * 160);
        if (kind == "agent")
        {
            nodeObject["prompt"] = "{{input}}";
        }
        nodes.Add(nodeObject);
        _stepId = id;
        _detailDirty = true;
        RenderDetail();
    }

    private bool _confirmStep;

    private UIElement StepCard(JsonNode step)
    {
        var id = Format.Text(step, "id");
        var kind = NodeKind(step);
        var body = new StackPanel { Spacing = Theme.SpaceM };
        body.Children.Add(new TextBlock
        {
            Text = $"{KindLabel(kind)} step",
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });

        var title = new TextBox { Text = Format.Text(step, "title") };
        title.TextChanged += (_, _) =>
        {
            if (step is JsonObject node)
            {
                node["title"] = title.Text;
            }
            _detailDirty = true;
        };
        body.Children.Add(Labeled("Title", title));

        if (step is JsonObject stepObject)
        {
            foreach (var field in StepFields(stepObject, kind))
            {
                body.Children.Add(field);
            }
        }

        body.Children.Add(new TextBlock
        {
            Text = ConnectionCaption(kind),
            FontSize = 12,
            Opacity = 0.68,
            TextWrapping = TextWrapping.Wrap,
        });
        var edges = GraphEdges();
        var outgoing = new StackPanel { Spacing = Theme.SpaceXs };
        foreach (var edge in edges.ToList())
        {
            if (Format.Text(edge, "from") != id)
            {
                continue;
            }
            var when = Format.Text(edge, "when", "ok");
            var to = Format.Text(edge, "to");
            var line = new Grid { ColumnSpacing = Theme.SpaceS };
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            line.Children.Add(new TextBlock
            {
                Text = $"{ConnectionLabel(kind, when)} → {to}",
                VerticalAlignment = VerticalAlignment.Center,
                TextWrapping = TextWrapping.Wrap,
            });
            var remove = ActionIconGlyph.Button("Remove", ActionIcon.Delete, (_, _) =>
            {
                GraphEdges().Remove(edge);
                _detailDirty = true;
                RenderDetail();
            });
            Grid.SetColumn(remove, 1);
            line.Children.Add(remove);
            outgoing.Children.Add(line);
        }
        body.Children.Add(outgoing);

        var targets = new List<string>();
        foreach (var node in GraphNodes())
        {
            var other = Format.Text(node, "id");
            if (!string.IsNullOrEmpty(other) && other != id)
            {
                targets.Add(other);
            }
        }
        if (targets.Count > 0)
        {
            var addRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
            var targetBox = new ComboBox { MinWidth = 130 };
            targetBox.ItemsSource = targets;
            targetBox.SelectedIndex = 0;
            var whens = kind switch
            {
                "condition" => new[] { "Then", "Else", "Always" },
                "loop" => new[] { "Body", "After last pass", "On error" },
                _ => new[] { "Then", "On error", "Always" },
            };
            var whenBox = new ComboBox { MinWidth = 120 };
            whenBox.ItemsSource = whens;
            whenBox.SelectedIndex = 0;
            addRow.Children.Add(targetBox);
            addRow.Children.Add(whenBox);
            addRow.Children.Add(ActionIconGlyph.Button(
                "Add connection", ActionIcon.Create, (_, _) =>
                {
                    AddConnection(id, targetBox.SelectedItem as string ?? "", whenBox.SelectedIndex, kind);
                }));
            body.Children.Add(addRow);
        }

        if (!_confirmStep)
        {
            body.Children.Add(ActionIconGlyph.Button(
                "Remove step", ActionIcon.Delete, (_, _) =>
                {
                    _confirmStep = true;
                    RenderDetail();
                }));
        }
        else
        {
            var confirmRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
            confirmRow.Children.Add(ActionIconGlyph.Button(
                "Remove this step", ActionIcon.Delete, (_, _) => RemoveStep(id)));
            confirmRow.Children.Add(ActionIconGlyph.Button(
                "Back", ActionIcon.Back, (_, _) =>
                {
                    _confirmStep = false;
                    RenderDetail();
                }));
            body.Children.Add(confirmRow);
        }
        return Chrome.Card(Format.Text(step, "title", id), body);
    }

    private List<UIElement> StepFields(JsonObject step, string kind)
    {
        var fields = new List<UIElement>();
        void Text(string key, string label, bool multiline = false, string placeholder = "")
        {
            var box = new TextBox
            {
                Text = Format.Text(step, key),
                PlaceholderText = placeholder,
                AcceptsReturn = multiline,
                TextWrapping = TextWrapping.Wrap,
            };
            if (multiline)
            {
                box.MinHeight = 96;
            }
            box.TextChanged += (_, _) =>
            {
                step[key] = box.Text;
                _detailDirty = true;
            };
            fields.Add(Labeled(label, box));
        }
        if (kind is "agent" or "input")
        {
            Text("prompt", kind == "input" ? "Prompt ({{input}} fills on Run)" : "Prompt", true);
        }
        if (kind == "agent")
        {
            var backendBox = new ComboBox { MinWidth = 200 };
            var names = new List<string> { "Default agent" };
            names.AddRange(_backends.Select(b => b.Label));
            backendBox.ItemsSource = names;
            var backendId = Format.Text(step, "backend");
            var index = _backends.FindIndex(b => b.Id == backendId);
            backendBox.SelectedIndex = index >= 0 ? index + 1 : 0;
            backendBox.SelectionChanged += (_, _) =>
            {
                var pick = backendBox.SelectedIndex;
                step["backend"] = pick >= 1 && pick - 1 < _backends.Count ? _backends[pick - 1].Id : "";
                _detailDirty = true;
            };
            fields.Add(Labeled("Agent", backendBox));
            Text("model", "Model", placeholder: "Default model");
            Text("effort", "Effort", placeholder: "Default effort");
        }
        if (kind == "command")
        {
            Text("command", "Command", true);
        }
        if (kind == "http")
        {
            var method = new ComboBox { MinWidth = 120 };
            method.ItemsSource = new[] { "GET", "POST", "PUT", "DELETE" };
            var current = Format.Text(step, "method", "GET");
            method.SelectedIndex = Math.Max(0, Array.IndexOf(new[] { "GET", "POST", "PUT", "DELETE" }, current));
            method.SelectionChanged += (_, _) =>
            {
                step["method"] = method.SelectedItem as string ?? "GET";
                _detailDirty = true;
            };
            fields.Add(Labeled("Method", method));
            Text("url", "URL");
            Text("body", "Body", true);
        }
        if (kind == "condition")
        {
            Text("test", "Test (reads the previous step)");
            Text("pattern", "Pattern");
        }
        if (kind == "loop")
        {
            var times = new TextBox { Text = Format.Text(step, "times", "3"), MinWidth = 80 };
            times.TextChanged += (_, _) =>
            {
                if (uint.TryParse(times.Text.Trim(), out var count) && count >= 1 && count <= 20)
                {
                    step["times"] = count;
                }
                _detailDirty = true;
            };
            fields.Add(Labeled("Passes (at most 20)", times));
            Text("until", "Stop when found");
        }
        if (kind == "automation")
        {
            Text("automationId", "Automation id");
            Text("promptOverride", "Prompt override", true);
        }
        if (kind == "gate")
        {
            Text("wait", "Wait");
            Text("waitPattern", "Wait pattern");
        }
        return fields;
    }

    private void AddConnection(string from, string to, int whenIndex, string kind)
    {
        if (string.IsNullOrEmpty(to))
        {
            return;
        }
        if (from == to)
        {
            Banner("A step cannot connect to itself.");
            return;
        }
        var when = (kind, whenIndex) switch
        {
            ("condition", 1) => "error",
            ("loop", 0) => "ok",
            ("loop", 1) => "always",
            ("loop", _) => "error",
            (_, 1) => "error",
            (_, 2) => "always",
            _ => "ok",
        };
        var edges = GraphEdges();
        foreach (var edge in edges)
        {
            if (Format.Text(edge, "from") == from && Format.Text(edge, "to") == to)
            {
                edge["when"] = when;
                _detailDirty = true;
                RenderDetail();
                return;
            }
        }
        if (edges.Count >= MaxConnections)
        {
            Banner($"A workflow may have at most {MaxConnections} connections.");
            return;
        }
        edges.Add(Edge(from, to, when));
        _detailDirty = true;
        RenderDetail();
    }

    private void RemoveStep(string id)
    {
        var nodes = GraphNodes();
        for (var i = nodes.Count - 1; i >= 0; i--)
        {
            if (Format.Text(nodes[i], "id") == id)
            {
                nodes.RemoveAt(i);
            }
        }
        var edges = GraphEdges();
        for (var i = edges.Count - 1; i >= 0; i--)
        {
            if (Format.Text(edges[i], "from") == id || Format.Text(edges[i], "to") == id)
            {
                edges.RemoveAt(i);
            }
        }
        if (_stepId == id)
        {
            _stepId = null;
        }
        _confirmStep = false;
        _detailDirty = true;
        RenderDetail();
    }

    /// <summary>
    /// The graph object itself carries every field, including ones this page
    /// never shows, so saving it back preserves unknown host fields on the
    /// graph and on every step without a separate merge pass.
    /// </summary>
    private JsonObject SavePayload()
    {
        return (JsonObject)(_graph?.DeepClone() ?? new JsonObject());
    }

    private async Task SaveAsync(bool force)
    {
        var error = ValidateGraph();
        if (error is not null)
        {
            Banner(error);
            return;
        }
        _working = true;
        try
        {
            if (_creating)
            {
                var payload = SavePayload();
                payload["id"] = "";
                var created = await AppServices.Host.CallAsync(
                    "workflow.create", new JsonObject { ["workflow"] = payload });
                _creating = false;
                _selectedId = Format.Text(created, "id");
                _detailDirty = false;
                _conflictId = null;
                Notice("Workflow added.");
            }
            else if (_selectedId is not null)
            {
                var id = _selectedId;
                var payload = SavePayload();
                payload["id"] = id;
                if (WorkbenchOps.WorkflowEditing(_protocol))
                {
                    var revision = force ? await FreshRevisionAsync(id) : _detailRevision;
                    if (revision is null)
                    {
                        Banner("Reload this workflow before saving it.");
                        return;
                    }
                    payload["revision"] = revision.Value;
                    try
                    {
                        await AppServices.Host.CallAsync("workflow.edit", new JsonObject
                        {
                            ["workflow"] = payload,
                            ["expectedRevision"] = revision.Value,
                        });
                    }
                    catch (Exception ex) when (WorkbenchOps.IsConflict(ex))
                    {
                        _conflictId = id;
                        Banner("This workflow changed since you opened it. Compare the saved graph before replacing it.");
                        await LoadAsync();
                        return;
                    }
                }
                else
                {
                    await AppServices.Host.CallAsync(
                        "workflow.update", new JsonObject { ["workflow"] = payload });
                }
                _detailDirty = false;
                _conflictId = null;
                Notice($"Saved \"{Format.Text(_graph, "name")}\".");
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

    private async Task<ulong?> FreshRevisionAsync(string id)
    {
        try
        {
            var fresh = await AppServices.Host.CallAsync("workflow.get", new JsonObject { ["id"] = id });
            return WorkbenchOps.Revision(fresh);
        }
        catch
        {
            return null;
        }
    }

    private async Task DeleteAsync()
    {
        if (_selectedId is null)
        {
            return;
        }
        _working = true;
        try
        {
            await AppServices.Host.CallAsync(
                "workflow.remove", new JsonObject { ["id"] = _selectedId });
            Notice("Workflow deleted.");
            _creating = false;
            _selectedId = null;
            _graph = null;
            _detailDirty = false;
            _confirmDelete = false;
            _stepId = null;
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

    private async Task DesignFromPromptAsync(string prompt, string backend)
    {
        var clean = prompt.Trim();
        if (string.IsNullOrEmpty(clean))
        {
            Banner("Describe the workflow to draft.");
            return;
        }
        _working = true;
        Notice("Designing. This drains an agent and can take minutes.");
        try
        {
            var parameters = new JsonObject { ["prompt"] = clean };
            if (_scopeWorkspaceId is not null)
            {
                parameters["workspaceId"] = _scopeWorkspaceId;
            }
            else
            {
                var graphFolder = Format.Text(_graph, "workspaceId");
                if (!string.IsNullOrEmpty(graphFolder))
                {
                    parameters["workspaceId"] = graphFolder;
                }
            }
            if (!string.IsNullOrEmpty(backend))
            {
                parameters["backend"] = backend;
            }
            // Design drains a backend for up to three minutes, so allow four.
            var designed = await AppServices.Host.CallAsync(
                "workflow.design", parameters, TimeSpan.FromMinutes(4));
            if (designed is JsonObject graph && graph.Count > 0)
            {
                var name = Format.Text(_graph, "name");
                _graph = (JsonObject)designed.DeepClone();
                if (!string.IsNullOrWhiteSpace(name) && name != "Untitled")
                {
                    _graph["name"] = name;
                }
                _graph["id"] = _creating ? "" : _selectedId ?? "";
                _stepId = null;
                _detailDirty = true;
                Notice("Draft ready. Review the steps, then Create or Save.");
            }
            else
            {
                Banner("The designer returned nothing. Try a more concrete prompt.");
            }
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
        }
        finally
        {
            _working = false;
        }
        RenderDetail();
    }

    private UIElement RunCard()
    {
        var body = new StackPanel { Spacing = Theme.SpaceS };
        var input = new TextBox
        {
            Text = _runInput,
            PlaceholderText = "Starting prompt, fills {{input}}",
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
        };
        input.TextChanged += (_, _) => _runInput = input.Text;
        body.Children.Add(Labeled("Input", input));
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        var runButton = ActionIconGlyph.PrimaryButton(
            "Run", ActionIcon.Run, async (_, _) => await RunAsync());
        runButton.IsEnabled = !_working && !_creating;
        row.Children.Add(runButton);
        body.Children.Add(row);
        return Chrome.Card("Run", body, FolderLabel(Format.Text(_graph, "workspaceId")));
    }

    private async Task RunAsync()
    {
        if (_creating || _selectedId is null)
        {
            Banner("Save the workflow before running it.");
            return;
        }
        if (_detailDirty)
        {
            await SaveAsync(force: false);
            if (_detailDirty)
            {
                Banner("Save the workflow before running it.");
                return;
            }
        }
        _working = true;
        try
        {
            var parameters = new JsonObject
            {
                ["id"] = _selectedId,
                ["input"] = _runInput,
            };
            var folder = Format.Text(_graph, "workspaceId");
            if (!string.IsNullOrEmpty(folder))
            {
                parameters["workspaceId"] = folder;
            }
            await AppServices.Host.CallAsync("workflow.run", parameters);
            Notice("The run started.");
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

    /// <summary>
    /// Run one workflow from its list row. The row's graph is already saved
    /// on the host, so this starts it directly instead of going through the
    /// detail's select-and-save path.
    /// </summary>
    private async Task RunAsync(string id)
    {
        if (_working)
        {
            return;
        }
        _working = true;
        try
        {
            var parameters = new JsonObject
            {
                ["id"] = id,
                ["input"] = _runInput,
            };
            foreach (var graph in _graphs)
            {
                if (Format.Text(graph, "id") == id)
                {
                    var folder = Format.Text(graph, "workspaceId");
                    if (!string.IsNullOrEmpty(folder))
                    {
                        parameters["workspaceId"] = folder;
                    }
                    break;
                }
            }
            await AppServices.Host.CallAsync("workflow.run", parameters);
            Notice("The run started.");
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

    private async Task KillAsync(string runId)
    {
        try
        {
            await AppServices.Host.CallAsync("workflow.kill", new JsonObject { ["id"] = runId });
            Notice("Stopped.");
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
            return;
        }
        await LoadAsync();
    }

    private async Task ContinueAsync(string runId)
    {
        try
        {
            await AppServices.Host.CallAsync("workflow.continue", new JsonObject { ["id"] = runId });
            Notice("The run continued.");
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
            return;
        }
        await LoadAsync();
    }

    private UIElement HistoryCard(string graphId)
    {
        var body = new StackPanel { Spacing = Theme.SpaceM };
        var runs = GraphRuns(graphId);
        if (runs.Count == 0)
        {
            body.Children.Add(new TextBlock
            {
                Text = "No runs yet. Run this workflow to see its history here.",
                Opacity = 0.66,
                TextWrapping = TextWrapping.Wrap,
            });
        }
        foreach (var run in runs)
        {
            if (run is null)
            {
                continue;
            }
            body.Children.Add(RunDetail(run));
        }
        return Chrome.Card("Run history", body, $"{runs.Count} runs");
    }

    private UIElement RunDetail(JsonNode run)
    {
        var runId = Format.Text(run, "id");
        var status = Format.Text(run, "status");
        var live = RunLive(run);
        var body = new StackPanel { Spacing = Theme.SpaceS };
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
        var input = Format.Text(run, "input");
        if (!string.IsNullOrEmpty(input))
        {
            body.Children.Add(new TextBlock
            {
                Text = input,
                FontSize = 12,
                Opacity = 0.8,
                TextWrapping = TextWrapping.Wrap,
                IsTextSelectionEnabled = true,
            });
        }
        foreach (var step in run["steps"] as JsonArray ?? new JsonArray())
        {
            if (step is null)
            {
                continue;
            }
            var nodeId = Format.Text(step, "nodeId", Format.Text(step, "id"));
            var stepStatus = Format.Text(step, "status");
            var key = runId + "\n" + nodeId;
            var stepBox = new StackPanel { Spacing = Theme.SpaceXs };
            stepBox.Children.Add(new TextBlock
            {
                Text = $"{nodeId} · {WorkbenchOps.RunLabel(stepStatus)}",
                TextWrapping = TextWrapping.Wrap,
            });
            if (_transcripts.TryGetValue(key, out var saved))
            {
                stepBox.Children.Add(new TextBlock
                {
                    Text = saved.Text,
                    TextWrapping = TextWrapping.Wrap,
                    IsTextSelectionEnabled = true,
                    Opacity = 0.9,
                });
                if (saved.Next > 0)
                {
                    var offset = saved.Next;
                    var moreNode = nodeId;
                    stepBox.Children.Add(ActionIconGlyph.Button(
                        "More", ActionIcon.More, async (_, _) => await LoadStepTranscriptAsync(runId, moreNode, offset)));
                }
            }
            var node = nodeId;
            stepBox.Children.Add(ActionIconGlyph.Button(
                "Transcript", ActionIcon.History, async (_, _) => await LoadStepTranscriptAsync(runId, node, 0)));
            body.Children.Add(stepBox);
        }
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        if (status == "waiting")
        {
            row.Children.Add(ActionIconGlyph.PrimaryButton(
                "Continue", ActionIcon.Run, async (_, _) => await ContinueAsync(runId)));
        }
        if (live && !string.IsNullOrEmpty(runId))
        {
            var liveId = runId;
            row.Children.Add(ActionIconGlyph.Button(
                "Stop", ActionIcon.Stop, async (_, _) => await KillAsync(liveId)));
        }
        if (row.Children.Count > 0)
        {
            body.Children.Add(row);
        }
        return body;
    }

    private async Task LoadStepTranscriptAsync(string runId, string nodeId, ulong offset)
    {
        try
        {
            var answer = await AppServices.Host.CallAsync(
                "workflow.transcript",
                new JsonObject { ["id"] = runId, ["nodeId"] = nodeId, ["offset"] = offset });
            var text = Format.Text(answer, "text");
            ulong next = 0;
            try { next = answer?["nextOffset"]?.GetValue<ulong>() ?? 0; } catch { /* keep */ }
            var key = runId + "\n" + nodeId;
            var previous = offset > 0 && _transcripts.TryGetValue(key, out var kept) ? kept.Text : "";
            _transcripts[key] = (previous + text, next);
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
        }
        RenderDetail();
    }
}
