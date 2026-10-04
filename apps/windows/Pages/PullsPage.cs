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
        _scope.ItemsSource = new[] { L10n.Text("windows.pullspage.all.a52ace42"), L10n.Text("windows.pullspage.mine.f57afb7d"), L10n.Text("windows.pullspage.assigned.8191888d"), L10n.Text("windows.pullspage.review_requested.744f7028") };
        _scope.SelectedIndex = 0;
        _state.ItemsSource = new[] { L10n.Text("common.open"), L10n.Text("windows.pullspage.merged.bd0a0620"), L10n.Text("windows.pullspage.closed.c21ead06"), L10n.Text("windows.pullspage.draft.ebf12ef4") };
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
        Chrome.ScopeChip(string.IsNullOrEmpty(_folderName) ? L10n.Text("windows.pullspage.pull_requests.d9e3f260") : _folderName);

    public IList<UIElement> ToolbarActions()
    {
        return new List<UIElement>
        {
            Buttons.ToolbarIcon(
                ActionIcon.Refresh,
                L10n.Text("windows.pullspage.reload_pull_requests.d07529a2"),
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
                L10n.Text("windows.pullspage.state.a3b50c47"),
                Format.Flag(detail, "draft")
                    ? L10n.Text("windows.pullspage.draft.ebf12ef4")
                    : Format.Text(detail, "state", "open")));
            _inspector.Children.Add(Chrome.InspectorField(
                L10n.Text("windows.pullspage.branch.52656e81"),
                $"{Format.Text(detail, "headRef")} → {Format.Text(detail, "baseRef")}"));
            _inspector.Children.Add(Chrome.InspectorField(
                L10n.Text("windows.pullspage.changes.bbd4b6a8"),
                $"+{Format.Long(detail, "additions")} −{Format.Long(detail, "deletions")}"));
            _inspector.Children.Add(Chrome.InspectorField(
                L10n.Text("common.files"), $"{Format.Long(detail, "changedFiles")}"));
            var checks = detail["checks"] as JsonArray;
            _inspector.Children.Add(Chrome.InspectorField(L10n.Text("windows.pullspage.checks.de07d072"), $"{checks?.Count ?? 0}"));
            return;
        }
        _inspector.Children.Add(new TextBlock
        {
            Text = L10n.Text("windows.pullspage.pull_requests.d9e3f260"),
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        if (!string.IsNullOrEmpty(_repo))
        {
            _inspector.Children.Add(Chrome.InspectorField(L10n.Text("windows.pullspage.repository.13d6ff07"), _repo));
        }
        if (!string.IsNullOrEmpty(_login))
        {
            _inspector.Children.Add(Chrome.InspectorField(L10n.Text("windows.pullspage.connected.22965568"), "@" + _login, SourceLabel(_source)));
        }
        _inspector.Children.Add(new TextBlock
        {
            Text = _listCount == 0
                ? L10n.Text("windows.pullspage.nothing_listed_under_these_filters.d5f659c5")
                : L10n.Text("windows.pullspage.0_1_listed.6a7bf1bb", $"{_listCount}", $"{(_listCount == 1 ? L10n.Text("windows.pullspage.pull_request.763fae51") : L10n.Text("windows.pullspage.pull_requests.dcf2de55"))}"),
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
        _root.Children.Add(Header(L10n.Text("windows.pullspage.review_the_work_around_this_branch.4ca99549")));
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
                        Format.Text(availability, "repo", L10n.Text("windows.pullspage.pull_requests.d9e3f260")));
                    _root.Children.Add(ConnectionLine(availability));
                    _root.Children.Add(ActionIconGlyph.PrimaryButton(L10n.Text("windows.pullcreate.new"), ActionIcon.Create, async (_, _) =>
                    {
                        await WorkspacePullCreate.ShowAsync(this, _workspaceId, _folderName, CallPullsAsync);
                        await LoadAsync(true);
                    }));
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
                        L10n.Text("windows.pullspage.this_folder_is_not_a_git_repository.a1da5b0e"),
                        L10n.Text("windows.pullspage.pull_requests_appear_for_folders_with_a_gi.33e92947"),
                        ActionIcon.Merge));
                    break;
                case "noRemote":
                    _root.Children.Add(Chrome.Empty(
                        L10n.Text("windows.pullspage.no_github_origin_yet.0478e3f8"),
                        L10n.Text("windows.pullspage.add_an_origin_remote_to_this_repository_th.1e168c71"),
                        ActionIcon.Merge));
                    break;
                default:
                    _root.Children.Add(Chrome.Empty(
                        L10n.Text("windows.pullspage.pull_requests_are_unavailable.086a162b"),
                        L10n.Text("windows.pullspage.refresh_to_ask_that_computer_again.2549ff1a"),
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
            Text = L10n.Text("windows.pullspage.pull_requests.d9e3f260"),
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
                    LabeledControl(L10n.Text("windows.pullspage.scope.b073f6c6"), _scope),
                    LabeledControl(L10n.Text("windows.pullspage.state.a3b50c47"), _state),
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
                L10n.Text("windows.pullspage.no_0_pull_requests.980f0d9c", $"{states[Math.Max(0, _state.SelectedIndex)]}"),
                L10n.Text("windows.pullspage.nothing_in_this_repository_matches_the_sel.667ebd03"),
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
            Text = L10n.Text("windows.pullspage.0_1_2_files_3_comments.d4b8ddd5", $"{Format.Long(pull, "additions")}", $"{Format.Long(pull, "deletions")}", $"{Format.Long(pull, "changedFiles")}", $"{Format.Long(pull, "comments")}"),
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
            Text = L10n.Text("windows.pullspage.read_the_conversation_inspect_the_same_dif.a163d47d"),
            TextWrapping = TextWrapping.Wrap,
            Opacity = 0.74,
        });
        body.Children.Add(ActionIconGlyph.PrimaryButton(
            L10n.Text("windows.pullspage.connect_github.4027e5b2"), ActionIcon.Connect, async (_, _) => await StartLoginAsync()));
        return Chrome.Card(L10n.Text("windows.pullspage.bring_the_review_into_tokenstat.124ca7d8"), body);
    }

    private UIElement AccessCard(JsonNode availability, string state)
    {
        var body = new StackPanel { Spacing = Theme.SpaceM };
        body.Children.Add(new TextBlock
        {
            Text = state == "needsInstallation"
                ? L10n.Text("windows.pullspage.choose_the_repositories_tokenstat_may_open.367af525")
                : L10n.Text("windows.pullspage.the_connection_works_but_this_repository_i.ac88cdf2"),
            TextWrapping = TextWrapping.Wrap,
            Opacity = 0.74,
        });
        var url = Format.Text(availability, "installUrl");
        if (!string.IsNullOrEmpty(url))
        {
            body.Children.Add(ActionIconGlyph.PrimaryButton(
                L10n.Text("windows.pullspage.choose_repositories.df6de593"), ActionIcon.External, (_, _) => Open(url)));
        }
        return Chrome.Card(L10n.Text("windows.pullspage.grant_repository_access.a46c65fe"), body, L10n.Text("windows.pullspage.only_repositories_selected_for_the_github.beb8f49c"));
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
                    ? L10n.Text("windows.pullspage.complete_the_connection_in_your_browser.a8e8f600")
                    : L10n.Text("windows.pullspage.enter_0_in_the_github_page_that_just_opene.69c61db4", $"{code}"),
                Theme.Accent,
                Symbol.Contact));
            _loginPoll = new CancellationTokenSource();
            _root.Children.Insert(2, ActionIconGlyph.Button(
                L10n.Text("windows.pullspage.cancel_sign_in.9effa0b7"), ActionIcon.Dismiss, async (_, _) => await CancelLoginAsync()));
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
        chrome.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.pullspage.pull_requests.d9e3f260"), ActionIcon.Back, async (_, _) => await LoadAsync()));
        chrome.Children.Add(ActionIconGlyph.Button(L10n.Text("common.refresh"), ActionIcon.Refresh, async (_, _) => await ShowDetailAsync(number, true)));
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
                Header = L10n.Text("windows.pullspage.conversation.ccca1817"),
                IsClosable = false,
                Content = Conversation(detail, timeline, number),
            });
            tabs.TabItems.Add(new TabViewItem
            {
                Header = L10n.Text("windows.pullspage.changes_0.eb1957f0", $"{Format.Long(detail, "changedFiles")}"),
                IsClosable = false,
                Content = LazyDiff(),
            });
            tabs.TabItems.Add(new TabViewItem
            {
                Header = L10n.Text("windows.pullspage.checks_0.22b4d740", $"{(detail["checks"] as JsonArray)?.Count ?? 0}"),
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
            Text = L10n.Text("windows.pullspage.0_opened_1.0dd2dd2e", $"{Format.Text(actor, "login")}", $"{Format.Long(detail, "number")}"),
            Opacity = 0.68,
        });
        body.Children.Add(new TextBlock
        {
            Text = L10n.Text("windows.pullspage.0_1_2_3_4_files.5fc1c874", $"{Format.Text(detail, "headRef")}", $"{Format.Text(detail, "baseRef")}", $"{Format.Long(detail, "additions")}", $"{Format.Long(detail, "deletions")}", $"{Format.Long(detail, "changedFiles")}"),
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
            Format.Text(detail["author"], "login", L10n.Text("windows.pullspage.author.d95082a2")),
            new TextBlock
            {
                Text = string.IsNullOrWhiteSpace(description) ? L10n.Text("windows.pullspage.no_description_was_added.68442d50") : description,
                TextWrapping = TextWrapping.Wrap,
                IsTextSelectionEnabled = true,
                Opacity = string.IsNullOrWhiteSpace(description) ? 0.6 : 1,
            }));
        foreach (var entry in Format.Items(timeline, "events") ?? new JsonArray())
        {
            if (entry is null) continue;
            var actor = Format.Text(entry["actor"], "login", L10n.Text("windows.pullspage.someone.864c855e"));
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
            PlaceholderText = L10n.Text("windows.pullspage.add_to_the_conversation.c38f0aa8"),
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            MinHeight = 96,
        };
        var composer = new StackPanel { Spacing = Theme.SpaceS };
        composer.Children.Add(comment);
        var composerActions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        composerActions.Children.Add(ActionIconGlyph.PrimaryButton(L10n.Text("windows.pullspage.comment.44f5e3fb"), ActionIcon.Comment, async (_, _) =>
        {
            if (string.IsNullOrWhiteSpace(comment.Text)) return;
            await WriteAsync("pulls.comment", number, new JsonObject { ["body"] = comment.Text.Trim() });
            await ShowDetailAsync(number, true);
        }));
        composerActions.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.pullspage.approve.6007acbe"), ActionIcon.Approve, async (_, _) =>
        {
            await WriteAsync("pulls.review", number, new JsonObject
            {
                ["verdict"] = "approve", ["body"] = comment.Text.Trim(),
            });
            await ShowDetailAsync(number, true);
        }));
        composerActions.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.pullspage.request_changes.cb5d9f98"), ActionIcon.Comment, async (_, _) =>
        {
            if (string.IsNullOrWhiteSpace(comment.Text))
            {
                _root.Children.Insert(1, Chrome.Banner(
                    L10n.Text("windows.pullspage.say_what_needs_to_change_before_requesting.24b6014c"),
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
        stack.Children.Add(Chrome.Card(L10n.Text("windows.pullspage.join_the_conversation.a0a9b316"), composer));
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
                stack.Children.Add(Chrome.Empty(L10n.Text("windows.pullspage.no_text_changes.08722a9e"), L10n.Text("windows.pullspage.this_pull_request_has_no_line_by_line_diff.680bf131"), ActionIcon.Compare));
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
                $"{Format.Text(check, "name", L10n.Text("windows.pullspage.check.9d60841e"))} · {state}", tint,
                state == "passing" ? Symbol.Accept : state == "failing" ? Symbol.Cancel : Symbol.Clock));
        }
        if (stack.Children.Count == 0)
        {
            stack.Children.Add(Chrome.Empty(L10n.Text("windows.pullspage.no_checks_reported.8454518f"), L10n.Text("windows.pullspage.the_head_commit_does_not_publish_a_check_s.3a467ede"), ActionIcon.Done));
        }
        return new ScrollViewer { MaxHeight = 600, Content = stack };
    }

    private UIElement ActionPanel(JsonNode detail, long number)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        var url = Format.Text(detail, "url");
        if (!string.IsNullOrEmpty(url))
            row.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.pullspage.open_on_github.03f69885"), ActionIcon.External, (_, _) => Open(url)));
        row.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.pullspage.checkout.99e71f48"), ActionIcon.Checkout, async (_, _) => await CheckoutAsync(detail, number)));
        if (Format.Flag(detail, "draft"))
            row.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.pullspage.mark_ready.6bb3f90b"), ActionIcon.Approve, async (_, _) => await ConfirmWriteAsync(L10n.Text("windows.pullspage.mark_this_pull_request_ready.be4a94ce"), "pulls.ready", number)));
        var state = Format.Text(detail, "state", "open");
        if (state == "open")
        {
            row.Children.Add(ActionIconGlyph.Button(L10n.Text("common.close"), ActionIcon.CancelPlan, async (_, _) => await ConfirmWriteAsync(L10n.Text("windows.pullspage.close_this_pull_request.54b5c0b1"), "pulls.close", number)));
            row.Children.Add(ActionIconGlyph.PrimaryButton(L10n.Text("windows.pullspage.merge.8851aaa7"), ActionIcon.Merge, async (_, _) => await MergeAsync(number)));
        }
        else if (state == "closed")
            row.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.pullspage.reopen.a886d1dc"), ActionIcon.Reopen, async (_, _) => await ConfirmWriteAsync(L10n.Text("windows.pullspage.reopen_this_pull_request.f7945627"), "pulls.reopen", number)));
        return Chrome.Card(L10n.Text("windows.pullspage.actions.ff8059dc"), row, L10n.Text("windows.pullspage.shared_repository_changes_happen_only_afte.a0dfb107"));
    }

    private async Task CheckoutAsync(JsonNode detail, long number)
    {
        var branch = new TextBox { Text = Format.Text(detail, "headRef"), MinWidth = 280 };
        var dialog = new ContentDialog
        {
            Title = L10n.Text("windows.pullspage.checkout_pull_request.89f37076"),
            Content = branch,
            PrimaryButtonText = L10n.Text("windows.pullspage.checkout.99e71f48"),
            CloseButtonText = L10n.Text("common.cancel"),
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
                Format.Text(outcome, "message", ok ? L10n.Text("windows.pullspage.checked_out.0f450a04") : L10n.Text("windows.pullspage.checkout_failed.ccd97c13")),
                ok ? Theme.Success : Theme.Warning,
                ok ? Symbol.Accept : Symbol.Important));
        }
        catch (Exception ex) { _root.Children.Insert(1, Chrome.Banner(ex.Message, Theme.Warning, Symbol.Important)); }
    }

    private async Task MergeAsync(long number)
    {
        var method = new ComboBox { ItemsSource = new[] { L10n.Text("windows.pullspage.merge_commit.8e9d44a6"), L10n.Text("windows.pullspage.squash.9f9a8456"), L10n.Text("windows.pullspage.rebase.9eb5b275") }, SelectedIndex = 0, MinWidth = 220 };
        var dialog = new ContentDialog
        {
            Title = L10n.Text("windows.pullspage.merge_pull_request.a17cd5dc"),
            Content = method,
            PrimaryButtonText = L10n.Text("windows.pullspage.merge.8851aaa7"),
            CloseButtonText = L10n.Text("common.cancel"),
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
            PrimaryButtonText = L10n.Text("windows.pullspage.continue.31fbef16"),
            CloseButtonText = L10n.Text("common.cancel"),
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
        "gitCredential" => L10n.Text("windows.pullspage.using_git_s_saved_credential.0e9c75dd"),
        "environment" => L10n.Text("windows.pullspage.using_the_shell_credential.f587050a"),
        "pasted" => L10n.Text("windows.pullspage.using_a_token_you_supplied.40e06d38"),
        _ => L10n.Text("windows.pullspage.tokenstat_github_app.4545f151"),
    };

    private static string TimelineTitle(string actor, string kind) => kind switch
    {
        "commented" => actor + L10n.Text("windows.pullspage.commented.70aa99ac"),
        "reviewed" => actor + L10n.Text("windows.pullspage.reviewed.f026d217"),
        "committed" => actor + L10n.Text("windows.pullspage.committed.be720d21"),
        _ => actor,
    };

    private static string TimelineSentence(string kind) => kind switch
    {
        "readyForReview" => L10n.Text("windows.pullspage.marked_this_pull_request_ready_for_review.a50f4b42"),
        "merged" => L10n.Text("windows.pullspage.merged_this_pull_request.07969d08"),
        "closed" => L10n.Text("windows.pullspage.closed_this_pull_request.ec9188a9"),
        "reopened" => L10n.Text("windows.pullspage.reopened_this_pull_request.232c0bb1"),
        _ => L10n.Text("windows.pullspage.updated_this_pull_request.88c34d43"),
    };

    private static void Open(string url)
    {
        try { Process.Start(new ProcessStartInfo { FileName = url, UseShellExecute = true }); }
        catch { }
    }
}
