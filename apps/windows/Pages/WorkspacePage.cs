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
                "Reload " + _section.Label().ToLowerInvariant(),
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
            _inspector.Children.Add(Chrome.InspectorField("Branch", WorkspaceGit.ShortBranch(_branch)));
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

    private async Task LoadAsync()
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
                    LoadQuickActions();
                    await LoadSessionsAsync();
                    break;
                case WorkspaceSection.Sessions:
                    LoadQuickActions();
                    await LoadSessionsAsync();
                    break;
                case WorkspaceSection.Browser:
                    LoadBrowser();
                    break;
                default:
                    if (RemoteWorkspaces.IsRemote(_id))
                    {
                        _root.Children.Add(Chrome.Empty(
                            _section.Label() + " is local for now",
                            "This folder lives on another machine, and " + _section.Label().ToLowerInvariant()
                            + " for a remote folder stays local, like the desktop Mac.",
                            ActionIcon.Reveal));
                        break;
                    }
                    _root.Children.Add(Chrome.Empty(
                        _section.Label() + " on Windows",
                        "The Mac app has the full " + _section.Label().ToLowerInvariant()
                        + " surface. This build lists the folder and the shared boards.",
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
            chrome.Children.Add(ActionIconGlyph.Button("Back", ActionIcon.Back, async (_, _) =>
            {
                _path = ParentPath(_path);
                await LoadAsync();
            }));
        }
        chrome.Children.Add(new TextBlock
        {
            Text = _path.Length == 0 ? "Workspace root" : _path,
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
            _root.Children.Add(EmptyState.View("Empty folder", "Nothing to list here.", EmptyArtKind.Files));
            return;
        }

        _summary = _path.Length == 0
            ? $"{array.Count} {(array.Count == 1 ? "entry" : "entries")} at the workspace root."
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
        _root.Children.Add(Chrome.Card("Files", list));
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
                Text = "This file is too large to edit here. Showing the start, read-only.",
                TextWrapping = TextWrapping.Wrap,
                Opacity = 0.8,
            });
        }
        body.Children.Add(editor);

        var dialog = new ContentDialog
        {
            Title = name,
            Content = body,
            CloseButtonText = huge ? "Close" : "Cancel",
            DefaultButton = huge ? ContentDialogButton.Close : ContentDialogButton.Primary,
        };
        if (!huge)
        {
            dialog.PrimaryButtonText = "Save";
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
            _root.Children.Add(BranchBar(branch, upstream, ahead, behind, folderName));
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
            ? "A clean tree."
            : $"{available.Count} changed {(available.Count == 1 ? "file" : "files")}, "
            + $"{session.SelectedCount} selected for the next commit.";
        RenderInspector();

        var selectionRow = new FlowPanel { Spacing = Theme.SpaceS };
        selectionRow.Children.Add(new TextBlock
        {
            Text = $"{session.SelectedCount} of {available.Count} selected",
            VerticalAlignment = VerticalAlignment.Center,
            Opacity = 0.7,
        });
        selectionRow.Children.Add(ActionIconGlyph.Button("Select all", ActionIcon.Apply, async (_, _) =>
        {
            session.SetAll(available);
            await LoadAsync();
        }));
        selectionRow.Children.Add(ActionIconGlyph.Button("Clear", ActionIcon.Dismiss, async (_, _) =>
        {
            session.ClearSelection();
            await LoadAsync();
        }));
        if (!remote)
        {
            selectionRow.Children.Add(ActionIconGlyph.Button("Review and commit", ActionIcon.Commit, async (_, _) =>
            {
                if (session.SelectedCount == 0)
                {
                    _root.Children.Insert(1, Chrome.Banner(
                        "Select at least one file to review.",
                        Theme.Warning,
                        Symbol.Important));
                    return;
                }
                await WorkspaceCommitComposer.ShowAsync(this, _id, folderName, branch);
                await LoadAsync();
            }));
        }
        selectionRow.Children.Add(ActionIconGlyph.Button("Review all", ActionIcon.Compare, async (_, _) =>
        {
            if (reviewFiles.Count == 0)
            {
                _root.Children.Insert(1, Chrome.Banner(
                    "No changes to review.",
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
                ? "No uncommitted changes in this folder."
                : $"On {branch}. No uncommitted changes.";
            _root.Children.Add(EmptyState.View("Clean tree", clean, EmptyArtKind.Changes));
            return;
        }

        var list = new StackPanel { Spacing = Theme.SpaceS };
        if (!string.IsNullOrEmpty(branch))
        {
            list.Children.Add(new TextBlock { Text = "On " + branch, Opacity = 0.7 });
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
            ToolTipService.SetToolTip(check, "Include in the next commit");
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
            actions.Children.Add(ActionIconGlyph.Button("Stage", ActionIcon.Apply, async (_, _) =>
            {
                var paths = new JsonArray { JsonValue.Create(filePath) };
                await GitwriteAsync("workspace.stage", new JsonObject
                {
                    ["id"] = _id,
                    ["paths"] = paths,
                });
            }));
            actions.Children.Add(ActionIconGlyph.Button("Unstage", ActionIcon.Restore, async (_, _) =>
            {
                var paths = new JsonArray { JsonValue.Create(filePath) };
                await GitwriteAsync("workspace.unstage", new JsonObject
                {
                    ["id"] = _id,
                    ["paths"] = paths,
                });
            }));
            actions.Children.Add(ActionIconGlyph.Button("Diff", ActionIcon.Compare, async (_, _) =>
            {
                await ShowDiffAsync(filePath);
            }));
            Grid.SetColumn(actions, 2);
            line.Children.Add(actions);
            list.Children.Add(line);
        }
        _root.Children.Add(Chrome.Card("Changes", list));

        if (remote)
        {
            _root.Children.Add(new TextBlock
            {
                Text = "Commits for this folder are made on "
                    + (RemoteWorkspaces.CachedFolder(_id)?.MachineLabel is string machine
                        && !string.IsNullOrEmpty(machine) ? machine : "that machine")
                    + ". Stage, unstage and diff work here.",
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
        await WorkspaceDiff.ShowFileDiffAsync(this, "Diff · " + filePath, diff);
    }

    private async Task<JsonNode?> LoadOneDiffAsync(string path)
    {
        return await RemoteWorkspaces.CallWorkspaceAsync(
            _id,
            "workspace.diff",
            new JsonObject { ["id"] = _id, ["path"] = path });
    }

    private UIElement BranchBar(string current, string upstream, long ahead, long behind, string folderName)
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
            ToolTipService.SetToolTip(switchButton, "Tracking " + upstream);
        }
        row.Children.Add(switchButton);
        row.Children.Add(ActionIconGlyph.Button("Push", ActionIcon.Upload, async (_, _) =>
        {
            await WorkspacePushDialog.ShowAsync(this, _id, folderName);
            await LoadAsync();
        }));
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

    private void LoadQuickActions()
    {
        var body = new StackPanel { Spacing = Theme.SpaceM, MaxWidth = 780, HorizontalAlignment = HorizontalAlignment.Stretch, Margin = new Thickness(0, 32, 0, 16) };
        body.Children.Add(new TextBlock
        {
            Text = "What do you want to do in " + _folderName + "?",
            TextAlignment = TextAlignment.Center, FontSize = 22, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
        });
        body.Children.Add(new TextBlock { Text = "Open the project where you left it, or start an agent that keeps running on its own.",
            Opacity = 0.65, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 16) });
        body.Children.Add(new TextBlock { Text = "Open", FontSize = 12, Opacity = 0.7 });
        var links = new FlowPanel { MinimumItemWidth = 220, Spacing = Theme.SpaceM };
        foreach (var section in new[] { WorkspaceSection.Chat, WorkspaceSection.Files, WorkspaceSection.Browser, WorkspaceSection.Changes, WorkspaceSection.Pulls, WorkspaceSection.Todo })
        {
            var content = new StackPanel { Spacing = Theme.SpaceS, HorizontalAlignment = HorizontalAlignment.Center };
            var icon = section.Action().Icon();
            icon.Foreground = Theme.AccentBrush;
            content.Children.Add(icon);
            content.Children.Add(new TextBlock { Text = section.Label(), HorizontalAlignment = HorizontalAlignment.Center });
            var button = new Button
            {
                Content = content, HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Center,
                Background = Theme.PanelBrush, BorderBrush = Theme.BorderBrush,
                CornerRadius = new CornerRadius(Theme.CardRadius), Padding = new Thickness(Theme.SpaceL),
            };
            button.Click += (_, _) => AppServices.OpenWorkspace?.Invoke(_id, section);
            links.Children.Add(button);
        }
        body.Children.Add(links);
        _root.Children.Add(body);
    }

    private async Task LoadSessionsAsync()
    {
        var launchers = new StackPanel { Spacing = Theme.SpaceS };
        launchers.MaxWidth = 780;
        launchers.HorizontalAlignment = HorizontalAlignment.Stretch;
        _root.Children.Add(launchers);
        await LoadLaunchersAsync(launchers);
        _sessionsHost.Children.Clear();
        _root.Children.Add(_sessionsHost);
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
            host.Children.Add(new TextBlock { Text = "Run an agent", Opacity = 0.7, FontSize = 12 });
            var tiles = new FlowPanel { MinimumItemWidth = 220, Spacing = Theme.SpaceM };
            foreach (var profile in Format.Items(catalog) ?? new JsonArray())
            {
                if (profile is null || Format.Flag(profile, "hidden")) continue;
                var id = Format.Text(profile, "id");
                var installed = Format.Flag(profile, "installed");
                var body = new StackPanel { Spacing = Theme.SpaceM, HorizontalAlignment = HorizontalAlignment.Center };
                body.Children.Add(AgentMark.View(Format.Text(profile, "harnessId", id), 42));
                body.Children.Add(new TextBlock
                {
                    Text = Format.Text(profile, "name", id), HorizontalAlignment = HorizontalAlignment.Center,
                    FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                });
                var actions = new StackPanel { Spacing = Theme.SpaceS };
                async Task RunAsync(Button button, string operation)
                {
                    button.IsEnabled = false;
                    try
                    {
                        if (operation == "install")
                        {
                            var result = await CallTargetAsync("launcher.install", new JsonObject { ["id"] = id }, TimeSpan.FromMinutes(5));
                            if (!Format.Flag(result, "ok")) throw new InvalidOperationException(Format.Text(result, "output", "Installation failed."));
                            await LoadLaunchersAsync(host);
                            return;
                        }
                        var session = await AppServices.Host.CallAsync("pty.spawn", new JsonObject
                        {
                            ["workspaceId"] = _id, ["command"] = Format.Text(profile, "command"),
                            ["args"] = profile["args"]?.DeepClone() ?? new JsonArray(),
                            ["rows"] = 30, ["cols"] = 100, ["dark"] = Theme.IsDark,
                        });
                        var sessionId = Format.Text(session, "id");
                        if (string.IsNullOrEmpty(sessionId)) throw new InvalidOperationException("The host did not return a session.");
                        AppServices.OpenTerminal?.Invoke(_id, sessionId);
                    }
                    catch (Exception ex)
                    {
                        host.Children.Add(Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important));
                    }
                    finally { button.IsEnabled = true; }
                }
                var launch = new Button
                {
                    Content = body, HorizontalAlignment = HorizontalAlignment.Stretch,
                    HorizontalContentAlignment = HorizontalAlignment.Center,
                    Background = Theme.PanelBrush, BorderBrush = Theme.BorderBrush,
                    CornerRadius = new CornerRadius(Theme.CardRadius), Padding = new Thickness(24), MinHeight = 110,
                };
                launch.Click += async (_, _) => await RunAsync(launch, installed ? "launch" : "install");
                launch.IsEnabled = installed || !string.IsNullOrEmpty(Format.Text(profile, "installCommand"));
                ToolTipService.SetToolTip(launch, installed ? "Launch " + Format.Text(profile, "name", id) : "Install " + Format.Text(profile, "name", id));
                var tile = new Grid();
                tile.Children.Add(launch);
                var setup = Buttons.ToolbarIcon(ActionIcon.Settings, "Set up " + Format.Text(profile, "name", id), (_, _) => { }, isAccent: true);
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
                    var install = ActionIconGlyph.Button(installed ? "Reinstall" : "Install", ActionIcon.Download, (_, _) => { });
                    install.Click += async (_, _) => { options.Hide(); await RunAsync(install, "install"); };
                    actions.Children.Add(install);
                }
                if (actions.Children.Count > 0) tile.Children.Add(setup);
                var menu = ContextMenus.Menu(tile);
                ContextMenus.AddButton(menu, launch, installed ? "Launch" : "Install");
                ContextMenus.AddButtons(menu, actions);
                ContextMenus.AddAsync(menu, "Remove from launcher", async () =>
                {
                    try { await CallTargetAsync("launcher.hide", new JsonObject { ["id"] = id }); await LoadLaunchersAsync(host); }
                    catch (Exception ex) { host.Children.Add(Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important)); }
                });
                tiles.Children.Add(tile);
            }
            host.Children.Add(tiles);
            var hidden = (Format.Items(catalog) ?? new JsonArray()).Where(profile => Format.Flag(profile, "hidden")).ToList();
            if (hidden.Count > 0)
            {
                var restore = ActionIconGlyph.Button("Restore hidden launchers", ActionIcon.Restore, (_, _) => { });
                var menu = new MenuFlyout();
                foreach (var profile in hidden)
                {
                    var hiddenId = Format.Text(profile, "id");
                    ContextMenus.AddAsync(menu, Format.Text(profile, "name", hiddenId), async () =>
                    {
                        try { await CallTargetAsync("launcher.show", new JsonObject { ["id"] = hiddenId }); await LoadLaunchersAsync(host); }
                        catch (Exception ex) { host.Children.Add(Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important)); }
                    });
                }
                restore.Flyout = menu;
                host.Children.Add(restore);
            }
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
                    "No shells in this folder",
                    RemoteWorkspaces.IsRemote(_id)
                        ? "Open a new shell. It runs on that machine through the tunnel."
                        : "Open a new shell. It runs on this PC through the host.",
                    EmptyArtKind.Sessions));
                _summary = "No shells in this folder.";
            }
            else
            {
                _sessionsHost.Children.Add(Chrome.Card("Sessions", list));
                _summary = running == total
                    ? $"{total} {(total == 1 ? "shell" : "shells")}, all running."
                    : $"{running} of {total} shells running.";
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
            : exitCode.HasValue ? $"exited {exitCode}" : "exited";
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

    private void LoadBrowser()
    {
        var portBox = new TextBox
        {
            PlaceholderText = "Port",
            MinWidth = 120,
        };
        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Theme.SpaceS,
        };
        row.Children.Add(portBox);
        row.Children.Add(ActionIconGlyph.Button("Open", ActionIcon.Browser, async (_, _) =>
        {
            await OpenPortAsync(portBox.Text);
        }));
        _root.Children.Add(row);
        _root.Children.Add(new TextBlock
        {
            Text = RemoteWorkspaces.IsRemote(_id)
                ? "Opens a page from that machine in the in-app browser, through the tunnel. Use the port its dev server is already listening on."
                : "Opens a loopback page on this PC in the in-app browser. Use the port a local dev server is already listening on.",
            Opacity = 0.7,
            TextWrapping = TextWrapping.Wrap,
        });
    }

    private async Task OpenPortAsync(string raw)
    {
        if (!ushort.TryParse(raw.Trim(), out var port) || port == 0)
        {
            _root.Children.Insert(1, Chrome.Banner(
                "Enter a port between 1 and 65535.",
                Theme.Danger,
                Symbol.Important));
            return;
        }
        var open = AppServices.OpenBrowser;
        if (open is null)
        {
            _root.Children.Insert(1, Chrome.Banner(
                "The in-app browser is not wired in this window.",
                Theme.Danger,
                Symbol.Important));
            return;
        }

        var host = "127.0.0.1";
        var unlistens = false;
        string? browserPeer = null;
        var url = $"http://{host}:{port}/";
        try
        {
            var parameters = new JsonObject
            {
                ["host"] = host,
                ["port"] = port,
            };
            if (RemoteWorkspaces.TrySplit(_id, out var peerKey, out _))
            {
                // The dev server listens on the peer's own loopback. The
                // bridge below binds one here and carries the bytes over.
                browserPeer = peerKey;
                parameters["peer"] = browserPeer;
            }
            var listened = await AppServices.Host.CallAsync("proxy.listen", parameters);
            var returned = Format.Text(listened, "url");
            if (!string.IsNullOrEmpty(returned))
            {
                url = returned;
            }
            unlistens = true;
        }
        catch (Exception ex)
        {
            if (RemoteWorkspaces.IsRemote(_id))
            {
                // The port is on the other machine: there is no local page
                // to fall back to.
                _root.Children.Insert(1, Chrome.Banner(
                    FriendlyError.Display(ex.Message), Theme.Danger, Symbol.Important));
                return;
            }
            var missingPeer = ex.Message.Contains("peer", StringComparison.OrdinalIgnoreCase)
                || ex.Message.Contains("missing field", StringComparison.OrdinalIgnoreCase);
            if (!missingPeer)
            {
                _root.Children.Insert(1, Chrome.Banner(
                    ex.Message + " Opening the port directly on this PC.",
                    Theme.Warning,
                    Symbol.Important));
            }
        }
        open(url, host, port, unlistens, browserPeer);
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
                list.Children.Add(new TextBlock { Text = Format.Text(card, "title", "(untitled)") });
            }
        }
        _summary = n == 0
            ? "No tasks in this folder."
            : $"{n} {(n == 1 ? "task" : "tasks")} in this folder.";
        RenderInspector();
        if (n == 0)
        {
            // The global Tasks board is this PC's only. A folder on another
            // machine grows its tasks on its own board instead.
            var hint = peer is null
                ? "Add one from Tasks."
                : "Add one on that machine's board for this folder.";
            _root.Children.Add(EmptyState.View("No tasks in this folder", hint, EmptyArtKind.Tasks));
            return;
        }
        _root.Children.Add(Chrome.Card("Tasks", list));
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
        message = Format.Text(outcome, "message", "The command failed.");
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
