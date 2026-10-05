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
using Microsoft.UI.Xaml.Media;
using Tokenstat.Design;
using Tokenstat.Navigation;

namespace Tokenstat.Pages;

internal sealed class WorkspacePage : Page, IInspectorContent, IToolbarItems
{
    private const int HugeChars = 200_000;

    private readonly string _id;
    private readonly WorkspaceSection _section;

    /// <summary>Which section this page shows, so the tab bar knows the launcher.</summary>
    internal WorkspaceSection Section => _section;
    private readonly StackPanel _root = new() { Spacing = Theme.SpaceL };
    private readonly StackPanel _inspector = new()
    {
        Spacing = Theme.SpaceM,
        Padding = new Thickness(Theme.SpaceM),
    };
    private readonly StackPanel _sessionsHost = new() { Spacing = Theme.SpaceS };
    private string _path = "";
    private string _folderName = "";
    private string _branch = "";
    private string _summary = "";
    private DispatcherQueueTimer? _sessionsPoll;
    private bool _sessionsLoading;
    private bool _showingLauncherCatalog;
    private string? _reviewPath;
    private bool _loading;
    private bool _reloadRequested;

    /// <summary>
    /// A chat's file row opens the current diff beside the conversation. The
    /// card is pinned by the next load only, so a later push, pull or refresh
    /// does not fetch that diff again or keep it at the top.
    /// </summary>
    public void RevealChangedFile(string? path)
    {
        _reviewPath = path;
        if (IsLoaded) _ = LoadAsync();
    }

    public WorkspacePage(string id, WorkspaceSection section)
    {
        _id = id;
        _section = section;
        Content = new ScrollViewer
        {
            Padding = new Thickness(Theme.SpaceM),
            Content = _root,
        };
        RenderInspector();
        Loaded += async (_, _) => await LoadAsync();
        Unloaded += (_, _) => StopSessionsPoll();
    }

    public event Action? ToolbarChanged;

    /// <summary>
    /// The folder this section belongs to.
    /// </summary>
    public UIElement? ToolbarScope =>
        Chrome.ScopeChip(string.IsNullOrEmpty(_folderName) ? _section.Label() : _folderName);

    public IList<UIElement> ToolbarActions()
    {
        return new List<UIElement>
        {
            Buttons.ToolbarIcon(
                ActionIcon.Refresh,
                L10n.Text("windows.workspacepage.reload_0.91253a23", $"{_section.Label().ToLowerInvariant()}"),
                async (_, _) =>
                {
                    LogoRefresh.Began();
                    await LoadAsync();
                }),
        };
    }

    private void RaiseToolbarChanged() => ToolbarChanged?.Invoke();

    /// <summary>
    /// The inspector column content: which folder is on screen, its branch,
    /// and a one line summary of the section. Reloads replace its children,
    /// so the column stays live without the shell asking again.
    /// </summary>
    public UIElement? Inspector => _inspector;

