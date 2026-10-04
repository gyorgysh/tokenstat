// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Tokenstat.Navigation;

namespace Tokenstat.Pages;

internal sealed partial class ChatPage
{
    private readonly FlowPanel _gitStrip = new() { Spacing = Theme.SpaceS };
    private JsonNode? _workspaceGit;
    private JsonNode? _branchPull;
    private string? _pullBranch;
    private int _gitRead;
    private DateTimeOffset _gitReadAt;

    private void ResetWorkspaceGit()
    {
        _gitRead++;
        _gitReadAt = default;
        _workspaceGit = null;
        _branchPull = null;
        _pullBranch = null;
    }

    /// <summary>
    /// Local status may follow new edits. A forge lookup runs only on opening,
    /// a branch change, or the end of a turn, and never blocks the transcript.
    /// </summary>
    private async Task RefreshWorkspaceGitAsync(bool refreshPull = false)
    {
        if (_opening || _openId is not string chat) return;
        if (!refreshPull && DateTimeOffset.UtcNow - _gitReadAt < TimeSpan.FromSeconds(2)) return;
        _gitReadAt = DateTimeOffset.UtcNow;
        var generation = _openGeneration;
        var read = ++_gitRead;
        bool Current() => read == _gitRead && generation == _openGeneration && _openId == chat && IsLoaded && !_opening;
        try
        {
            var status = await RemoteWorkspaces.CallWorkspaceAsync(_workspaceId, "workspace.status", new JsonObject { ["id"] = _workspaceId });
            if (!Current()) return;
            _workspaceGit = status["git"];
            var branch = Format.Text(_workspaceGit, "branch");
            if (branch != _pullBranch) _branchPull = null;
            RenderGitStrip();
            if (!Busy() && branch.Length > 0 && (branch != _pullBranch || refreshPull))
            {
                var answer = await WorkspaceBranchPull.LoadAsync(_workspaceId, branch, refreshPull);
                if (!Current()) return;
                _pullBranch = branch;
                _branchPull = answer?["pull"];
                RenderGitStrip();
            }
        }
        catch
        {
            if (!Current()) return;
            _workspaceGit = null;
            _branchPull = null;
            RenderGitStrip();
        }
    }

    private void RenderGitStrip()
    {
        _gitStrip.Children.Clear();
        if (Format.Flag(_workspaceGit, "isRepo") && _workspaceGit?["files"] is JsonArray { Count: > 0 } files)
        {
            var changes = Buttons.Secondary(files.Count == 1
                ? L10n.Text("windows.chatchanges.files_changed.one", "1")
                : L10n.Text("windows.chatchanges.files_changed.other", $"{files.Count}"),
                ActionIcon.Preview, (_, _) => ReviewChangesRequested?.Invoke(null), small: true);
            _gitStrip.Children.Add(changes);
            _gitStrip.Children.Add(DiffStat(Format.Long(_workspaceGit, "added"), Format.Long(_workspaceGit, "removed")));
        }
        // A fresh no-PR answer supersedes the cached sidebar badge too.
        var branch = Format.Text(_workspaceGit, "branch");
        var pull = _pullBranch == branch ? _branchPull
            : (Format.Text(_openChat, "branch") == branch ? _openChat?["pull"] : null);
        if (pull is JsonObject) _gitStrip.Children.Add(WorkspaceBranchPull.Chip(pull));
        _gitStrip.Visibility = _gitStrip.Children.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    }
}
