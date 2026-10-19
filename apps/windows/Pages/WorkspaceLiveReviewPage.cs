// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Tokenstat.Navigation;

namespace Tokenstat.Pages;

/// <summary>A live working-tree review, separate from immutable turn and commit reviews.</summary>
internal sealed class WorkspaceLiveReviewPage : Page
{
    private readonly string _workspaceId;
    private readonly ScrollViewer _viewer = new() { Padding = new Thickness(Theme.SpaceM),
        HorizontalScrollBarVisibility = ScrollBarVisibility.Auto };
    private readonly ContentControl _error = new();
    private readonly TextBlock _title = new() { TextWrapping = TextWrapping.Wrap,
        VerticalAlignment = VerticalAlignment.Center };
    private CancellationTokenSource _lifetime = new();
    private string? _path;
    private bool _loading;
    private bool _pending;
    private string? _snapshotSignature;
    private readonly DispatcherQueueTimer _poll;

    internal WorkspaceLiveReviewPage(string workspaceId, Action manage)
    {
        _workspaceId = workspaceId;
        _poll = DispatcherQueue.CreateTimer();
        _poll.Interval = TimeSpan.FromSeconds(3);
        _poll.Tick += (_, _) =>
        {
            if (_loading) return;
            for (DependencyObject? node = this; node is not null; node = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(node))
                if (node is UIElement { Visibility: Visibility.Collapsed }) return;
            Refresh();
        };
        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var header = new FlowPanel { Spacing = Theme.SpaceS, Margin = new Thickness(8) };
        _title.Text = L10n.Text("windows.workbench.working_tree");
        header.Children.Add(_title);
        header.Children.Add(Buttons.ToolbarIcon(ActionIcon.Refresh, L10n.Text("common.retry"), (_, _) => Refresh()));
        header.Children.Add(Buttons.Secondary(L10n.Text("windows.workspacepage.review_and_commit.96f097b7"),
            ActionIcon.Commit, (_, _) => manage(), small: true));
        root.Children.Add(header);
        Grid.SetRow(_error, 1); root.Children.Add(_error);
        Grid.SetRow(_viewer, 2); root.Children.Add(_viewer);
        _viewer.Content = new ProgressRing { IsActive = true };
        Content = root;
        Loaded += (_, _) => { _lifetime.Dispose(); _lifetime = new(); _poll.Start(); Refresh(); };
        Unloaded += (_, _) => { _poll.Stop(); _lifetime.Cancel(); };
    }

    internal void Review(string? path) { _path = path; _title.Text = path ?? L10n.Text("windows.workbench.working_tree"); Refresh(); }
    internal void Refresh()
    {
        if (!IsLoaded) return;
        _pending = true;
        if (!_loading) _ = ReloadAsync();
    }

    private async Task ReloadAsync()
    {
        _loading = true;
        try
        {
            while (_pending && IsLoaded)
            {
                _pending = false;
                var lifetime = _lifetime;
                var path = _path;
                bool Current() => IsLoaded && lifetime == _lifetime && !lifetime.IsCancellationRequested && path == _path;
                try
                {
                    var (snapshot, signature) = await SnapshotAsync(path, lifetime.Token);
                    if (!Current()) continue;
                    if (snapshot is not null)
                    {
                        var offset = _viewer.VerticalOffset;
                        _viewer.Content = snapshot;
                        _viewer.UpdateLayout();
                        _viewer.ChangeView(null, offset, null, true);
                        _snapshotSignature = signature;
                    }
                    _error.Content = null;
                }
                catch (OperationCanceledException) { }
                catch (Exception error)
                {
                    if (Current()) _error.Content = Chrome.Banner(FriendlyError.Display(error.Message), Theme.Danger, Symbol.Important);
                }
            }
        }
        finally { _loading = false; }
    }

    private async Task<(UIElement? Snapshot, string Signature)> SnapshotAsync(string? path, CancellationToken token)
    {
        var status = await RemoteWorkspaces.CallWorkspaceAsync(_workspaceId, "workspace.status",
            new JsonObject { ["id"] = _workspaceId }).WaitAsync(TimeSpan.FromSeconds(30), token);
        var files = (status["git"]?["files"] as JsonArray ?? status["files"] as JsonArray ?? new JsonArray())
            .Where(file => path is null || Format.Text(file, "path") == path).ToArray();
        using var slots = new SemaphoreSlim(4);
        var loads = new List<Task<(JsonNode? File, JsonNode? Diff, string? Error)>>();
        foreach (var file in files.Take(WorkspaceDiff.ReviewMaxFiles))
        {
            async Task<(JsonNode?, JsonNode?, string?)> Load()
            {
                await slots.WaitAsync(token);
                try
                {
                    var name = Format.Text(file, "path");
                    var diff = await RemoteWorkspaces.CallWorkspaceAsync(_workspaceId, "workspace.diff",
                        new JsonObject { ["id"] = _workspaceId, ["path"] = name }).WaitAsync(TimeSpan.FromSeconds(30), token);
                    token.ThrowIfCancellationRequested();
                    return (file, diff, null);
                }
                catch (OperationCanceledException) { throw; }
                catch (Exception error)
                {
                    return (file, null, FriendlyError.Display(error.Message));
                }
                finally { slots.Release(); }
            }
            loads.Add(Load());
        }
        var results = await Task.WhenAll(loads);
        var signature = path + "\n" + string.Join("\n", files.Select(file => file?.ToJsonString()))
            + "\n" + string.Join("\n", results.Select(result => result.Diff?.ToJsonString() ?? result.Error));
        if (signature == _snapshotSignature) return (null, signature);
        var stack = new StackPanel { Spacing = Theme.SpaceM };
        if (files.Length == 0)
            stack.Children.Add(new TextBlock { Text = L10n.Text("windows.workspacediff.no_changes_to_review.1f08cad6"), TextWrapping = TextWrapping.Wrap });
        foreach (var result in results)
        {
            if (result.Diff is { } diff)
                stack.Children.Add(path is not null ? WorkspaceDiff.FullFile(diff)
                    : WorkspaceDiff.FileCard(this, (Format.Text(result.File, "path"), Format.Text(result.File, "kind"),
                        Format.Long(result.File, "added"), Format.Long(result.File, "removed")), diff, workingTree: true));
            else
            {
                var failed = new StackPanel { Spacing = Theme.SpaceS };
                failed.Children.Add(Chrome.Banner(result.Error ?? L10n.Text("windows.workspacediff.no_diff_was_returned.b30e0096"), Theme.Danger, Symbol.Important));
                failed.Children.Add(Buttons.Secondary(L10n.Text("common.retry"), ActionIcon.Refresh, (_, _) => Refresh(), small: true));
                stack.Children.Add(failed);
            }
        }
        if (files.Length > WorkspaceDiff.ReviewMaxFiles)
        {
            var left = files.Length - WorkspaceDiff.ReviewMaxFiles;
            stack.Children.Add(new TextBlock { Text = L10n.Text("windows.workspacediff.0_more_1_changed_open_2_from_changes_for_t.f976e9a1",
                $"{left}", left == 1 ? L10n.Text("windows.workspacediff.file.3b9c358f") : L10n.Text("windows.workspacediff.files.3d7db37d"),
                left == 1 ? L10n.Text("windows.workspacediff.it.2ad8a704") : L10n.Text("windows.workspacediff.them.c9a8dc33")), TextWrapping = TextWrapping.Wrap });
        }
        return (stack, signature);
    }
}
