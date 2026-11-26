// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Tokenstat.Navigation;

namespace Tokenstat.Pages;

/// <summary>
/// Updating an agent from the chat's picker, with a toast that says it is
/// running and then what changed, from which version to which.
/// </summary>
internal sealed partial class ChatPage
{
    private FrameworkElement? _agentToast;
    private bool _updatingAgent;
    private bool _offeringAgentUpdate;

    private void AgentToast(string text, BannerSeverity severity)
    {
        if (_agentToast?.Parent is Microsoft.UI.Xaml.Controls.Panel previous) previous.Children.Remove(_agentToast);
        var toast = Chrome.Toast(text, severity, onDismiss: () => _agentToast = null);
        toast.HorizontalAlignment = HorizontalAlignment.Right;
        _agentToast = toast;
        _composerContext.Children.Insert(0, toast);
        if (severity != BannerSeverity.Success) return;
        var shown = toast;
        _ = Task.Delay(TimeSpan.FromSeconds(10)).ContinueWith(_ => DispatcherQueue.TryEnqueue(() =>
        {
            if (_agentToast != shown) return;
            (shown.Parent as Microsoft.UI.Xaml.Controls.Panel)?.Children.Remove(shown);
            _agentToast = null;
        }));
    }

    /// <summary>Updates the agent and says whether it worked.</summary>
    private async Task<bool> UpdateAgentAsync(JsonNode backend)
    {
        var id = Format.Text(backend, "launcherId");
        if (id.Length == 0 || _updatingAgent) return false;
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
        return severity == BannerSeverity.Success;
    }

    /// <summary>
    /// Before a message goes to an agent that is behind, offer the update,
    /// once per version and host, as on the Mac. True when the message should
    /// go now, false when it should wait in the composer.
    /// </summary>
    private async Task<bool> OfferAgentUpdateAsync(JsonNode backend, Func<bool> current)
    {
        // An update already running from the picker: send, as the Mac does.
        if (_updatingAgent) return true;
        if (_offeringAgentUpdate) return false;
        var host = ChatHostKey();
        if (!AgentUpdateSkips.IsDue(backend, host)) return true;
        var label = Format.Text(backend, "label");
        var lines = new List<string>();
        if (Format.Text(backend, "installedVersion") is { Length: > 0 } installed)
            lines.Add(L10n.Text("common.agent_updates.installed") + " " + installed);
        if (Format.Text(backend, "latestVersion") is { Length: > 0 } latest)
            lines.Add(L10n.Text("common.agent_updates.latest") + " " + latest);
        lines.Add(L10n.Text("common.agent_updates.prompt_detail"));
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = L10n.Text("common.agent_updates.prompt_title", label),
            Content = new TextBlock { Text = string.Join("\n", lines), TextWrapping = TextWrapping.Wrap },
            PrimaryButtonText = L10n.Text("common.agent_updates.update_and_send"),
            SecondaryButtonText = L10n.Text("common.agent_updates.skip_version"),
            CloseButtonText = L10n.Text("common.cancel"),
            DefaultButton = ContentDialogButton.Primary,
        };
        _offeringAgentUpdate = true;
        try
        {
            var result = await Chrome.ShowDialog(this, dialog);
            if (!current()) return false;
            switch (result)
            {
                case ContentDialogResult.Primary:
                    return await UpdateAgentAsync(backend);
                case ContentDialogResult.Secondary:
                    AgentUpdateSkips.Skip(backend, host);
                    return true;
                default:
                    return false;
            }
        }
        finally { _offeringAgentUpdate = false; }
    }

    /// <summary>Which machine the chat's agents run on, for per-host skips.</summary>
    private string ChatHostKey() =>
        RemoteWorkspaces.TrySplit(_workspaceId, out var peer, out _) ? peer : "local";
}

/// <summary>
/// Versions somebody chose to skip, per host and agent. A plain file beside
/// the other per-user settings, because this app is unpackaged.
/// </summary>
internal static class AgentUpdateSkips
{
    private static readonly object Gate = new();
    private static string FilePath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "tokenstat", "agent-update-skips.json");

    private static string Key(JsonNode backend, string host) =>
        host + "|" + Format.Text(backend, "launcherId", Format.Text(backend, "id"));

    internal static bool IsDue(JsonNode backend, string host)
    {
        if (!Format.Flag(backend, "updateAvailable") || Format.Text(backend, "launcherId").Length == 0) return false;
        if (backend["installed"] is JsonValue installed && installed.TryGetValue<bool>(out var on) && !on) return false;
        var latest = Format.Text(backend, "latestVersion");
        if (latest.Length == 0) return false;
        lock (Gate) return Format.Text(Read(), Key(backend, host)) != latest;
    }

    internal static void Skip(JsonNode backend, string host)
    {
        var latest = Format.Text(backend, "latestVersion");
        if (latest.Length == 0) return;
        lock (Gate)
        {
            var all = Read();
            all[Key(backend, host)] = latest;
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
                File.WriteAllText(FilePath, all.ToJsonString());
            }
            catch
            {
                // Not remembered: the offer comes back next time, which is safe.
            }
        }
    }

    private static JsonObject Read()
    {
        try
        {
            return File.Exists(FilePath) && JsonNode.Parse(File.ReadAllText(FilePath)) is JsonObject all ? all : new JsonObject();
        }
        catch
        {
            return new JsonObject();
        }
    }
}
