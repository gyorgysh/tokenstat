// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

using System.Diagnostics;
using System.Text.Json.Nodes;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Tokenstat.Design;
using Tokenstat.Navigation;

namespace Tokenstat.Pages;

/// <summary>
/// Native pull-request list and review surface. Network calls stay behind the
/// host boundary; this page only asks because it loaded or a labelled control
/// was pressed.
/// </summary>
internal sealed class PullsPage : Page, IInspectorContent, IToolbarItems
{
    private readonly string _workspaceId;
    private readonly StackPanel _inspector = new()
    {
        Spacing = Theme.SpaceM,
        Padding = new Thickness(Theme.SpaceM),
    };
    private readonly StackPanel _root = new() { Spacing = Theme.SpaceL };
    private readonly ComboBox _scope = new() { MinWidth = 145 };
    private readonly ComboBox _state = new() { MinWidth = 120 };
    private CancellationTokenSource? _loginPoll;
    private string _folderName = "";
    private string _repo = "";
    private string _login = "";
    private string _source = "";
    private int _listCount;
    private long? _openNumber;
    private JsonNode? _detail;

    public PullsPage(string workspaceId)
    {
        _workspaceId = workspaceId;
        _scope.ItemsSource = new[] { "All", "Mine", "Assigned", "Review requested" };
        _scope.SelectedIndex = 0;
        _state.ItemsSource = new[] { "Open", "Merged", "Closed", "Draft" };
        _state.SelectedIndex = 0;
        _scope.SelectionChanged += async (_, _) => await LoadListAsync();
        _state.SelectionChanged += async (_, _) => await LoadListAsync();
        // A scanned list takes the window, like the Mac ReadingRoom: no lane,
        // leading, with the wide gutters. The lane that keeps prose readable
        // is the lane that pushes rows into each other.
        Content = new ScrollViewer
        {
            Padding = new Thickness(Theme.SpaceXl),
            Content = _root,
        };
        RenderInspector();
        Loaded += async (_, _) => await LoadAsync();
        Unloaded += (_, _) => _loginPoll?.Cancel();
    }

    public event Action? ToolbarChanged;

    /// <summary>
    /// The folder these pull requests belong to.
    /// </summary>
    public UIElement? ToolbarScope =>
        Chrome.ScopeChip(string.IsNullOrEmpty(_folderName) ? "Pull requests" : _folderName);

    public IList<UIElement> ToolbarActions()
    {
        return new List<UIElement>
        {
            Buttons.ToolbarIcon(
                ActionIcon.Refresh,
                "Reload pull requests",
                async (_, _) =>
                {
                    LogoRefresh.Began();
                    if (_openNumber.HasValue)
                    {
                        await ShowDetailAsync(_openNumber.Value, true);
                    }
                    else
                    {
                        await LoadAsync(true);
                    }
                }),
        };
    }

    private void RaiseToolbarChanged() => ToolbarChanged?.Invoke();

    /// <summary>
    /// The inspector column content: the repository and connection, and the
    /// open pull request when one is on screen. List and detail loads repaint
    /// it, so the column stays live without the shell asking again.
    /// </summary>
    public UIElement? Inspector => _inspector;

