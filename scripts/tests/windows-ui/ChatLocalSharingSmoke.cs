// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Tokenstat;
using Tokenstat.Pages;

namespace NativeUiTests;

internal static class ChatLocalSharingSmoke
{
    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        yield return root;
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
            foreach (var child in Descendants(VisualTreeHelper.GetChild(root, i))) yield return child;
    }
    internal static async Task RunAsync(StackPanel body)
    {
        var share = "share_" + new string('a', 32); var stopped = false; var released = false; var stopCalls = 0; var refreshes = 0;
        var current = true; var requests = new List<JsonObject>();
        Task<JsonNode> Local(string method, JsonObject input)
        {
            if (input["_accountScope"] is not null || input["_accountSession"] is not null || input["workspaceId"]?.GetValue<string>() != "folder" || input["id"]?.GetValue<string>() != "chat") throw new Exception("Local sharing controls used an account or another chat");
            requests.Add((JsonObject)input.DeepClone());
            if (method == "chat.sharing.info") return Task.FromResult<JsonNode>(new JsonObject { ["sharing"] = new JsonObject {
                ["id"] = share, ["revision"] = stopped ? 4L : 3L, ["phase"] = stopped ? "withdrawn" : "active", ["privateReady"] = released,
                ["accountCleanupPending"] = true, ["agentRunHeld"] = stopped && !released } });
            if (method == "chat.sharing.stopLocal")
            {
                if (input["share"]?.GetValue<string>() != share || input["expectedRevision"]?.GetValue<long>() != 3 || input["confirmStop"]?.GetValue<bool>() != true) throw new Exception("Local Stop lost explicit reviewed revision");
                stopCalls++; stopped = true;
                return Task.FromResult<JsonNode>(new JsonObject { ["stoppedLocally"] = true, ["privateReady"] = false, ["localRecoveryNeeded"] = true, ["accountCleanupPending"] = true });
            }
            if (method != "chat.sharing.recoverRun" || input["confirmRecovery"]?.GetValue<bool>() != true) throw new Exception("Unexpected local sharing request");
            released = true; return Task.FromResult<JsonNode>(new JsonObject { ["recovered"] = true });
        }
        var model = new ChatLocalSharingModel("folder", "chat", share, false, () => current, Local);
        var panel = new ChatLocalSharingPanel(model, () => current, () => { refreshes++; return Task.CompletedTask; });
        body.Children.Add(panel); body.UpdateLayout();
        Button Button(string key) => Descendants(panel).OfType<Button>().Single(button => AutomationProperties.GetName(button) == L10n.Text(key));
        async Task Wait(Func<bool> ready, string reason)
        {
            var deadline = DateTime.UtcNow.AddSeconds(5);
            while (!ready() && DateTime.UtcNow < deadline) { panel.UpdateLayout(); await Task.Delay(20); }
            if (!ready()) throw new Exception(reason);
        }
        async Task Click(string key)
        {
            var button = Button(key);
            if (!button.IsEnabled || new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke) is not IInvokeProvider invoke) throw new Exception("Local sharing action is inaccessible");
            invoke.Invoke(); await Task.Yield();
        }
        try
        {
            await Wait(() => model.Loaded, "Local sharing snapshot did not load");
            if (Button("common.teams.stop_sharing").IsEnabled || stopCalls != 0 || refreshes != 0) throw new Exception("Local Stop skipped review or resumed private editing");
            Descendants(panel).OfType<CheckBox>().Single().IsChecked = true;
            await Wait(() => Button("common.teams.stop_sharing").IsEnabled, "Explicit local sharing consent did not enable Stop");
            await Click("common.teams.stop_sharing"); await Wait(() => stopCalls == 1 && !model.Busy, "Reviewed local Stop did not settle");
            if (refreshes != 0 || model.PrivateReady) throw new Exception("An unresolved run resumed the personal chat");
            await Click("common.refresh"); await Wait(() => model.CanRelease, "Stopped-run proof recovery did not become available");
            if (Button("common.teams.stop_sharing").Visibility != Visibility.Collapsed) throw new Exception("Already withdrawn sharing asked for another Stop");
            await Click("common.teams.release_agent_run"); await Wait(() => refreshes == 1, "Proven release did not request an authoritative chat refresh");
            current = false; AppServices.NotifyAccountChanged();
            await Wait(() => !Button("common.refresh").IsEnabled, "Account replacement retained an actionable old cleanup surface");
        }
        finally { body.Children.Remove(panel); }
        Program.Log("PASS: native Windows local sharing requires review, preserves the private-use fence until proven release and retires controls after account replacement");
    }
}
