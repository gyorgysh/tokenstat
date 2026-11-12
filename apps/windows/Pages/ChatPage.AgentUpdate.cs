// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Tokenstat.Design;

namespace Tokenstat.Pages;

/// <summary>
/// Updating an agent from the chat's picker, with a toast that says it is
/// running and then what changed, from which version to which.
/// </summary>
internal sealed partial class ChatPage
{
    private FrameworkElement? _agentToast;
    private bool _updatingAgent;

    private void AgentToast(string text, BannerSeverity severity)
    {
        if (_agentToast is not null) _root.Children.Remove(_agentToast);
        var toast = Chrome.Toast(text, severity, onDismiss: () => _agentToast = null);
        toast.HorizontalAlignment = HorizontalAlignment.Right;
        _agentToast = toast;
        _root.Children.Insert(Math.Min(1, _root.Children.Count), toast);
        if (severity != BannerSeverity.Success) return;
        // A success leaves on its own, like the Mac's. A failure stays until read.
        var shown = toast;
        _ = Task.Delay(TimeSpan.FromSeconds(10)).ContinueWith(_ => DispatcherQueue.TryEnqueue(() =>
        {
            if (_agentToast != shown) return;
            _root.Children.Remove(shown);
            _agentToast = null;
        }));
    }

    private async Task UpdateAgentAsync(JsonNode backend)
    {
        var id = Format.Text(backend, "launcherId");
        if (id.Length == 0 || _updatingAgent) return;
        var label = Format.Text(backend, "label", id);
        _updatingAgent = true;
        AgentToast(L10n.Text("common.agent_updates.toast_updating", label), BannerSeverity.Info);
        // The reload repaints the conversation, which clears the root, so the
        // closing toast goes up after it.
        string message;
        var severity = BannerSeverity.Success;
        try
        {
            var result = await CallChatAsync("launcher.update", new JsonObject { ["id"] = id }, LauncherInstaller.Patience);
            var before = Format.Text(result, "before");
            var after = Format.Text(result, "after");
            if (!Format.Flag(result, "ok"))
            {
                message = L10n.Text("common.agent_updates.toast_failed", label);
                severity = BannerSeverity.Warning;
            }
            else if (before.Length > 0 && after.Length > 0 && before != after)
                message = L10n.Text("common.agent_updates.toast_updated", label, before, after);
            else if (after.Length > 0)
                message = L10n.Text("common.agent_updates.toast_current", label, after);
            else
                message = L10n.Text("common.agent_updates.toast_finished", label);
        }
        catch (Exception)
        {
            message = L10n.Text("common.agent_updates.toast_failed", label);
            severity = BannerSeverity.Warning;
        }
        try
        {
            await ReloadBackendsAsync();
        }
        catch (Exception)
        {
            // The toast still says what happened. The list catches up on the next reload.
        }
        AgentToast(message, severity);
        _updatingAgent = false;
    }
}