    private void RenderInspector()
    {
        _inspector.Children.Clear();
        if (_detail is not null && _openNumber.HasValue)
        {
            var detail = _detail;
            _inspector.Children.Add(new TextBlock
            {
                Text = $"#{_openNumber} {Format.Text(detail, "title")}",
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                TextWrapping = TextWrapping.Wrap,
            });
            _inspector.Children.Add(Chrome.InspectorField(
                "State",
                Format.Flag(detail, "draft")
                    ? "Draft"
                    : Format.Text(detail, "state", "open")));
            _inspector.Children.Add(Chrome.InspectorField(
                "Branch",
                $"{Format.Text(detail, "headRef")} → {Format.Text(detail, "baseRef")}"));
            _inspector.Children.Add(Chrome.InspectorField(
                "Changes",
                $"+{Format.Long(detail, "additions")} −{Format.Long(detail, "deletions")}"));
            _inspector.Children.Add(Chrome.InspectorField(
                "Files", $"{Format.Long(detail, "changedFiles")}"));
            var checks = detail["checks"] as JsonArray;
            _inspector.Children.Add(Chrome.InspectorField("Checks", $"{checks?.Count ?? 0}"));
            return;
        }
        _inspector.Children.Add(new TextBlock
        {
            Text = "Pull requests",
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        if (!string.IsNullOrEmpty(_repo))
        {
            _inspector.Children.Add(Chrome.InspectorField("Repository", _repo));
        }
        if (!string.IsNullOrEmpty(_login))
        {
            _inspector.Children.Add(Chrome.InspectorField("Connected", "@" + _login, SourceLabel(_source)));
        }
        _inspector.Children.Add(new TextBlock
        {
            Text = _listCount == 0
                ? "Nothing listed under these filters."
                : $"{_listCount} {(_listCount == 1 ? "pull request" : "pull requests")} listed.",
            Opacity = 0.7,
            TextWrapping = TextWrapping.Wrap,
        });
    }

    /// <summary>
    /// One workspace-scoped pulls method against this folder, local or
    /// remote. A remote folder travels as remote.call with the peer's own
    /// folder id, the way the desktop Mac routes every pulls read and write.
    /// Params are copied, never mutated, so a retry cannot forward an already
    /// rewritten id. The sign-in flow has no folder and always stays local,
    /// matching the Mac.
    /// </summary>
    private Task<JsonNode> CallPullsAsync(string method, JsonNode? parameters = null)
    {
        if (!RemoteWorkspaces.TrySplit(_workspaceId, out var peer, out var inner))
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

    private async Task<string> FolderNameAsync()
    {
        if (RemoteWorkspaces.CachedFolder(_workspaceId) is RemoteFolder cached)
        {
            return cached.DisplayName;
        }
        try
        {
            var listed = await AppServices.Host.CallAsync("workspace.list");
            var array = listed as JsonArray ?? listed["workspaces"] as JsonArray;
            if (array is not null)
            {
                foreach (var folder in array)
                {
                    if (Format.Text(folder, "id") == _workspaceId)
                    {
                        return Format.Text(folder, "name", Format.Text(folder, "path", _workspaceId));
                    }
                }
            }
        }
        catch
        {
        }
        return "";
    }

    private async Task LoadAsync(bool refresh = false)
    {
        _root.Children.Clear();
        _openNumber = null;
        _detail = null;
        _root.Children.Add(Header("Review the work around this branch"));
        var skeleton = Motion.SkeletonCard();
        _root.Children.Add(skeleton);
        _folderName = await FolderNameAsync();
        RaiseToolbarChanged();
        RenderInspector();
        UIElement? rows = null;
        try
        {
            var availability = await CallPullsAsync(
                "pulls.availability",
                new JsonObject { ["workspaceId"] = _workspaceId });
            _root.Children.Remove(skeleton);
            var state = Format.Text(availability, "state");
            switch (state)
            {
                case "ready":
                    _repo = Format.Text(availability, "repo");
                    _login = Format.Text(availability, "login");
                    _source = Format.Text(availability, "source");
                    RenderInspector();
                    _root.Children[0] = Header(
                        Format.Text(availability, "repo", "Pull requests"));
                    _root.Children.Add(ConnectionLine(availability));
                    _root.Children.Add(FilterBar());
                    rows = Motion.SkeletonCard();
                    _root.Children.Add(rows);
                    await AppendListAsync(refresh);
                    _root.Children.Remove(rows);
                    rows = null;
                    break;
                case "signedOut":
                    _root.Children.Add(ConnectionCard());
                    break;
                case "needsInstallation":
                case "noRepositoryAccess":
                    _root.Children.Add(AccessCard(availability, state));
                    break;
                case "notRepository":
                    _root.Children.Add(Chrome.Empty(
                        "This folder is not a Git repository",
                        "Pull requests appear for folders with a Git repository and a GitHub origin.",
                        ActionIcon.Merge));
                    break;
                case "noRemote":
                    _root.Children.Add(Chrome.Empty(
                        "No GitHub origin yet",
                        "Add an origin remote to this repository, then refresh this screen.",
                        ActionIcon.Merge));
                    break;
                default:
                    _root.Children.Add(Chrome.Empty(
                        "Pull requests are unavailable",
                        "Refresh to ask the workspace host again.",
                        ActionIcon.Merge));
                    break;
            }
        }
        catch (Exception ex)
        {
            _root.Children.Remove(skeleton);
            if (rows is not null)
            {
                _root.Children.Remove(rows);
            }
            _root.Children.Add(Chrome.Banner(ex.Message, Theme.Warning, Symbol.Important));
        }
    }

    private UIElement Header(string subtitle)
    {
        var row = new Grid();
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var mark = new Border
        {
            Width = 42,
            Height = 42,
            CornerRadius = new CornerRadius(12),
            Background = Theme.AccentSoftBrush,
            Child = new SymbolIcon
            {
                Symbol = ActionIcon.Merge.Symbol(),
                Foreground = Theme.AccentBrush,
            },
        };
        row.Children.Add(mark);
        var titles = new StackPanel { Spacing = 2, Margin = new Thickness(Theme.SpaceM, 0, 0, 0) };
        titles.Children.Add(new TextBlock
        {
            Text = "Pull requests",
            FontSize = Fonts.PageTitle,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        titles.Children.Add(new TextBlock { Text = subtitle, Opacity = 0.66, TextWrapping = TextWrapping.Wrap });
        Grid.SetColumn(titles, 1);
        row.Children.Add(titles);
        return row;
    }

    private static UIElement ConnectionLine(JsonNode availability)
    {
        var login = Format.Text(availability, "login", "connected");
        var source = SourceLabel(Format.Text(availability, "source"));
        return new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Theme.SpaceS,
            Children =
            {
                new Border
                {
                    Width = 8, Height = 8, CornerRadius = new CornerRadius(4),
                    Background = Theme.Brush(static () => Theme.Success),
                    VerticalAlignment = VerticalAlignment.Center,
                },
                new TextBlock
                {
                    Text = $"@{login} · {source}",
                    Opacity = 0.72,
                    VerticalAlignment = VerticalAlignment.Center,
                },
            },
        };
    }

    private UIElement FilterBar()
    {
        return new Border
        {
            Background = Theme.AccentSoftBrush,
            BorderBrush = Theme.BorderBrush,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(Theme.CardRadius),
            Padding = new Thickness(Theme.SpaceM),
            Child = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = Theme.SpaceM,
                Children =
                {
                    LabeledControl("Scope", _scope),
                    LabeledControl("State", _state),
                },
            },
        };
    }

    private static UIElement LabeledControl(string label, Control control)
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

    private async Task LoadListAsync()
    {
        if (!IsLoaded)
        {
            return;
        }
        await LoadAsync();
    }

    private async Task AppendListAsync(bool refresh)
    {
        var scopes = new[] { "all", "mine", "assigned", "reviewRequested" };
        var states = new[] { "open", "merged", "closed", "draft" };
        var listed = await CallPullsAsync("pulls.list", new JsonObject
        {
            ["workspaceId"] = _workspaceId,
            ["scope"] = scopes[Math.Max(0, _scope.SelectedIndex)],
            ["state"] = states[Math.Max(0, _state.SelectedIndex)],
            ["limit"] = 40,
            ["refresh"] = refresh,
        });
        var rows = listed as JsonArray;
        _listCount = rows?.Count ?? 0;
        RenderInspector();
        if (rows is null || rows.Count == 0)
        {
            _root.Children.Add(Chrome.Empty(
                $"No {states[Math.Max(0, _state.SelectedIndex)]} pull requests",
                "Nothing in this repository matches the selected scope and state.",
                ActionIcon.Merge));
            return;
        }
        var list = new StackPanel { Spacing = Theme.SpaceS };
        foreach (var pull in rows)
        {
            if (pull is null) continue;
            list.Children.Add(PullRow(pull));
        }
        _root.Children.Add(list);
    }

    private UIElement PullRow(JsonNode pull)
    {
        var number = Format.Long(pull, "number");
        var state = Format.Text(pull, "state", "open");
        var draft = Format.Flag(pull, "draft");
        var tint = StateTint(state, draft);
        var body = new StackPanel { Spacing = Theme.SpaceS };
        var heading = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        heading.Children.Add(new TextBlock
        {
            Text = $"#{number}", Foreground = Theme.Brush(tint),
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        heading.Children.Add(new TextBlock
        {
            Text = Format.Text(pull, "title"),
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
            MaxWidth = 680,
        });
        body.Children.Add(heading);
        body.Children.Add(new TextBlock
        {
            Text = $"{Format.Text(pull, "author")}  ·  {Format.Text(pull, "headRef")} → {Format.Text(pull, "baseRef")}",
            FontSize = 12,
            Opacity = 0.68,
            TextWrapping = TextWrapping.Wrap,
        });
        body.Children.Add(Fonts.Tabular(new TextBlock
        {
            Text = $"+{Format.Long(pull, "additions")}   −{Format.Long(pull, "deletions")}   {Format.Long(pull, "changedFiles")} files   {Format.Long(pull, "comments")} comments",
            FontSize = 11,
            Foreground = Theme.Brush(tint),
        }));
        var card = new Border
        {
            Background = Theme.PanelBrush,
            BorderBrush = Theme.BorderBrush,
            BorderThickness = new Thickness(1, 1, 1, 1),
            CornerRadius = new CornerRadius(Theme.CardRadius),
            Padding = new Thickness(Theme.CardPadding),
            Child = body,
        };
        var button = new Button
        {
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(0),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Content = card,
        };
        button.Click += async (_, _) => await ShowDetailAsync(number);
        return button;
    }

    private UIElement ConnectionCard()
    {
        var body = new StackPanel { Spacing = Theme.SpaceM };
        body.Children.Add(new TextBlock
        {
            Text = "Read the conversation, inspect the same diff as Changes, follow checks, and review without losing the workspace around it.",
            TextWrapping = TextWrapping.Wrap,
            Opacity = 0.74,
        });
        body.Children.Add(ActionIconGlyph.PrimaryButton(
            "Connect GitHub", ActionIcon.Connect, async (_, _) => await StartLoginAsync()));
        return Chrome.Card("Bring the review into tokenstat", body);
    }

    private UIElement AccessCard(JsonNode availability, string state)
    {
        var body = new StackPanel { Spacing = Theme.SpaceM };
        body.Children.Add(new TextBlock
        {
            Text = state == "needsInstallation"
                ? "Choose the repositories tokenstat may open."
                : "The connection works, but this repository is not in tokenstat's selected repositories.",
            TextWrapping = TextWrapping.Wrap,
            Opacity = 0.74,
        });
        var url = Format.Text(availability, "installUrl");
        if (!string.IsNullOrEmpty(url))
        {
            body.Children.Add(ActionIconGlyph.PrimaryButton(
                "Choose repositories", ActionIcon.External, (_, _) => Open(url)));
        }
        return Chrome.Card("Grant repository access", body, "Only repositories selected for the GitHub App are visible.");
    }

    private async Task StartLoginAsync()
    {
        _loginPoll?.Cancel();
        try
        {
            var started = await AppServices.Host.CallAsync("pulls.signIn", new JsonObject());
            var url = Format.Text(started, "openUrl");
            var code = Format.Text(started, "userCode");
            if (!string.IsNullOrEmpty(url)) Open(url);
            _root.Children.Insert(1, Chrome.Banner(
                string.IsNullOrEmpty(code)
                    ? "Complete the connection in your browser."
                    : $"Enter {code} in the GitHub page that just opened.",
                Theme.Accent,
                Symbol.Contact));
            _loginPoll = new CancellationTokenSource();
            _root.Children.Insert(2, ActionIconGlyph.Button(
                "Cancel sign-in", ActionIcon.Dismiss, async (_, _) => await CancelLoginAsync()));
            var token = _loginPoll.Token;
            while (!token.IsCancellationRequested)
            {
                var interval = Math.Max(1, Format.Long(started, "interval"));
                await Task.Delay(TimeSpan.FromSeconds(interval), token);
                var polled = await AppServices.Host.CallAsync("pulls.signInPoll", new JsonObject());
                if (Format.Text(polled, "state") == "confirmed")
                {
                    await LoadAsync();
                    return;
                }
                var next = Format.Long(polled, "interval");
                if (next > 0 && started is JsonObject startedObject) startedObject["interval"] = next;
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            _root.Children.Insert(1, Chrome.Banner(ex.Message, Theme.Warning, Symbol.Important));
        }
    }

    /// <summary>
    /// The device flow holds server state, so leaving it cancels the wait
    /// rather than leaving a code the page forgot about.
    /// </summary>
    private async Task CancelLoginAsync()
    {
        _loginPoll?.Cancel();
        try
        {
            await AppServices.Host.CallAsync("pulls.cancelSignIn", new JsonObject());
        }
        catch
        {
        }
        await LoadAsync();
    }

    private async Task ShowDetailAsync(long number, bool refresh = false)
    {
        _root.Children.Clear();
        _openNumber = number;
        _detail = null;
        var chrome = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        chrome.Children.Add(ActionIconGlyph.Button("Pull requests", ActionIcon.Back, async (_, _) => await LoadAsync()));
        chrome.Children.Add(ActionIconGlyph.Button("Refresh", ActionIcon.Refresh, async (_, _) => await ShowDetailAsync(number, true)));
        _root.Children.Add(chrome);
        try
        {
            var detailTask = CallPullsAsync("pulls.view", new JsonObject
            {
                ["workspaceId"] = _workspaceId, ["number"] = number, ["refresh"] = refresh,
            });
            var timelineTask = CallPullsAsync("pulls.timeline", new JsonObject
            {
                ["workspaceId"] = _workspaceId, ["number"] = number, ["refresh"] = refresh,
            });
            await Task.WhenAll(detailTask, timelineTask);
            var detail = detailTask.Result;
            var timeline = timelineTask.Result;
            _detail = detail;
            RenderInspector();
            _root.Children.Add(DetailHero(detail));

            var tabs = new TabView();
            tabs.TabItems.Add(new TabViewItem
            {
                Header = "Conversation",
                IsClosable = false,
                Content = Conversation(detail, timeline, number),
            });
            tabs.TabItems.Add(new TabViewItem
            {
                Header = $"Changes ({Format.Long(detail, "changedFiles")})",
                IsClosable = false,
                Content = LazyDiff(),
            });
            tabs.TabItems.Add(new TabViewItem
            {
                Header = $"Checks ({(detail["checks"] as JsonArray)?.Count ?? 0})",
                IsClosable = false,
                Content = Checks(detail),
            });
            tabs.SelectionChanged += async (_, _) =>
            {
                if (tabs.SelectedIndex == 1 && tabs.TabItems[1] is TabViewItem item
                    && item.Content is Grid holder && holder.Tag is null)
                {
                    holder.Tag = true;
                    await LoadDiffAsync(holder, number);
                }
            };
            _root.Children.Add(tabs);
            _root.Children.Add(ActionPanel(detail, number));
        }
        catch (Exception ex)
        {
            _root.Children.Add(Chrome.Banner(ex.Message, Theme.Warning, Symbol.Important));
        }
    }

    private static UIElement DetailHero(JsonNode detail)
    {
        var actor = detail["author"];
        var body = new StackPanel { Spacing = Theme.SpaceS };
        body.Children.Add(new TextBlock
        {
            Text = Format.Text(detail, "title"), FontSize = 23,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
        });
        body.Children.Add(new TextBlock
        {
            Text = $"{Format.Text(actor, "login")} opened #{Format.Long(detail, "number")}",
            Opacity = 0.68,
        });
        body.Children.Add(new TextBlock
        {
            Text = $"{Format.Text(detail, "headRef")}  →  {Format.Text(detail, "baseRef")}    +{Format.Long(detail, "additions")}  −{Format.Long(detail, "deletions")}  ·  {Format.Long(detail, "changedFiles")} files",
            Foreground = Theme.AccentBrush,
            TextWrapping = TextWrapping.Wrap,
        });
        return new Border
        {
            Background = Theme.AccentSoftBrush,
            BorderBrush = Theme.Brush(static () => Theme.Accent),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(Theme.CardRadius),
            Padding = new Thickness(Theme.CardPadding),
            Child = body,
        };
    }

    private UIElement Conversation(JsonNode detail, JsonNode timeline, long number)
    {
        var stack = new StackPanel { Spacing = Theme.SpaceM, Padding = new Thickness(0, Theme.SpaceM, 0, Theme.SpaceM) };
        var description = Format.Text(detail, "body");
        stack.Children.Add(Chrome.Card(
            Format.Text(detail["author"], "login", "Author"),
            new TextBlock
            {
                Text = string.IsNullOrWhiteSpace(description) ? "No description was added." : description,
                TextWrapping = TextWrapping.Wrap,
                IsTextSelectionEnabled = true,
                Opacity = string.IsNullOrWhiteSpace(description) ? 0.6 : 1,
            }));
        foreach (var entry in Format.Items(timeline, "events") ?? new JsonArray())
        {
            if (entry is null) continue;
            var actor = Format.Text(entry["actor"], "login", "Someone");
            var kind = Format.Text(entry, "kind");
            var body = Format.Text(entry, "body", Format.Text(entry, "subject"));
            stack.Children.Add(Chrome.Card(
                TimelineTitle(actor, kind),
                new TextBlock
                {
                    Text = string.IsNullOrEmpty(body) ? TimelineSentence(kind) : body,
                    TextWrapping = TextWrapping.Wrap,
                    IsTextSelectionEnabled = true,
                }));
        }
        var comment = new TextBox
        {
            PlaceholderText = "Add to the conversation…",
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            MinHeight = 96,
        };
        var composer = new StackPanel { Spacing = Theme.SpaceS };
        composer.Children.Add(comment);
        var composerActions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        composerActions.Children.Add(ActionIconGlyph.PrimaryButton("Comment", ActionIcon.Comment, async (_, _) =>
        {
            if (string.IsNullOrWhiteSpace(comment.Text)) return;
            await WriteAsync("pulls.comment", number, new JsonObject { ["body"] = comment.Text.Trim() });
            await ShowDetailAsync(number, true);
        }));
        composerActions.Children.Add(ActionIconGlyph.Button("Approve", ActionIcon.Approve, async (_, _) =>
        {
            await WriteAsync("pulls.review", number, new JsonObject
            {
                ["verdict"] = "approve", ["body"] = comment.Text.Trim(),
            });
            await ShowDetailAsync(number, true);
        }));
        composerActions.Children.Add(ActionIconGlyph.Button("Request changes", ActionIcon.Comment, async (_, _) =>
        {
            if (string.IsNullOrWhiteSpace(comment.Text))
            {
                _root.Children.Insert(1, Chrome.Banner(
                    "Say what needs to change before requesting changes.",
                    Theme.Warning,
                    Symbol.Important));
                return;
            }
            await WriteAsync("pulls.review", number, new JsonObject
            {
                ["verdict"] = "requestChanges", ["body"] = comment.Text.Trim(),
            });
            await ShowDetailAsync(number, true);
        }));
        composer.Children.Add(composerActions);
        stack.Children.Add(Chrome.Card("Join the conversation", composer));
        return new ScrollViewer { MaxHeight = 600, Content = stack };
    }

    private static Grid LazyDiff()
    {
        // A spinner alone reads as frozen. The pulsing rows say what shape
        // the diff lands in.
        var progress = new ProgressRing
        {
            IsActive = true,
            Width = 28,
            Height = 28,
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        var stack = new StackPanel
        {
            Spacing = Theme.SpaceM,
            Padding = new Thickness(0, Theme.SpaceM, 0, Theme.SpaceM),
            Children = { progress, Motion.SkeletonRows(4) },
        };
        return new Grid { MinHeight = 260, Tag = null, Children = { stack } };
    }

    private async Task LoadDiffAsync(Grid holder, long number)
    {
        try
        {
            var response = await CallPullsAsync("pulls.diff", new JsonObject
            {
                ["workspaceId"] = _workspaceId, ["number"] = number,
            });
            var files = response as JsonArray;
            var stack = new StackPanel { Spacing = Theme.SpaceM, Padding = new Thickness(0, Theme.SpaceM, 0, Theme.SpaceM) };
            foreach (var file in files ?? new JsonArray())
            {
                if (file is null) continue;
                var lines = new StackPanel { Spacing = 0 };
                foreach (var hunk in file["hunks"] as JsonArray ?? new JsonArray())
                {
                    if (hunk is null) continue;
                    lines.Children.Add(DiffLine(Format.Text(hunk, "header"), Theme.AccentSoft));
                    foreach (var line in hunk["lines"] as JsonArray ?? new JsonArray())
                    {
                        if (line is null) continue;
                        var kind = Format.Text(line, "kind", "context");
                        var prefix = kind == "added" ? "+" : kind == "removed" ? "−" : " ";
                        var tint = kind == "added" ? Theme.AccentSoft
                            : kind == "removed" ? ColorFrom(Theme.Danger, 24)
                            : Theme.Panel;
                        lines.Children.Add(DiffLine(prefix + Format.Text(line, "text"), tint));
                    }
                }
                stack.Children.Add(Chrome.Card(Format.Text(file, "path"), lines));
            }
            if (stack.Children.Count == 0)
            {
                stack.Children.Add(Chrome.Empty("No text changes", "This pull request has no line-by-line diff to show.", ActionIcon.Compare));
            }
            holder.Children.Clear();
            holder.Children.Add(new ScrollViewer { MaxHeight = 620, Content = stack });
        }
        catch (Exception ex)
        {
            holder.Children.Clear();
            holder.Children.Add(Chrome.Banner(ex.Message, Theme.Warning, Symbol.Important));
        }
    }

    private static UIElement DiffLine(string text, Windows.UI.Color background) => new Border
    {
        Background = Theme.Brush(background),
        Padding = new Thickness(10, 3, 10, 3),
        Child = new TextBlock
        {
            Text = text,
            FontFamily = Fonts.Mono,
            FontSize = 12,
            IsTextSelectionEnabled = true,
        },
    };

    private static UIElement Checks(JsonNode detail)
    {
        var stack = new StackPanel { Spacing = Theme.SpaceS, Padding = new Thickness(0, Theme.SpaceM, 0, Theme.SpaceM) };
        foreach (var check in detail["checks"] as JsonArray ?? new JsonArray())
        {
            if (check is null) continue;
            var state = Format.Text(check, "state", "pending");
            var tint = state == "passing" ? Theme.Success : state == "failing" ? Theme.Danger : Theme.Warning;
            stack.Children.Add(Chrome.Banner(
                $"{Format.Text(check, "name", "Check")} · {state}", tint,
                state == "passing" ? Symbol.Accept : state == "failing" ? Symbol.Cancel : Symbol.Clock));
        }
        if (stack.Children.Count == 0)
        {
            stack.Children.Add(Chrome.Empty("No checks reported", "The head commit does not publish a check suite.", ActionIcon.Done));
        }
        return new ScrollViewer { MaxHeight = 600, Content = stack };
    }

    private UIElement ActionPanel(JsonNode detail, long number)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        var url = Format.Text(detail, "url");
        if (!string.IsNullOrEmpty(url))
            row.Children.Add(ActionIconGlyph.Button("Open on GitHub", ActionIcon.External, (_, _) => Open(url)));
        row.Children.Add(ActionIconGlyph.Button("Checkout", ActionIcon.Checkout, async (_, _) => await CheckoutAsync(detail, number)));
        if (Format.Flag(detail, "draft"))
            row.Children.Add(ActionIconGlyph.Button("Mark ready", ActionIcon.Approve, async (_, _) => await ConfirmWriteAsync("Mark this pull request ready?", "pulls.ready", number)));
        var state = Format.Text(detail, "state", "open");
        if (state == "open")
        {
            row.Children.Add(ActionIconGlyph.Button("Close", ActionIcon.CancelPlan, async (_, _) => await ConfirmWriteAsync("Close this pull request?", "pulls.close", number)));
            row.Children.Add(ActionIconGlyph.PrimaryButton("Merge", ActionIcon.Merge, async (_, _) => await MergeAsync(number)));
        }
        else if (state == "closed")
            row.Children.Add(ActionIconGlyph.Button("Reopen", ActionIcon.Reopen, async (_, _) => await ConfirmWriteAsync("Reopen this pull request?", "pulls.reopen", number)));
        return Chrome.Card("Actions", row, "Shared repository changes happen only after a labelled press.");
    }

    private async Task CheckoutAsync(JsonNode detail, long number)
    {
        var branch = new TextBox { Text = Format.Text(detail, "headRef"), MinWidth = 280 };
        var dialog = new ContentDialog
        {
            Title = "Checkout pull request",
            Content = branch,
            PrimaryButtonText = "Checkout",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await Chrome.ShowDialog(this, dialog) != ContentDialogResult.Primary) return;
        try
        {
            var outcome = await CallPullsAsync("pulls.checkout", new JsonObject
            {
                ["workspaceId"] = _workspaceId, ["number"] = number, ["branch"] = branch.Text.Trim(),
            });
            var ok = Format.Flag(outcome, "ok");
            _root.Children.Insert(1, Chrome.Banner(
                Format.Text(outcome, "message", ok ? "Checked out." : "Checkout failed."),
                ok ? Theme.Success : Theme.Warning,
                ok ? Symbol.Accept : Symbol.Important));
        }
        catch (Exception ex) { _root.Children.Insert(1, Chrome.Banner(ex.Message, Theme.Warning, Symbol.Important)); }
    }

    private async Task MergeAsync(long number)
    {
        var method = new ComboBox { ItemsSource = new[] { "Merge commit", "Squash", "Rebase" }, SelectedIndex = 0, MinWidth = 220 };
        var dialog = new ContentDialog
        {
            Title = "Merge pull request?",
            Content = method,
            PrimaryButtonText = "Merge",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await Chrome.ShowDialog(this, dialog) != ContentDialogResult.Primary) return;
        var values = new[] { "merge", "squash", "rebase" };
        await WriteAsync("pulls.merge", number, new JsonObject { ["mergeMethod"] = values[Math.Max(0, method.SelectedIndex)] });
        await ShowDetailAsync(number, true);
    }

    private async Task ConfirmWriteAsync(string title, string method, long number)
    {
        var dialog = new ContentDialog
        {
            Title = title,
            PrimaryButtonText = "Continue",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
        };
        if (await Chrome.ShowDialog(this, dialog) != ContentDialogResult.Primary) return;
        await WriteAsync(method, number, new JsonObject());
        await ShowDetailAsync(number, true);
    }

    private async Task WriteAsync(string method, long number, JsonObject extra)
    {
        extra["workspaceId"] = _workspaceId;
        extra["number"] = number;
        await CallPullsAsync(method, extra);
    }

    private static Windows.UI.Color StateTint(string state, bool draft) => draft
        ? Theme.StateIdle
        : state == "merged" ? Theme.Secondary
        : state == "closed" ? Theme.Danger
        : Theme.Accent;

    private static Windows.UI.Color ColorFrom(Windows.UI.Color tint, byte alpha) =>
        Windows.UI.Color.FromArgb(alpha, tint.R, tint.G, tint.B);

    private static string SourceLabel(string source) => source switch
    {
        "gitCredential" => "using Git's saved credential",
        "environment" => "using the shell credential",
        "pasted" => "using a token you supplied",
        _ => "tokenstat GitHub App",
    };

    private static string TimelineTitle(string actor, string kind) => kind switch
    {
        "commented" => actor + " commented",
        "reviewed" => actor + " reviewed",
        "committed" => actor + " committed",
        _ => actor,
    };

    private static string TimelineSentence(string kind) => kind switch
    {
        "readyForReview" => "Marked this pull request ready for review.",
        "merged" => "Merged this pull request.",
        "closed" => "Closed this pull request.",
        "reopened" => "Reopened this pull request.",
        _ => "Updated this pull request.",
    };

    private static void Open(string url)
    {
        try { Process.Start(new ProcessStartInfo { FileName = url, UseShellExecute = true }); }
        catch { }
    }
}
