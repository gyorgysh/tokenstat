// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Tokenstat.Design;
using Tokenstat.Navigation;
using Tokenstat.Notifications;

namespace Tokenstat.Pages;

internal sealed partial class AutomationsPage
{
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? _tablePoll;
    private bool _tableReading;
    private int _tableGeneration;
    private readonly OperationEpoch _tableMount = new();
    private void StartTablePolling()
    {
        if (!IsLoaded) return;
        StopTablePolling();
        _tablePoll = DispatcherQueue.CreateTimer();
        _tablePoll.Interval = TimeSpan.FromSeconds(2);
        _tablePoll.Tick += async (_, _) => await RefreshTableAsync();
        _tablePoll.Start();
    }
    private void StopTablePolling()
    {
        _tableGeneration++;
        _tablePoll?.Stop();
        _tablePoll = null;
    }
    private async Task RefreshTableAsync()
    {
        if (!IsLoaded || _working || _tableReading) return;
        _tableReading = true;
        var generation = _tableGeneration;
        try
        {
            var jobsRead = CallWorkbenchAsync("automation.list", new JsonObject());
            var runsRead = CallWorkbenchAsync("automation.runs", new JsonObject());
            await Task.WhenAll(jobsRead, runsRead);
            if (generation != _tableGeneration || _working || !IsLoaded) return;
            var jobs = Format.Items(jobsRead.Result) ?? new JsonArray();
            var runs = Format.Items(runsRead.Result) ?? new JsonArray();
            if (_scopeWorkspaceId is not null && RemoteWorkspaces.TrySplit(_scopeWorkspaceId, out _, out var inner))
            {
                foreach (var run in runs.OfType<JsonObject>())
                    if (Format.Text(run, "workspaceId") == inner) run["workspaceId"] = _scopeWorkspaceId;
                foreach (var job in jobs.OfType<JsonObject>())
                    if (Format.Text(job, "workspaceId") == inner) job["workspaceId"] = _scopeWorkspaceId;
            }
            if (jobs.ToJsonString() == _jobs.ToJsonString() && runs.ToJsonString() == _runs.ToJsonString()) return;
            _jobs = jobs; _runs = runs;
            _rawJobs = jobs.OfType<JsonObject>().Where(job => Format.Text(job, "id").Length > 0)
                .ToDictionary(job => Format.Text(job, "id"), job => (JsonObject)job.DeepClone());
            if (_scopeWorkspaceId is null || !RemoteWorkspaces.IsRemote(_scopeWorkspaceId)) RunNotifications.Shared.SettleAutomations(runs);
            RenderList();
            // A status update must not replace an editor under the person's caret.
            if (_showingRuns || !_detailDirty && !_creating) { SnapshotDraft(); RenderDetail(); }
        }
        catch { /* Quiet polling retains the last confirmed table and editor. */ }
        finally { _tableReading = false; }
    }
}