    private void RenderInspector()
    {
        _inspector.Children.Clear();
        _inspector.Children.Add(new TextBlock
        {
            Text = _section.Label(),
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        if (!string.IsNullOrEmpty(_folderName))
        {
            _inspector.Children.Add(new TextBlock
            {
                Text = _folderName,
                Opacity = 0.7,
                TextWrapping = TextWrapping.Wrap,
            });
        }
        if (!string.IsNullOrEmpty(_branch))
        {
            _inspector.Children.Add(Chrome.InspectorField(L10n.Text("windows.workspacepage.branch.52656e81"), WorkspaceGit.ShortBranch(_branch)));
        }
        if (!string.IsNullOrEmpty(_summary))
        {
            _inspector.Children.Add(new TextBlock
            {
                Text = _summary,
                Opacity = 0.7,
                TextWrapping = TextWrapping.Wrap,
            });
        }
    }

    /// <summary>
    /// Loads build straight into <c>_root</c> across awaits, so two at once
    /// would interleave their rows. A request during a load runs once that
    /// load ends instead.
    /// </summary>
    private async Task LoadAsync()
    {
        if (_loading)
        {
            _reloadRequested = true;
            return;
        }
        _loading = true;
        try
        {
            do
            {
                _reloadRequested = false;
                await LoadOnceAsync();
            }
            while (_reloadRequested);
        }
        finally
        {
            _loading = false;
        }
    }

    private async Task LoadOnceAsync()
    {
        _root.Children.Clear();
        _summary = "";
        if (_section != WorkspaceSection.Sessions)
        {
            StopSessionsPoll();
        }
        _root.Children.Add(new TextBlock
        {
            Text = _section.Label(),
            FontSize = 18,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        var skeleton = Motion.SkeletonCard();
        _root.Children.Add(skeleton);
        _folderName = await FolderNameAsync();
        RaiseToolbarChanged();
        RenderInspector();
        try
        {
            switch (_section)
            {
                case WorkspaceSection.Files:
                    await LoadFilesAsync();
                    break;
                case WorkspaceSection.Changes:
                    await LoadChangesAsync();
                    break;
                case WorkspaceSection.Todo:
                    await LoadTodoAsync();
                    break;
                case WorkspaceSection.Launcher:
                case WorkspaceSection.Sessions:
                    await LoadLauncherAsync();
                    break;
                case WorkspaceSection.Browser:
                    await LoadBrowserAsync();
                    break;
                default:
                    if (RemoteWorkspaces.IsRemote(_id))
                    {
                        _root.Children.Add(Chrome.Empty(
                            _section.Label() + L10n.Text("windows.workspacepage.is_local_for_now.d30635a4"),
                            L10n.Text("windows.workspacepage.this_folder_lives_on_another_machine_and_0.43cf4ce1", $"{_section.Label().ToLowerInvariant()}"),
                            ActionIcon.Reveal));
                        break;
                    }
                    _root.Children.Add(Chrome.Empty(
                        _section.Label() + L10n.Text("windows.workspacepage.on_windows.c6bb28b6"),
                        L10n.Text("windows.workspacepage.the_mac_app_has_the_full_0_surface_this_bu.eb18e4f0", $"{_section.Label().ToLowerInvariant()}"),
                        ActionIcon.Reveal));
                    break;
            }
            _root.Children.Remove(skeleton);
        }
        catch (Exception ex)
        {
            _root.Children.Remove(skeleton);
            _root.Children.Add(Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important));
        }
    }

    private async Task LoadFilesAsync()
    {
        var chrome = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Theme.SpaceS,
        };
        if (_path.Length > 0)
        {
            chrome.Children.Add(ActionIconGlyph.Button(L10n.Text("common.back"), ActionIcon.Back, async (_, _) =>
            {
                _path = ParentPath(_path);
                await LoadAsync();
            }));
        }
        chrome.Children.Add(new TextBlock
        {
            Text = _path.Length == 0 ? L10n.Text("windows.workspacepage.project_root.f85c5ef5") : _path,
            VerticalAlignment = VerticalAlignment.Center,
            Opacity = 0.7,
            TextWrapping = TextWrapping.Wrap,
        });
        _root.Children.Add(chrome);

        var tree = await RemoteWorkspaces.CallWorkspaceAsync(
            _id,
            "workspace.tree",
            new JsonObject { ["id"] = _id, ["path"] = _path });
        var array = tree as JsonArray ?? tree["entries"] as JsonArray;
        if (array is null || array.Count == 0)
        {
            _root.Children.Add(EmptyState.View(L10n.Text("windows.workspacepage.empty_folder.ca1fd454"), L10n.Text("windows.workspacepage.nothing_to_list_here.1715efe9"), EmptyArtKind.Files));
            return;
        }

        _summary = _path.Length == 0
            ? L10n.Text("windows.workspacepage.0_1_at_the_project_root.16601378", $"{array.Count}", $"{(array.Count == 1 ? L10n.Text("windows.workspacepage.entry.923fe539") : L10n.Text("windows.workspacepage.entries.87d05cd0"))}")
            : $"{array.Count} {(array.Count == 1 ? "entry" : "entries")} in {_path}.";
        RenderInspector();
        var list = new StackPanel { Spacing = 4 };
        foreach (var entry in array)
        {
            var name = Format.Text(entry, "name", Format.Text(entry, "path"));
            var entryPath = Format.Text(entry, "path", name);
            var dir = Format.Flag(entry, "isDir") || Format.Flag(entry, "dir");
            var ignored = Format.Flag(entry, "ignored");
            var open = new Button
            {
                Content = (dir ? "▸ " : "") + name,
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Left,
                Opacity = ignored ? 0.55 : 1,
            };
            var capturedPath = entryPath;
            var capturedDir = dir;
            var capturedName = name;
            open.Click += async (_, _) =>
            {
                if (capturedDir)
                {
                    _path = capturedPath;
                    await LoadAsync();
                    return;
                }
                await OpenFileAsync(capturedPath, capturedName);
            };
            list.Children.Add(open);
        }
        _root.Children.Add(Chrome.Card(L10n.Text("common.files"), list));
    }

    private async Task OpenFileAsync(string path, string name)
    {
        JsonNode read;
        try
        {
            read = await RemoteWorkspaces.CallWorkspaceAsync(
                _id,
                "workspace.read",
                new JsonObject { ["id"] = _id, ["path"] = path });
        }
        catch (Exception ex)
        {
            _root.Children.Insert(1, Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important));
            return;
        }

        var content = Format.Text(read, "content");
        var huge = content.Length > HugeChars;
        var shown = huge ? content[..HugeChars] : content;
        var editor = new TextBox
        {
            Text = shown,
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            FontFamily = Fonts.Mono,
            IsReadOnly = huge,
            Height = 420,
            MinWidth = 640,
        };
        var body = new StackPanel { Spacing = Theme.SpaceS };
        if (huge)
        {
            body.Children.Add(new TextBlock
            {
                Text = L10n.Text("windows.workspacepage.this_file_is_too_large_to_edit_here_showin.f568e57f"),
                TextWrapping = TextWrapping.Wrap,
                Opacity = 0.8,
            });
        }
        body.Children.Add(editor);

        var dialog = new ContentDialog
        {
            Title = name,
            Content = body,
            CloseButtonText = huge ? L10n.Text("common.close") : L10n.Text("common.cancel"),
            DefaultButton = huge ? ContentDialogButton.Close : ContentDialogButton.Primary,
        };
        if (!huge)
        {
            dialog.PrimaryButtonText = L10n.Text("common.save");
        }
        if (await Chrome.ShowDialog(this, dialog) != ContentDialogResult.Primary || huge)
        {
            return;
        }
        try
        {
            var outcome = await RemoteWorkspaces.CallWorkspaceAsync(
                _id,
                "workspace.write",
                new JsonObject
                {
                    ["id"] = _id,
                    ["path"] = path,
                    ["content"] = editor.Text,
                });
            if (!OutcomeOk(outcome, out var message))
            {
                _root.Children.Insert(1, Chrome.Banner(message, Theme.Danger, Symbol.Important));
            }
        }
        catch (Exception ex)
        {
            _root.Children.Insert(1, Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important));
        }
    }

