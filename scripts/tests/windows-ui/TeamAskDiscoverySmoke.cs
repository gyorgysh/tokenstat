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
using static Tokenstat.Pages.TeamManagementModel;

namespace NativeUiTests;

internal static class TeamAskDiscoverySmoke
{
    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        yield return root;
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
            foreach (var child in Descendants(VisualTreeHelper.GetChild(root, i))) yield return child;
    }
    internal static async Task RunAsync(StackPanel body)
    {
        var root = Path.Combine(Path.GetTempPath(), "teams-ask-discovery-" + Guid.NewGuid().ToString("N"));
        var storage = new TeamAskRecoveryStore(root); var person = "one"; var asks = 0; var stops = 0; var hold = false;
        var pending = new TaskCompletionSource<JsonNode>();
        var target = new TeamCommentTarget("https://fixture.invalid", "one", "org", "repo", "checkout", "share", new('a', 64));
        var input = new JsonObject { ["text"] = "Fictional saved request", ["review"] = new string('c', 64), ["clientMessageId"] = Guid.NewGuid().ToString(), ["clientMessageCreatedAtMs"] = 1L };
        var fence = new JsonObject { ["runId"] = "run_" + new string('a', 32), ["incarnation"] = new string('b', 64) };
        void Seed() => storage.Replace(target, new((JsonObject)input.DeepClone()), null, "Fictional unreachable project");
        Seed();
        Task<JsonNode> Host(string method, JsonObject? fields)
        {
            if (method == "account.status") return Task.FromResult<JsonNode>(new JsonObject { ["signedIn"] = true, ["host"] = target.Origin, ["handle"] = person, ["accountId"] = person, ["accountSession"] = "session-" + person });
            if (method == "teams.capabilities") throw new Tokenstat.Host.HostException("teams_unreachable", "Fictional directory offline");
            if (method != "teams.ask" || Text(fields, "_accountSession") != "session-one" || Text(fields?["target"], "share") != target.Share) throw new Exception("Saved Ask escaped its original account or chat");
            switch (Text(fields, "method"))
            {
                case "team.chat.ask":
                    if (!JsonNode.DeepEquals(fields?["params"], input)) throw new Exception("Recovery changed the reviewed request");
                    asks++; return hold ? pending.Task : Task.FromResult<JsonNode>(new JsonObject { ["state"] = "running", ["fence"] = fence.DeepClone() });
                case "team.chat.ask.stop":
                    if (!JsonNode.DeepEquals(fields?["params"]?["fence"], fence)) throw new Exception("Recovery changed the Stop fence");
                    stops++; return Task.FromResult<JsonNode>(new JsonObject { ["stopping"] = false });
                case "team.chat.ask.status": return Task.FromResult<JsonNode>(new JsonObject { ["running"] = false });
                default: throw new Exception("Recovery tried a new review or directory read");
            }
        }
        var page = new TeamsPage(Host, storage); body.Children.Add(page); body.UpdateLayout();
        bool Shows(string text) => Descendants(page).OfType<TextBlock>().Any(row => row.Text == text);
        async Task Wait(Func<bool> ready, string reason)
        {
            var deadline = DateTime.UtcNow.AddSeconds(6);
            while (!ready() && DateTime.UtcNow < deadline) { page.UpdateLayout(); await Task.Delay(20); }
            if (!ready()) throw new Exception(reason);
        }
        async Task Click(string key, bool last = false)
        {
            await Wait(() => Descendants(page).OfType<Button>().Any(button => AutomationProperties.GetName(button) == L10n.Text(key)
                && button.Visibility == Visibility.Visible && button.IsEnabled), "Saved request action did not become available: " + key);
            var buttons = Descendants(page).OfType<Button>().Where(b => AutomationProperties.GetName(b) == L10n.Text(key) && b.Visibility == Visibility.Visible).ToArray();
            var button = last ? buttons.Last() : buttons.Single();
            if (!button.IsEnabled || new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke) is not IInvokeProvider invoke) throw new Exception("Saved Ask action is inaccessible");
            invoke.Invoke(); await Task.Yield();
        }
        try
        {
            await Wait(() => Shows("Fictional directory offline"), "Unavailable directory did not settle");
            await Click("common.teams.saved_asks");
            await Wait(() => Shows("Fictional saved request"), "Saved Ask was hidden without directory access");
            if (asks != 0) throw new Exception("Listing saved Asks sent paid work");
            await Click("common.teams.recover_ask");
            await Wait(() => Descendants(page).OfType<Button>().Any(b => AutomationProperties.GetName(b) == L10n.Text("common.teams.retry_same_ask") && b.IsEnabled && b.Visibility == Visibility.Visible), "Original request did not restore");
            await Click("common.teams.retry_same_ask");
            await Wait(() => storage.Load(target)?.Record.Fence is not null, "Retry lost the original running fence");
            await Click("common.teams.stop_agent"); await Wait(() => stops == 1, "Recovered Stop was not sent");
            await Click("common.refresh", last: true); // The list refresh reloads the saved row without sending.
            await Wait(() => Descendants(page).OfType<Button>().Any(b => AutomationProperties.GetName(b) == L10n.Text("common.teams.recover_ask") && b.Visibility == Visibility.Visible), "List refresh did not retain the running request");
            await Click("common.teams.recover_ask");
            await Wait(() => Descendants(page).OfType<Button>().Any(b => AutomationProperties.GetName(b) == L10n.Text("common.teams.stop_agent") && b.Visibility == Visibility.Visible), "Reopened recovery lost Stop");
            var status = Descendants(page).OfType<Button>().First(b => AutomationProperties.GetName(b) == L10n.Text("common.refresh") && b.Visibility == Visibility.Visible);
            ((IInvokeProvider)new ButtonAutomationPeer(status).GetPattern(PatternInterface.Invoke)!).Invoke();
            await Wait(() => storage.Load(target) is null, "Confirmed completion did not settle saved recovery");

            Seed(); hold = true;
            await Click("common.refresh", last: true);
            await Wait(() => Descendants(page).OfType<Button>().Any(b => AutomationProperties.GetName(b) == L10n.Text("common.teams.recover_ask") && b.Visibility == Visibility.Visible), "Pending request did not reappear");
            await Click("common.teams.recover_ask");
            await Wait(() => Descendants(page).OfType<Button>().Any(b => AutomationProperties.GetName(b) == L10n.Text("common.teams.retry_same_ask") && b.IsEnabled && b.Visibility == Visibility.Visible), "Pending request did not restore");
            await Click("common.teams.retry_same_ask"); await Wait(() => asks == 2, "Lost reply was not held");
            person = "two"; AppServices.NotifyAccountChanged(); await Wait(() => !Shows("Fictional saved request"), "Another account kept old request text");
            pending.SetResult(new JsonObject { ["state"] = "running", ["fence"] = fence.DeepClone() }); await Task.Delay(100);
            if (storage.Load(target)?.Record.Fence is not null || storage.List(target.Origin, "two").Entries.Count != 0) throw new Exception("Late recovery changed the next account or overwrote an uncertain request");
        }
        finally { body.Children.Remove(page); Directory.Delete(root, true); }
        Program.Log("PASS: native Windows saved Ask discovery survives unavailable projects, retries the original request, recovers Stop and excludes late account replies");
    }
}
