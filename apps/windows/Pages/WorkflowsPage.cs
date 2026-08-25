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

namespace Tokenstat.Pages;

/// <summary>
/// Workflow graphs stored on this host. Run starts one, Kill stops a live run.
/// The canvas editor stays on the Mac.
/// </summary>
internal sealed class WorkflowsPage : Page
{
    private readonly string? _workspaceId;
    private readonly StackPanel _root = new() { Spacing = Theme.SpaceL };

    public WorkflowsPage(string? workspaceId = null)
    {
        _workspaceId = workspaceId;
        _root.Children.Add(ActionIconGlyph.Button(
            "Refresh", ActionIcon.Refresh, async (_, _) => await LoadAsync()));
        Content = new ScrollViewer
        {
            Padding = new Thickness(Theme.SpaceL),
            Content = _root,
        };
        Loaded += async (_, _) => await LoadAsync();
    }

    private async Task LoadAsync()
    {
        while (_root.Children.Count > 1)
        {
            _root.Children.RemoveAt(1);
        }
        JsonNode listed;
        JsonNode runsNode;
        try
        {
            listed = await AppServices.Host.CallAsync("workflow.list");
            try
            {
                runsNode = await AppServices.Host.CallAsync("workflow.runs");
            }
            catch
            {
                runsNode = new JsonArray();
            }
        }
        catch (Exception ex)
        {
            _root.Children.Add(Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important));
            return;
        }

        var live = LatestRuns(Format.Items(runsNode));
        var array = Format.Items(listed);
        var list = new StackPanel { Spacing = Theme.SpaceS };
        if (array is not null)
        {
            foreach (var graph in array)
            {
                if (!Format.InWorkspace(graph, _workspaceId, includeUnscoped: false))
                {
                    continue;
                }
                var id = Format.Text(graph, "id");
                if (string.IsNullOrEmpty(id))
                {
                    continue;
                }
                var name = Format.Text(graph, "name", Format.Text(graph, "title", "Workflow"));
                live.TryGetValue(id, out var run);
                var status = Format.Text(run, "status", "idle");
                var runId = Format.Text(run, "id");
                var running = status is "running" or "queued";

                var body = new StackPanel { Spacing = Theme.SpaceS };
                body.Children.Add(new TextBlock
                {
                    Text = name,
                    FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                    TextWrapping = TextWrapping.Wrap,
                });
                body.Children.Add(new TextBlock
                {
                    Text = status,
                    Opacity = 0.7,
                });
                var actions = new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Spacing = Theme.SpaceS,
                };
                var workflowId = id;
                actions.Children.Add(ActionIconGlyph.Button("Run", ActionIcon.Run, async (_, _) =>
                {
                    await RunAsync(workflowId);
                }));
                if (running && !string.IsNullOrEmpty(runId))
                {
                    var liveId = runId;
                    actions.Children.Add(ActionIconGlyph.Button("Kill", ActionIcon.Stop, async (_, _) =>
                    {
                        await KillAsync(liveId);
                    }));
                }
                body.Children.Add(actions);
                list.Children.Add(body);
            }
        }
        if (list.Children.Count == 0)
        {
            _root.Children.Add(Chrome.Empty(
                "No workflows yet",
                "Design a workflow on a Mac, then Run and Kill it from here.",
                Symbol.Switch));
            return;
        }
        _root.Children.Add(Chrome.Card("Workflows", list));
    }

    private async Task RunAsync(string id)
    {
        try
        {
            var parameters = new JsonObject
            {
                ["id"] = id,
                ["input"] = "",
            };
            if (!string.IsNullOrEmpty(_workspaceId))
            {
                parameters["workspaceId"] = _workspaceId;
            }
            await AppServices.Host.CallAsync("workflow.run", parameters);
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
            return;
        }
        await LoadAsync();
    }

    private async Task KillAsync(string runId)
    {
        try
        {
            await AppServices.Host.CallAsync("workflow.kill", new JsonObject { ["id"] = runId });
        }
        catch (Exception ex)
        {
            Banner(ex.Message);
            return;
        }
        await LoadAsync();
    }

    private static Dictionary<string, JsonNode?> LatestRuns(JsonArray? runs)
    {
        var map = new Dictionary<string, JsonNode?>();
        if (runs is null)
        {
            return map;
        }
        foreach (var run in runs)
        {
            var workflowId = Format.Text(run, "workflowId");
            if (string.IsNullOrEmpty(workflowId))
            {
                continue;
            }
            if (!map.TryGetValue(workflowId, out var existing)
                || Format.Long(run, "startedAtMs") >= Format.Long(existing, "startedAtMs"))
            {
                map[workflowId] = run;
            }
        }
        return map;
    }

    private void Banner(string text)
    {
        _root.Children.Insert(1, Chrome.Banner(text, Theme.Danger, Symbol.Important));
    }
}