    private async Task LoadChangesAsync()
    {
        var status = await RemoteWorkspaces.CallWorkspaceAsync(
            _id,
            "workspace.status",
            new JsonObject { ["id"] = _id });
        var git = status["git"];
        var array = git?["files"] as JsonArray
            ?? status["files"] as JsonArray
            ?? status as JsonArray;
        var branch = Format.Text(git, "branch", Format.Text(status, "branch"));
        var upstream = Format.Text(git, "upstream", Format.Text(status, "upstream"));
        var ahead = Format.Long(git, "ahead");
        var behind = Format.Long(git, "behind");
        var folderName = _folderName;
        _branch = branch;
        var remote = RemoteWorkspaces.IsRemote(_id);

        if (!string.IsNullOrEmpty(branch))
        {
            // The branch switch and push dialogs route through the peer, so
            // a folder on another machine gets the same bar as a local one.
            var bar = BranchBar(branch, upstream, ahead, behind, folderName, null);
            _root.Children.Add(bar);
            // A forge timeout must not hold the file list or diff preview.
            _ = DecorateBranchBarAsync(bar, branch, upstream, ahead, behind, folderName);
        }

        var session = WorkspaceCommitSession.For(_id);
        var available = new List<string>();
        var reviewFiles = new List<(string Path, string Kind, long? Added, long? Removed)>();
        if (array is not null)
        {
            foreach (var entry in array)
            {
                var availablePath = Format.Text(entry, "path", Format.Text(entry, "name"));
                if (!string.IsNullOrEmpty(availablePath))
                {
                    available.Add(availablePath);
                    reviewFiles.Add((
                        availablePath,
                        Format.Text(entry, "kind", Format.Text(entry, "status")),
                        entry?["added"] is null ? null : Format.Long(entry, "added"),
                        entry?["removed"] is null ? null : Format.Long(entry, "removed")));
                }
            }
        }
        session.Reconcile(available);
        _summary = available.Count == 0
            ? L10n.Text("windows.workspacepage.a_clean_tree.dde03840")
            : L10n.Text("windows.workspacepage.0_changed_1_2_selected_for_the_next_commit.32bf5b80", $"{available.Count}", $"{(available.Count == 1 ? L10n.Text("windows.workspacepage.file.3b9c358f") : L10n.Text("windows.workspacepage.files.3d7db37d"))}", $"{session.SelectedCount}");
        RenderInspector();

        var reviewPath = _reviewPath;
        // A reload already queued behind this one would wipe the card, so it
        // keeps the path to pin again.
        if (!_reloadRequested) _reviewPath = null;
        if (reviewPath is string wanted)
        {
            wanted = wanted.Replace('\\', '/');
            var file = reviewFiles.OrderByDescending(file => file.Path.Length).FirstOrDefault(file =>
                wanted == file.Path.Replace('\\', '/') || wanted.EndsWith("/" + file.Path.Replace('\\', '/'), StringComparison.Ordinal));
            if (!string.IsNullOrEmpty(file.Path))
            {
                var diff = await LoadOneDiffAsync(file.Path);
                _root.Children.Add(Chrome.Card(file.Path, WorkspaceDiff.PreviewFile(this, file.Path, diff)));
            }
        }

        var selectionRow = new FlowPanel { Spacing = Theme.SpaceS };
        selectionRow.Children.Add(new TextBlock
        {
            Text = L10n.Text("windows.workspacepage.0_of_1_selected.d06c59a5", $"{session.SelectedCount}", $"{available.Count}"),
            VerticalAlignment = VerticalAlignment.Center,
            Opacity = 0.7,
        });
        selectionRow.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.workspacepage.select_all.1fc9a387"), ActionIcon.Apply, async (_, _) =>
        {
            session.SetAll(available);
            await LoadAsync();
        }));
        selectionRow.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.workspacepage.clear.83b12c22"), ActionIcon.Dismiss, async (_, _) =>
        {
            session.ClearSelection();
            await LoadAsync();
        }));
        if (!remote)
        {
            selectionRow.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.workspacepage.review_and_commit.96f097b7"), ActionIcon.Commit, async (_, _) =>
            {
                if (session.SelectedCount == 0)
                {
                    _root.Children.Insert(1, Chrome.Banner(
                        L10n.Text("windows.workspacepage.select_at_least_one_file_to_review.3ccd700d"),
                        Theme.Warning,
                        Symbol.Important));
                    return;
                }
                await WorkspaceCommitComposer.ShowAsync(this, _id, folderName, branch);
                await LoadAsync();
            }));
        }
        selectionRow.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.workspacepage.review_all.d05163fa"), ActionIcon.Compare, async (_, _) =>
        {
            if (reviewFiles.Count == 0)
            {
                _root.Children.Insert(1, Chrome.Banner(
                    L10n.Text("windows.workspacepage.no_changes_to_review.1f08cad6"),
                    Theme.Warning,
                    Symbol.Important));
                return;
            }
            await WorkspaceDiff.ShowReviewAllAsync(this, reviewFiles, LoadOneDiffAsync);
        }));
        if (available.Count > 0) _root.Children.Add(selectionRow);

        if (array is null || array.Count == 0)
        {
            var clean = string.IsNullOrEmpty(branch)
                ? L10n.Text("windows.workspacepage.no_uncommitted_changes_in_this_folder.9a39a402")
                : L10n.Text("windows.workspacepage.on_0_no_uncommitted_changes.59ef86e6", $"{branch}");
            _root.Children.Add(EmptyState.View(L10n.Text("windows.workspacepage.clean_tree.1cec0a42"), clean, EmptyArtKind.Changes));
            return;
        }

        var list = new StackPanel { Spacing = Theme.SpaceS };
        if (!string.IsNullOrEmpty(branch))
        {
            list.Children.Add(new TextBlock { Text = L10n.Text("windows.workspacepage.on_0.88d14a53", $"{branch}"), Opacity = 0.7 });
        }
        foreach (var entry in array)
        {
            var path = Format.Text(entry, "path", Format.Text(entry, "name"));
            var kind = Format.Text(entry, "kind", Format.Text(entry, "status"));
            if (string.IsNullOrEmpty(path))
            {
                continue;
            }
            var filePath = path;
            var line = new Grid();
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var check = new CheckBox
            {
                IsChecked = session.Paths.Contains(filePath),
                VerticalAlignment = VerticalAlignment.Center,
            };
            ToolTipService.SetToolTip(check, L10n.Text("windows.workspacepage.include_in_the_next_commit.5d7f428d"));
            check.Checked += async (_, _) =>
            {
                session.Select(filePath);
                await LoadAsync();
            };
            check.Unchecked += async (_, _) =>
            {
                session.Select(filePath);
                await LoadAsync();
            };
            line.Children.Add(check);
            var label = new TextBlock
            {
                Text = string.IsNullOrEmpty(kind) ? path : $"{WorkspaceGit.KindLabel(kind)} · {path}",
                TextWrapping = TextWrapping.Wrap,
                VerticalAlignment = VerticalAlignment.Center,
            };
            Grid.SetColumn(label, 1);
            line.Children.Add(label);
            var actions = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = Theme.SpaceS,
            };
            actions.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.workspacepage.stage.de838855"), ActionIcon.Apply, async (_, _) =>
            {
                var paths = new JsonArray { JsonValue.Create(filePath) };
                await GitwriteAsync("workspace.stage", new JsonObject
                {
                    ["id"] = _id,
                    ["paths"] = paths,
                });
            }));
            actions.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.workspacepage.unstage.033f86f9"), ActionIcon.Restore, async (_, _) =>
            {
                var paths = new JsonArray { JsonValue.Create(filePath) };
                await GitwriteAsync("workspace.unstage", new JsonObject
                {
                    ["id"] = _id,
                    ["paths"] = paths,
                });
            }));
            actions.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.workspacepage.diff.7ecf4628"), ActionIcon.Compare, async (_, _) =>
            {
                await ShowDiffAsync(filePath);
            }));
            Grid.SetColumn(actions, 2);
            line.Children.Add(actions);
            list.Children.Add(line);
        }
        _root.Children.Add(Chrome.Card(L10n.Text("windows.workspacepage.changes.bbd4b6a8"), list));

        if (remote)
        {
            _root.Children.Add(new TextBlock
            {
                Text = L10n.Text("windows.workspacepage.commits_for_this_folder_are_made_on_0_stag.e44b99b2", $"{(RemoteWorkspaces.CachedFolder(_id)?.MachineLabel is string machine
                        && !string.IsNullOrEmpty(machine) ? machine : L10n.Text("windows.workspacepage.that_machine.518ab459"))}"),
                Opacity = 0.7,
                FontSize = 12,
                TextWrapping = TextWrapping.Wrap,
            });
        }
        var history = remote
            ? await WorkspaceRemoteHistory.LoadCardAsync(this, _id)
            : await WorkspaceHistory.LoadCardAsync(this, _id);
        if (history is not null)
        {
            _root.Children.Add(history);
        }
    }

    private async Task DecorateBranchBarAsync(UIElement bar, string branch, string upstream, long ahead, long behind, string folderName)
    {
        var pull = await WorkspaceBranchPull.LoadAsync(_id, branch);
        var index = _root.Children.IndexOf(bar);
        if (IsLoaded && index >= 0 && pull is not null)
            _root.Children[index] = BranchBar(branch, upstream, ahead, behind, folderName, pull);
    }

    private async Task ShowDiffAsync(string filePath)
    {
        JsonNode? diff;
        try
        {
            diff = await RemoteWorkspaces.CallWorkspaceAsync(
                _id,
                "workspace.diff",
                new JsonObject { ["id"] = _id, ["path"] = filePath });
        }
        catch (Exception ex)
        {
            _root.Children.Add(Chrome.Banner(FriendlyError.Display(ex.Message), Theme.Danger, Symbol.Important));
            return;
        }
        await WorkspaceDiff.ShowFileDiffAsync(this, L10n.Text("windows.workspacepage.diff_0.4cfe00c5", $"{filePath}"), diff);
    }

    private async Task<JsonNode?> LoadOneDiffAsync(string path)
    {
        return await RemoteWorkspaces.CallWorkspaceAsync(
            _id,
            "workspace.diff",
            new JsonObject { ["id"] = _id, ["path"] = path });
    }

    private UIElement BranchBar(string current, string upstream, long ahead, long behind, string folderName, JsonNode? pull)
    {
        var label = WorkspaceGit.ShortBranch(current);
        if (ahead > 0)
        {
            label += $" ↑{ahead}";
        }
        if (behind > 0)
        {
            label += $" ↓{behind}";
        }
        // No leading icon: the switch button already carries the branch
        // glyph, and a second identical mark beside it reads as a dead button.
        var row = new FlowPanel { Spacing = Theme.SpaceS };
        var switchButton = ActionIconGlyph.Button(label, ActionIcon.Merge, async (_, _) =>
        {
            await WorkspaceBranches.ShowAsync(this, _id, current);
            await LoadAsync();
        });
        if (!string.IsNullOrEmpty(upstream))
        {
            ToolTipService.SetToolTip(switchButton, L10n.Text("windows.workspacepage.tracking_0.2e7aa60a", $"{upstream}"));
        }
        row.Children.Add(switchButton);
        row.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.gitpull.pull"), ActionIcon.Download, async (_, _) =>
        {
            await WorkspacePullDialog.ShowAsync(this, _id, folderName);
            await LoadAsync();
        }));
        row.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.workspacepage.push.731ce7ed"), ActionIcon.Upload, async (_, _) =>
        {
            await WorkspacePushDialog.ShowAsync(this, _id, folderName);
            await LoadAsync();
        }));
        if (WorkspaceBranchPull.Control(this, _id, folderName, pull, LoadAsync) is Button request)
            row.Children.Add(request);
        return new Border
        {
            Background = Theme.AccentSoftBrush,
            BorderBrush = Theme.BorderBrush,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(Theme.CardRadius),
            Padding = new Thickness(Theme.SpaceM),
            Child = row,
        };
    }

    private async Task GitwriteAsync(string method, JsonObject parameters)
    {
        try
        {
            var outcome = await RemoteWorkspaces.CallWorkspaceAsync(_id, method, parameters);
            if (!OutcomeOk(outcome, out var message))
            {
                _root.Children.Insert(1, Chrome.Banner(message, Theme.Danger, Symbol.Important));
                return;
            }
        }
        catch (Exception ex)
        {
            _root.Children.Insert(1, Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important));
            return;
        }
        await LoadAsync();
    }

    /// <summary>
    /// The launcher's one column, the Mac's width: what to open, the saved
    /// servers, then the agents. Everything shares the column so the servers
    /// line up with the tiles above and below them.
    /// </summary>
    private const double LauncherColumnWidth = 620;

    /// <summary>The Mac grid: tiles 150 to 200 wide, three to a row in the column.</summary>
    private const double LauncherTileMinWidth = 150;

    private async Task LoadLauncherAsync()
    {
        var column = new StackPanel
        {
            Spacing = Theme.SpaceM,
            MaxWidth = LauncherColumnWidth,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            Margin = new Thickness(0, Theme.SpaceM, 0, Theme.SpaceL),
        };
        _root.Children.Add(column);
        AddQuickActions(column);
        var servers = await ServerLauncher.CreateAsync(
            host => WorkspaceTabsPage.Find(this)?.OpenServerAsync(host) ?? Task.CompletedTask,
            () => AppServices.OpenServers?.Invoke());
        if (servers is FrameworkElement placed) placed.Margin = new Thickness(0, Theme.SpaceS, 0, 0);
        column.Children.Add(servers);
        await LoadSessionsAsync(column);
    }

    private void AddQuickActions(StackPanel column)
    {
        var mark = new FontIcon
        {
            Glyph = "\uF0E2", // GridView
            FontSize = 34,
            Foreground = Theme.AccentBrush,
            Opacity = 0.65,
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, Theme.SpaceM, 0, 0),
        };
        column.Children.Add(mark);
        column.Children.Add(new TextBlock
        {
            Text = L10n.Text("windows.workspacepage.what_do_you_want_to_do_in_0.d6c232de", $"{_folderName}"),
            TextAlignment = TextAlignment.Center, FontSize = 20, FontWeight = Microsoft.UI.Text.FontWeights.Medium,
            TextWrapping = TextWrapping.Wrap,
        });
        column.Children.Add(new TextBlock
        {
            Text = L10n.Text("windows.workspacepage.open_the_project_where_you_left_it_or_star.4f0ed092"),
            Opacity = 0.65, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap,
            MaxWidth = 380, HorizontalAlignment = HorizontalAlignment.Center,
        });
        column.Children.Add(LauncherHeading(L10n.Text("common.open")));
        var links = new FlowPanel { MinimumItemWidth = LauncherTileMinWidth, Spacing = Theme.SpaceM };
        // Every section of the project, because the sidebar lists only what
        // is running and the chats; this page is where the rest open.
        foreach (var section in new[]
        {
            WorkspaceSection.Chat, WorkspaceSection.Files, WorkspaceSection.Browser,
            WorkspaceSection.Changes, WorkspaceSection.History, WorkspaceSection.Pulls,
            WorkspaceSection.Todo, WorkspaceSection.Notes, WorkspaceSection.Automations,
            WorkspaceSection.Workflows,
        })
        {
            var icon = section.Action().Icon();
            icon.Foreground = Theme.AccentBrush;
            var button = LauncherTile(TileBody(new Viewbox { Width = 18, Height = 18, Child = icon }, section.Label()));
            button.Click += (_, _) => AppServices.OpenWorkspace?.Invoke(_id, section);
            links.Children.Add(button);
        }
        column.Children.Add(links);
    }

    /// <summary>A small caption over a group of tiles, like the Mac launcher.</summary>
    private static TextBlock LauncherHeading(string title) => new()
    {
        Text = title,
        FontSize = 12,
        FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        Foreground = Theme.Brush(static () => Theme.ControlGlyph),
        Margin = new Thickness(0, 4, 0, 0),
    };

    /// <summary>
    /// A tile's face: the mark in a 34 high slot, then one line of label. The
    /// slot is fixed so a glyph and a brand mark sit on the same baseline.
    /// </summary>
    private static StackPanel TileBody(UIElement mark, string label, double markOpacity = 1)
    {
        var slot = new Grid { Height = 34, Opacity = markOpacity };
        if (mark is FrameworkElement element)
        {
            element.HorizontalAlignment = HorizontalAlignment.Center;
            element.VerticalAlignment = VerticalAlignment.Center;
        }
        slot.Children.Add(mark);
        var body = new StackPanel { Spacing = Theme.SpaceS, HorizontalAlignment = HorizontalAlignment.Center };
        body.Children.Add(slot);
        body.Children.Add(new TextBlock
        {
            Text = label,
            FontSize = 13,
            FontWeight = Microsoft.UI.Text.FontWeights.Medium,
            HorizontalAlignment = HorizontalAlignment.Center,
            MaxLines = 1,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        return body;
    }

    /// <summary>
    /// The Mac tile: panel fill, hairline, card radius, 12 above and below.
    /// It stretches to its row, so a row of tiles is one height.
    /// </summary>
    private static Button LauncherTile(UIElement body) => new()
    {
        Content = body,
        HorizontalAlignment = HorizontalAlignment.Stretch,
        VerticalAlignment = VerticalAlignment.Stretch,
        HorizontalContentAlignment = HorizontalAlignment.Center,
        VerticalContentAlignment = VerticalAlignment.Center,
        Background = Theme.PanelBrush,
        BorderBrush = Theme.BorderBrush,
        BorderThickness = new Thickness(1),
        CornerRadius = new CornerRadius(Theme.CardRadius),
        Padding = new Thickness(Theme.SpaceS, Theme.SpaceM, Theme.SpaceS, Theme.SpaceM),
    };

    /// <summary>
    /// A tool that is not on the launcher yet: a faint fill and a dashed
    /// outline, like the Mac, so it reads as something to add rather than
    /// something to run. The outline sits over the button and takes no input.
    /// </summary>
    private static Grid DashedTile(Button button)
    {
        button.Background = Theme.Brush(static () => Windows.UI.Color.FromArgb(102, Theme.Panel.R, Theme.Panel.G, Theme.Panel.B));
        button.BorderThickness = new Thickness(0);
        var outline = new Microsoft.UI.Xaml.Shapes.Rectangle
        {
            RadiusX = Theme.CardRadius,
            RadiusY = Theme.CardRadius,
            Stroke = Theme.BorderBrush,
            StrokeThickness = 1,
            StrokeDashArray = new DoubleCollection { 4, 3 },
            IsHitTestVisible = false,
        };
        var tile = new Grid();
        tile.Children.Add(button);
        tile.Children.Add(outline);
        return tile;
    }

    private async Task LoadSessionsAsync(StackPanel column)
    {
        var launchers = new StackPanel { Spacing = Theme.SpaceM };
        column.Children.Add(launchers);
        await LoadLaunchersAsync(launchers);
        _sessionsHost.Children.Clear();
        column.Children.Add(_sessionsHost);
        await RefreshSessionsAsync();
        StartSessionsPoll();
    }

    private Task<JsonNode> CallTargetAsync(string method, JsonNode? parameters = null, TimeSpan? patience = null) =>
        RemoteWorkspaces.TrySplit(_id, out var peer, out _)
            ? RemoteWorkspaces.CallOnPeerAsync(peer, method, parameters, patience)
            : AppServices.Host.CallAsync(method, parameters, patience);

    private async Task LoadLaunchersAsync(StackPanel host)
    {
        host.Children.Clear();
        try
        {
            var catalog = await CallTargetAsync("launcher.catalog");
            var profiles = (Format.Items(catalog) ?? new JsonArray()).OfType<JsonNode>().ToArray();
            host.Children.Add(LauncherHeading(L10n.Text("windows.workspacepage.run_an_agent.b7046310")));
            var tiles = new FlowPanel { MinimumItemWidth = LauncherTileMinWidth, Spacing = Theme.SpaceM };
            // Like the Mac: the launcher's tools, then More, then the catalog
            // when it is open.
            var visible = new List<UIElement>();
            var extra = new List<UIElement>();
            foreach (var profile in profiles)
            {
                var id = Format.Text(profile, "id");
                var installed = Format.Flag(profile, "installed");
                var hidden = Format.Flag(profile, "hidden");
                var canInstall = !string.IsNullOrEmpty(Format.Text(profile, "installCommand"));
                var actionLabel = installed ? hidden ? L10n.Text("common.add")
                    : L10n.Text("windows.workspacepage.launch.ccf56ef5")
                    : canInstall ? L10n.Text("windows.workspacepage.install.569ca49f")
                    : L10n.Text("windows.chatpage.not_available_on_this_computer.ffcbd9b9");
                if ((!installed || hidden) && !_showingLauncherCatalog) continue;
                var onLauncher = installed && !hidden;
                // No status line, like the Mac: the faint mark and the dashed
                // outline say "not here yet", and the tooltip says what a
                // click does.
                var body = TileBody(AgentMark.View(Format.Text(profile, "harnessId", id), 34),
                    Format.Text(profile, "name", id), onLauncher ? 1 : 0.35);
                var actions = new StackPanel { Spacing = Theme.SpaceS };
                async Task RunAsync(Button button, string operation)
                {
                    button.IsEnabled = false;
                    try
                    {
                        if (operation == "show")
                        {
                            await CallTargetAsync("launcher.show", new JsonObject { ["id"] = id });
                            await LoadLaunchersAsync(host);
                            return;
                        }
                        if (operation == "install")
                        {
                            var result = await CallTargetAsync("launcher.install", new JsonObject { ["id"] = id }, TimeSpan.FromMinutes(5));
                            if (!Format.Flag(result, "ok")) throw new InvalidOperationException(Format.Text(result, "output", L10n.Text("windows.workspacepage.installation_failed.bfb3106f")));
                            await LoadLaunchersAsync(host);
                            return;
                        }
                        // The tool's own bypass flags when the project's switch
                        // is on, like the Mac launcher. A tool with none (the
                        // shell) launches the same either way.
                        var args = profile["args"]?.DeepClone() as JsonArray ?? new JsonArray();
                        if (WorkspaceBypass.IsOn(_id) && profile["bypassArgs"] is JsonArray bypassArgs)
                        {
                            foreach (var flag in bypassArgs) args.Add(flag?.DeepClone());
                        }
                        var session = await AppServices.Host.CallAsync("pty.spawn", new JsonObject
                        {
                            ["workspaceId"] = _id, ["command"] = Format.Text(profile, "command"),
                            ["args"] = args,
                            ["rows"] = 30, ["cols"] = 100, ["dark"] = Theme.IsDark,
                        });
                        var sessionId = Format.Text(session, "id");
                        if (string.IsNullOrEmpty(sessionId)) throw new InvalidOperationException(L10n.Text("windows.workspacepage.the_host_did_not_return_a_session.8a4eda9a"));
                        AppServices.OpenTerminal?.Invoke(_id, sessionId);
                    }
                    catch (Exception ex)
                    {
                        host.Children.Add(Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important));
                    }
                    finally { button.IsEnabled = true; }
                }
                var launch = LauncherTile(body);
                launch.Click += async (_, _) => await RunAsync(launch, installed ? hidden ? "show" : "launch" : "install");
                launch.IsEnabled = installed || canInstall;
                ToolTipService.SetToolTip(launch, hidden || !installed && !canInstall ? actionLabel
                    : installed ? L10n.Text("windows.workspacepage.launch_0.7c80096e", Format.Text(profile, "name", id))
                    : L10n.Text("windows.workspacepage.install_0.234d862d", Format.Text(profile, "name", id)));
                var tile = onLauncher ? new Grid() : DashedTile(launch);
                if (onLauncher) tile.Children.Add(launch);
                var setup = Buttons.ToolbarIcon(ActionIcon.Settings, L10n.Text("windows.workspacepage.set_up_0.4e4ef4a2", $"{Format.Text(profile, "name", id)}"), (_, _) => { }, isAccent: true);
                setup.HorizontalAlignment = HorizontalAlignment.Right;
                setup.VerticalAlignment = VerticalAlignment.Top;
                setup.Margin = new Thickness(8);
                setup.Width = 24; setup.Height = 24;
                setup.Foreground = Theme.AccentBrush;
                setup.Content = new FontIcon { Glyph = "\uE713", FontSize = 14 };
                var options = new Flyout { Content = actions };
                setup.Flyout = options;
                if (!string.IsNullOrEmpty(Format.Text(profile, "installCommand")))
                {
                    var install = ActionIconGlyph.Button(installed ? L10n.Text("windows.workspacepage.reinstall.c630a782") : L10n.Text("windows.workspacepage.install.569ca49f"), ActionIcon.Download, (_, _) => { });
                    install.Click += async (_, _) => { options.Hide(); await RunAsync(install, "install"); };
                    actions.Children.Add(install);
                }
                if (installed && !hidden && actions.Children.Count > 0) tile.Children.Add(setup);
                var menu = ContextMenus.Menu(tile);
                ContextMenus.AddButton(menu, launch, actionLabel);
                ContextMenus.AddButtons(menu, actions);
                if (installed && !hidden) ContextMenus.AddAsync(menu, L10n.Text("windows.workspacepage.remove_from_launcher.b107a73b"), async () =>
                {
                    try { await CallTargetAsync("launcher.hide", new JsonObject { ["id"] = id }); await LoadLaunchersAsync(host); }
                    catch (Exception ex) { host.Children.Add(Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important)); }
                });
                (onLauncher ? visible : extra).Add(tile);
            }
            foreach (var tile in visible) tiles.Children.Add(tile);
            if (profiles.Any(profile => !Format.Flag(profile, "installed") || Format.Flag(profile, "hidden")))
            {
                var glyph = (_showingLauncherCatalog ? ActionIcon.Collapse : ActionIcon.Create).Icon();
                var moreBody = TileBody(new Viewbox { Width = 18, Height = 18, Child = glyph },
                    _showingLauncherCatalog ? L10n.Text("windows.workspacepage.hide_catalog")
                        : L10n.Text("windows.workspacepage.more_tools"), 0.6);
                var more = LauncherTile(moreBody);
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(more, "launcher.more");
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(more, _showingLauncherCatalog
                    ? L10n.Text("windows.workspacepage.hide_catalog") : L10n.Text("windows.workspacepage.more_tools"));
                more.Click += async (_, _) => { _showingLauncherCatalog = !_showingLauncherCatalog; await LoadLaunchersAsync(host); };
                tiles.Children.Add(DashedTile(more));
            }
            foreach (var tile in extra) tiles.Children.Add(tile);
            host.Children.Add(tiles);
        }
        catch (Exception ex) { host.Children.Add(Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important)); }
    }

    /// <summary>
    /// The live session list, like the Mac session strip: each shell with its
    /// running state, refreshed on a timer while this section is on screen.
    /// A quiet pass replaces the rows without rebuilding the page.
    /// </summary>
    private async Task RefreshSessionsAsync()
    {
        if (_sessionsLoading)
        {
            return;
        }
        _sessionsLoading = true;
        try
        {
            var peer = RemoteWorkspaces.TrySplit(_id, out var peerKey, out var innerId)
                ? peerKey : null;
            var listed = peer is null
                ? await AppServices.Host.CallAsync("pty.list")
                : await RemoteWorkspaces.CallOnPeerAsync(peer, "pty.list");
            var array = listed as JsonArray
                ?? listed["sessions"] as JsonArray
                ?? listed["items"] as JsonArray;
            _sessionsHost.Children.Clear();
            var list = new StackPanel { Spacing = Theme.SpaceS };
            var running = 0;
            var total = 0;
            if (array is not null)
            {
                foreach (var item in array)
                {
                    if (Format.Flag(item, "hidden"))
                    {
                        continue;
                    }
                    var workspace = Format.Text(item, "workspaceId");
                    if (workspace != (peer is null ? _id : innerId))
                    {
                        continue;
                    }
                    var id = Format.Text(item, "id");
                    if (string.IsNullOrEmpty(id))
                    {
                        continue;
                    }
                    total++;
                    var alive = Format.Flag(item, "alive");
                    if (alive)
                    {
                        running++;
                    }
                    // Namespaced to the peer, the way the host renamespaces
                    // its own answers: the id reads as one of this machine's
                    // and groups under the remote folder in the sidebar.
                    var openId = peer is null ? id : RemoteWorkspaces.Join(peer, id);
                    list.Children.Add(SessionRow(
                        openId,
                        Format.Text(item, "command", "shell"),
                        alive,
                        item?["exitCode"] is null ? null : (int?)Format.Long(item, "exitCode")));
                }
            }
            if (total == 0)
            {
                _sessionsHost.Children.Add(EmptyState.View(
                    L10n.Text("windows.workspacepage.no_shells_in_this_folder.727f2ce6"),
                    RemoteWorkspaces.IsRemote(_id)
                        ? L10n.Text("windows.workspacepage.open_a_new_shell_it_runs_on_that_machine_t.ff8f1763")
                        : L10n.Text("windows.workspacepage.open_a_new_shell_it_runs_on_this_pc.eee8fa9c"),
                    EmptyArtKind.Sessions));
                _summary = L10n.Text("windows.workspacepage.no_shells_in_this_folder.b7cd6bcc");
            }
            else
            {
                _sessionsHost.Children.Add(Chrome.Card(L10n.Text("windows.workspacepage.sessions.6fa3cbf4"), list));
                _summary = running == total
                    ? L10n.Text("windows.workspacepage.0_1_all_running.504eeb8b", $"{total}", $"{(total == 1 ? "shell" : L10n.Text("windows.workspacepage.shells.b0606c08"))}")
                    : L10n.Text("windows.workspacepage.0_of_1_shells_running.13b482cd", $"{running}", $"{total}");
            }
            RenderInspector();
        }
        catch (Exception ex)
        {
            _sessionsHost.Children.Clear();
            _sessionsHost.Children.Add(Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important));
        }
        finally
        {
            _sessionsLoading = false;
        }
    }

    private UIElement SessionRow(string id, string command, bool alive, int? exitCode)
    {
        var state = alive
            ? "running"
            : exitCode.HasValue ? L10n.Text("windows.workspacepage.exited_0.39ec5073", $"{exitCode}") : "exited";
        var body = new StackPanel { Spacing = 2 };
        body.Children.Add(new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Theme.SpaceS,
            Children =
            {
                new Border
                {
                    Width = 8,
                    Height = 8,
                    CornerRadius = new CornerRadius(4),
                    Background = alive ? Theme.Brush(static () => Theme.Success) : Theme.Brush(static () => Theme.StateIdle),
                    VerticalAlignment = VerticalAlignment.Center,
                },
                new TextBlock
                {
                    Text = command,
                    FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                    TextWrapping = TextWrapping.Wrap,
                },
            },
        });
        body.Children.Add(new TextBlock
        {
            Text = $"{state} · {(id.Length <= 6 ? id : id[^6..])}",
            FontSize = 12,
            Opacity = 0.68,
        });
        var card = new Border
        {
            Background = Theme.PanelBrush,
            BorderBrush = Theme.BorderBrush,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(Theme.CardRadius),
            Padding = new Thickness(Theme.CardPadding),
            Child = body,
        };
        var open = new Button
        {
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(0),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Content = card,
        };
        var sessionId = id;
        open.Click += (_, _) => AppServices.OpenTerminal?.Invoke(_id, sessionId);
        return open;
    }

    private void StartSessionsPoll()
    {
        StopSessionsPoll();
        _sessionsPoll = DispatcherQueue.CreateTimer();
        _sessionsPoll.Interval = TimeSpan.FromSeconds(2);
        _sessionsPoll.Tick += (_, _) => _ = RefreshSessionsAsync();
        _sessionsPoll.Start();
    }

    private void StopSessionsPoll()
    {
        _sessionsPoll?.Stop();
        _sessionsPoll = null;
    }

    private async Task LoadBrowserAsync()
    {
        var memory = await BrowserProjectMemory.ForAsync(_id);
        var portBox = new TextBox
        {
            PlaceholderText = L10n.Text("windows.workspacepage.port.72e9a59f"),
            Text = memory?.Targets.FirstOrDefault() is string savedTarget && Uri.TryCreate(savedTarget, UriKind.Absolute, out var last) ? last.Port.ToString() : "",
            MinWidth = 120,
        };
        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Theme.SpaceS,
        };
        row.Children.Add(portBox);
        row.Children.Add(ActionIconGlyph.Button(L10n.Text("common.open"), ActionIcon.Browser, async (_, _) =>
        {
            await OpenPortAsync(portBox.Text);
        }));
        if (memory?.Targets.Count > 0)
        {
            var recent = new MenuFlyout();
            foreach (var target in memory.Targets)
                ContextMenus.Add(recent, target, () => portBox.Text = new Uri(target).Port.ToString());
            row.Children.Add(ActionIconGlyph.MoreButton(L10n.Text("windows.workspacepage.recent_ports.b757062a"), recent));
        }
        _root.Children.Add(row);
        _root.Children.Add(new TextBlock
        {
            Text = RemoteWorkspaces.IsRemote(_id)
                ? L10n.Text("windows.workspacepage.opens_a_page_from_that_machine_in_the_in_a.96e37993")
                : L10n.Text("windows.workspacepage.opens_a_loopback_page_on_this_pc_in_the_in.2e1d8c7c"),
            Opacity = 0.7,
            TextWrapping = TextWrapping.Wrap,
        });
    }

    private async Task OpenPortAsync(string raw)
    {
        var operation = BrowserProjectMemory.AccountEpoch.Capture();
        if (!ushort.TryParse(raw.Trim(), out var port) || port == 0)
        {
            _root.Children.Insert(1, Chrome.Banner(
                L10n.Text("windows.workspacepage.enter_a_port_between_1_and_65535.8d698cda"),
                Theme.Danger,
                Symbol.Important));
            return;
        }
        var open = AppServices.OpenBrowser;
        if (open is null)
        {
            _root.Children.Insert(1, Chrome.Banner(
                L10n.Text("windows.workspacepage.the_in_app_browser_is_not_wired_in_this_wi.7ab7dbc4"),
                Theme.Danger,
                Symbol.Important));
            return;
        }

        var host = "127.0.0.1";
        var browserPeer = RemoteWorkspaces.TrySplit(_id, out var peer, out _) ? peer : null;
        var original = $"http://{host}:{port}/";
        var memory = await BrowserProjectMemory.ForAsync(_id);
        if (!operation.IsCurrent || memory is not null && !memory.IsCurrent) return;
        if (browserPeer is null) memory?.Remember(original);
        // BrowserTab acquires a reference-counted bridge from this original target.
        open(original, host, port, false, browserPeer);
    }

    private async Task LoadTodoAsync()
    {
        var peer = RemoteWorkspaces.TrySplit(_id, out var peerKey, out var innerId)
            ? peerKey : null;
        var cards = peer is null
            ? await AppServices.Host.CallAsync("todo.list")
            : await RemoteWorkspaces.CallOnPeerAsync(peer, "todo.list");
        var array = cards as JsonArray ?? cards["cards"] as JsonArray;
        var list = new StackPanel { Spacing = Theme.SpaceS };
        var n = 0;
        if (array is not null)
        {
            foreach (var card in array)
            {
                var workspace = Format.Text(card, "workspaceId");
                if (!string.IsNullOrEmpty(workspace) && workspace != (peer is null ? _id : innerId))
                {
                    continue;
                }
                n++;
                list.Children.Add(new TextBlock { Text = Format.Text(card, "title", L10n.Text("windows.workspacepage.untitled.3bc7cc17")) });
            }
        }
        _summary = n == 0
            ? L10n.Text("windows.workspacepage.no_tasks_in_this_folder.876ca35f")
            : L10n.Text("windows.workspacepage.0_1_in_this_folder.8b3dad5f", $"{n}", $"{(n == 1 ? L10n.Text("windows.workspacepage.task.0ebb429f") : L10n.Text("windows.workspacepage.tasks.08515408"))}");
        RenderInspector();
        if (n == 0)
        {
            // The global Tasks board is this PC's only. A folder on another
            // machine grows its tasks on its own board instead.
            var hint = peer is null
                ? L10n.Text("windows.workspacepage.add_one_from_tasks.391694bb")
                : L10n.Text("windows.workspacepage.add_one_on_that_machine_s_board_for_this_f.b2cea4d5");
            _root.Children.Add(EmptyState.View(L10n.Text("windows.workspacepage.no_tasks_in_this_folder.ff9fd529"), hint, EmptyArtKind.Tasks));
            return;
        }
        _root.Children.Add(Chrome.Card(L10n.Text("common.tasks"), list));
    }

    private async Task<string> FolderNameAsync()
    {
        if (RemoteWorkspaces.CachedFolder(_id) is RemoteFolder cached)
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
                    if (Format.Text(folder, "id") == _id)
                    {
                        return Format.Text(folder, "name", Format.Text(folder, "path", _id));
                    }
                }
            }
        }
        catch
        {
        }
        return _id;
    }

    private static bool OutcomeOk(JsonNode outcome, out string message)
    {
        message = Format.Text(outcome, "message", L10n.Text("windows.workspacepage.the_command_failed.449398a9"));
        if (outcome is JsonObject && outcome["ok"] is not null)
        {
            return Format.Flag(outcome, "ok");
        }
        return true;
    }

    private static string ParentPath(string path)
    {
        var i = path.LastIndexOf('/');
        return i <= 0 ? "" : path[..i];
    }
}
