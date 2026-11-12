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
    private readonly ContentControl _viewer = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch,
        VerticalContentAlignment = VerticalAlignment.Stretch };
    private string? _displayedPath;
    private readonly ContentControl _error = new();
    private readonly TextBlock _title = new() { TextWrapping = TextWrapping.Wrap,
        VerticalAlignment = VerticalAlignment.Center };
    private CancellationTokenSource _lifetime = new();
    private string? _path;
    private bool _loading;
    private bool _pending;
    private int _attachmentRevision;
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
        Loaded += (_, _) => ReconcileAttachment();
        Unloaded += (_, _) => ReconcileAttachment();
    }

    private void ReconcileAttachment()
    {
        var revision = ++_attachmentRevision;
        // An old Unloaded can arrive after a quick remove/re-add. Cancelling
        // there would stop the current review's polling and every later load.
        if (!DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, () =>
        {
            if (revision != _attachmentRevision) return;
            if (IsLoaded && Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(this) is not null)
            {
                if (_lifetime.IsCancellationRequested) { _lifetime.Dispose(); _lifetime = new(); }
                _poll.Start();
                Refresh();
            }
            else { _poll.Stop(); _lifetime.Cancel(); }
        })) { _poll.Stop(); _lifetime.Cancel(); }
    }

    internal void Review(string? path) { _path = path; Refresh(); }
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
                    var (snapshot, signature, selected) = await SnapshotAsync(path, lifetime.Token);
                    if (!Current()) continue;
                    if (snapshot is not null)
                    {
                        var offset = _displayedPath == selected && _viewer.Content is WorkspaceReviewBrowser previous
                            ? previous.VerticalOffset : 0;
                        _viewer.Content = snapshot;
                        if (snapshot is WorkspaceReviewBrowser browser) browser.RestoreOffset(offset);
                        _displayedPath = selected;
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

    private async Task<(UIElement? Snapshot, string Signature, string? Selected)> SnapshotAsync(string? path, CancellationToken token)
    {
        var status = await RemoteWorkspaces.CallWorkspaceAsync(_workspaceId, "workspace.status",
            new JsonObject { ["id"] = _workspaceId }).WaitAsync(TimeSpan.FromSeconds(30), token);
        var files = (status["git"]?["files"] as JsonArray ?? status["files"] as JsonArray ?? new JsonArray())
            .Select(file => Format.Text(file, "path")).Where(name => !string.IsNullOrEmpty(name)).ToArray();
        var selected = path is not null && files.Contains(path) ? path : files.FirstOrDefault();
        if (selected is null)
        {
            var emptySignature = "empty";
            if (emptySignature == _snapshotSignature) return (null, emptySignature, null);
            return (new TextBlock { Text = L10n.Text("windows.workspacediff.no_changes_to_review.1f08cad6"),
                Margin = new Thickness(Theme.SpaceM), TextWrapping = TextWrapping.Wrap }, emptySignature, null);
        }
        JsonNode? diff = null;
        string? error = null;
        try
        {
            diff = await RemoteWorkspaces.CallWorkspaceAsync(_workspaceId, "workspace.diff",
                new JsonObject { ["id"] = _workspaceId, ["path"] = selected }).WaitAsync(TimeSpan.FromSeconds(30), token);
            token.ThrowIfCancellationRequested();
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception failure) { error = FriendlyError.Display(failure.Message); }
        var signature = selected + "\n" + string.Join("\n", files) + "\n" + (diff?.ToJsonString() ?? error);
        if (signature == _snapshotSignature) return (null, signature, selected);
        UIElement detail;
        if (diff is not null)
        {
            var document = new StackPanel { Spacing = Theme.SpaceS, Padding = new Thickness(Theme.SpaceM) };
            document.Children.Add(new TextBlock { Text = selected, FontFamily = Fonts.Mono, FontSize = 12,
                IsTextSelectionEnabled = true, TextTrimming = TextTrimming.CharacterEllipsis });
            document.Children.Add(WorkspaceDiff.FullFile(diff));
            detail = document;
        }
        else
        {
            var failed = new StackPanel { Spacing = Theme.SpaceS, Padding = new Thickness(Theme.SpaceM) };
            failed.Children.Add(Chrome.Banner(error ?? L10n.Text("windows.workspacediff.no_diff_was_returned.b30e0096"), Theme.Danger, Symbol.Important));
            failed.Children.Add(Buttons.Secondary(L10n.Text("common.retry"), ActionIcon.Refresh, (_, _) => Refresh(), small: true));
            detail = failed;
        }
        return (new WorkspaceReviewBrowser(files, selected, detail, Review), signature, selected);
    }
}
