// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Tokenstat.Pages;

namespace Tokenstat;

/// <summary>
/// Asks the person sharing a project, wherever they are in the app, when a
/// teammate's Ask is waiting for them on this computer. The teammate's app
/// keeps sending the same request, so an answer here starts it within a few
/// seconds.
/// </summary>
public sealed partial class MainWindow
{
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? _teamAgentPoll;
    private readonly HashSet<string> _teamAgentAnswered = new(StringComparer.Ordinal);
    private bool _teamAgentPrompting;

    private void StartTeamAgentRequests()
    {
        _teamAgentPoll = DispatcherQueue.CreateTimer();
        _teamAgentPoll.Interval = TimeSpan.FromSeconds(3);
        _teamAgentPoll.Tick += (_, _) => _ = PollTeamAgentRequestsAsync();
        _teamAgentPoll.Start();
    }

    private async Task PollTeamAgentRequestsAsync()
    {
        // Nothing can be waiting unless this computer shares something.
        if (_teamAgentPrompting || _teamFolderLinks.Count == 0 || Content is not UIElement owner) return;
        JsonNode answer;
        try { answer = await AppServices.Host.CallAsync("teams.agentAccess.requests", new JsonObject()); }
        catch { return; }
        if (answer["requests"] is not JsonArray rows) return;
        var live = rows.OfType<JsonObject>().ToList();
        _teamAgentAnswered.RemoveWhere(id => !live.Any(row => Format.Text(row, "id") == id));
        var request = live.FirstOrDefault(row => !_teamAgentAnswered.Contains(Format.Text(row, "id")));
        if (request is null) return;
        _teamAgentPrompting = true;
        try
        {
            var id = Format.Text(request, "id"); var person = Format.Text(request, "personName");
            var project = TeamCheckoutFolderName(Format.Text(request, "checkoutId")) ?? L10n.Text("common.teams.this_project");
            var dialog = new ContentDialog
            {
                Title = L10n.Text("common.teams.agent_request_title", person),
                Content = new TextBlock { Text = L10n.Text("common.teams.agent_request_message", project, Format.Text(request, "text")), TextWrapping = TextWrapping.Wrap },
                PrimaryButtonText = L10n.Text("common.teams.agent_request_allow_once"),
                SecondaryButtonText = L10n.Text("common.teams.agent_request_allow_always", person),
                CloseButtonText = L10n.Text("common.teams.agent_request_deny"),
                DefaultButton = ContentDialogButton.Close,
            };
            ContentDialogResult result;
            // Another dialog may be open. Ask again on the next tick.
            try { result = await Chrome.ShowDialog(owner, dialog); }
            catch { return; }
            var decision = result switch { ContentDialogResult.Primary => "once", ContentDialogResult.Secondary => "always", _ => "deny" };
            _teamAgentAnswered.Add(id);
            try { await AppServices.Host.CallAsync("teams.agentAccess.decide", new JsonObject { ["request"] = id, ["decision"] = decision }); }
            catch (Exception error)
            {
                await Chrome.ShowDialog(owner, new ContentDialog { Title = L10n.Text("common.teams.agent_request_failed"), Content = error.Message, CloseButtonText = L10n.Text("common.done") });
            }
        }
        finally { _teamAgentPrompting = false; }
    }

    private string? TeamCheckoutFolderName(string checkout)
    {
        foreach (var (folder, publications) in _teamFolderLinks)
        {
            if (!publications.Any(row => Format.Text(row, "id") == checkout)) continue;
            return _localFolders.OfType<JsonObject>().FirstOrDefault(row => Format.Text(row, "id") == folder) is { } found
                ? Format.Text(found, "name") : null;
        }
        return null;
    }
}
