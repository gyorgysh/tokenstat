// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Reflection;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Tokenstat;
using Tokenstat.Design;
using Tokenstat.Pages;

namespace NativeUiTests
{
    internal static class TeamsPageSmoke
    {
        internal static async Task RunAsync(StackPanel body)
        {
            var target = new JsonObject { ["organization"] = "org-fixture", ["repository"] = "repo-fixture", ["checkout"] = "checkout-fixture", ["share"] = "share-fixture" };
            var fence = new JsonObject { ["fixture"] = "exact-original-fence" };
            JsonNode? stopped = null;
            var calls = 0;
            var statusReads = 0;
            var stopAttempts = 0;
            Task<JsonNode> Host(string method, JsonObject? fields)
            {
                if (method == "account.status") return Task.FromResult<JsonNode>(new JsonObject());
                if (Format.Text(fields, "method") == "team.chat.details")
                {
                    calls++;
                    throw new Tokenstat.Host.HostException("team_connection_unavailable", "Fictional history read failure");
                }
                if (Format.Text(fields, "method") == "team.chat.ask.stop")
                {
                    if (++stopAttempts == 1) throw new Tokenstat.Host.HostException("team_connection_unavailable", "Fictional Stop request failed");
                    stopped = fields?["params"]?["fence"]?.DeepClone();
                    return Task.FromResult<JsonNode>(new JsonObject());
                }
                if (Format.Text(fields, "method") == "team.chat.ask.status")
                {
                    statusReads++;
                    return Task.FromResult<JsonNode>(new JsonObject());
                }
                throw new Exception("Unexpected fictional host call");
            }
            var page = new TeamsPage(Host);
            body.Children.Add(page); body.UpdateLayout();
            var deadline = DateTime.UtcNow.AddSeconds(3);
            while (!page.IsLoaded && DateTime.UtcNow < deadline) await Task.Delay(20);
            if (!page.IsLoaded) throw new Exception("Teams fixture did not load");
            const BindingFlags flags = BindingFlags.Instance | BindingFlags.NonPublic;
            var runs = (Dictionary<string, JsonNode>)typeof(TeamsPage).GetField("_activeRuns", flags)!.GetValue(page)!;
            runs[target.ToJsonString()] = fence;
            var show = (Task<bool>)typeof(TeamsPage).GetMethod("ShowChatAsync", flags)!.Invoke(page, [target, "Fictional chat", "Fictional computer", null])!;
            if (await show || calls != 1) throw new Exception("Teams fixture did not exercise the history read failure");
            deadline = DateTime.UtcNow.AddSeconds(7);
            while (statusReads == 0 && DateTime.UtcNow < deadline) await Task.Delay(20);
            if (statusReads == 0 || runs.Count != 1) throw new Exception("An unconfirmed status discarded the known run");
            page.UpdateLayout();
            static IEnumerable<Button> Buttons(DependencyObject root)
            {
                if (root is Button button) yield return button;
                for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
                    foreach (var child in Buttons(VisualTreeHelper.GetChild(root, i))) yield return child;
            }
            var stop = Buttons(page).SingleOrDefault(b => AutomationProperties.GetName(b) == L10n.Text("common.teams.stop_agent"));
            if (stop is null || !stop.IsEnabled) throw new Exception("History failure hid the known Stop control");
            var invoke = new ButtonAutomationPeer(stop).GetPattern(PatternInterface.Invoke) as IInvokeProvider;
            if (invoke is null) throw new Exception("Stop has no accessible invoke action");
            invoke.Invoke();
            deadline = DateTime.UtcNow.AddSeconds(3);
            while (stopAttempts == 0 && DateTime.UtcNow < deadline) await Task.Delay(20);
            if (stopAttempts != 1 || !stop.IsEnabled) throw new Exception("Failed Stop could not be retried");
            invoke.Invoke();
            deadline = DateTime.UtcNow.AddSeconds(3);
            while (stopped is null && DateTime.UtcNow < deadline) await Task.Delay(20);
            if (!JsonNode.DeepEquals(fence, stopped)) throw new Exception("Stop lost the original run fence");
            body.Children.Remove(page);
            Program.Log("PASS: the production Teams reader preserves accessible Stop through malformed status and a history read failure");
            await DirectoryAsync(body);
        }

        private static async Task DirectoryAsync(StackPanel body)
        {
            var observed = new List<JsonObject>();
            var laterRequests = 0;
            static JsonObject Row(string id, string name, string? org = null) => org is null
                ? new JsonObject { ["id"] = id, ["name"] = name }
                : new JsonObject { ["id"] = id, ["name"] = name, ["organizationId"] = org, ["role"] = "viewer" };
            static JsonObject Page(string field, JsonObject[] rows, int? next = null) => new() { [field] = new JsonArray(rows.Cast<JsonNode?>().ToArray()), ["nextOffset"] = next };
            Task<JsonNode> Host(string method, JsonObject? fields)
            {
                if (method == "account.status") return Task.FromResult<JsonNode>(new JsonObject {
                    ["signedIn"] = true, ["host"] = "https://fixture.invalid", ["handle"] = "fictional", ["accountId"] = "person-fixture", ["accountSession"] = "fictional-session",
                });
                observed.Add((JsonObject)fields!.DeepClone());
                if (method == "teams.capabilities") return Task.FromResult<JsonNode>(new JsonObject { ["enabled"] = true, ["ready"] = true, ["actorId"] = "person-fixture" });
                if (method != "teams.directory") throw new Exception("Unexpected fictional directory method");
                var operation = Format.Text(fields, "operation");
                var offset = fields?["page"]?["offset"]?.GetValue<int>() ?? 0;
                JsonNode answer = operation switch {
                    "organizations.list" when offset == 0 => Page("organizations", [Row("org-first", "First fictional team")], 100),
                    "organizations.list" when ++laterRequests == 1 => throw new Tokenstat.Host.HostException("teams_unreachable", "Fictional temporary page failure"),
                    "organizations.list" => Page("organizations", [Row("org-later", "Later fictional team")]),
                    "organizations.get" => new JsonObject { ["organization"] = Row(Format.Text(fields, "organization"), "Later fictional team") },
                    "repositories.list" when Format.Text(fields, "organization") == "org-first" => Page("repositories", []),
                    "repositories.list" when offset == 0 => Page("repositories", [Row("repo-first", "First fictional project", "org-later")], 100),
                    "repositories.list" => Page("repositories", [Row("repo-later", "Later fictional project", "org-later")]),
                    "checkouts.list" => Page("checkouts", []),
                    _ => throw new Exception("Unexpected fictional directory operation"),
                };
                return Task.FromResult(answer);
            }
            var page = new TeamsPage(Host);
            body.Children.Add(page); body.UpdateLayout();
            static IEnumerable<DependencyObject> Descendants(DependencyObject root)
            {
                yield return root;
                for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
                    foreach (var child in Descendants(VisualTreeHelper.GetChild(root, i))) yield return child;
            }
            Button? Find(string name) => Descendants(page).OfType<Button>().SingleOrDefault(button => AutomationProperties.GetName(button) == name);
            async Task Wait(Func<bool> ready, string reason)
            {
                var deadline = DateTime.UtcNow.AddSeconds(5);
                while (!ready() && DateTime.UtcNow < deadline) { page.UpdateLayout(); await Task.Delay(20); }
                if (!ready()) throw new Exception(reason);
            }
            async Task Click(string name)
            {
                await Wait(() => Find(name) is { IsEnabled: true }, "Missing directory control: " + name);
                if (new ButtonAutomationPeer(Find(name)!).GetPattern(PatternInterface.Invoke) is not IInvokeProvider invoke) throw new Exception("Directory action is inaccessible");
                invoke.Invoke();
            }
            await Click("First fictional team");
            await Click(L10n.Text("common.teams.organizations"));
            await Click(L10n.Text("common.teams.more_organizations"));
            await Wait(() => laterRequests == 1 && Find(L10n.Text("common.teams.more_organizations")) is { IsEnabled: true }, "Failed directory page could not be retried");
            if (Find("First fictional team") is null) throw new Exception("Offline page discarded loaded teams");
            await Click(L10n.Text("common.teams.more_organizations"));
            await Click("Later fictional team");
            await Click(L10n.Text("common.teams.load_more"));
            await Wait(() => Descendants(page).OfType<TextBlock>().Any(text => text.Text == "Later fictional project"), "The later project page was unreachable");
            if (!observed.Any(row => Format.Text(row, "operation") == "repositories.list" && row["page"]?["offset"]?.GetValue<int>() == 100 && Format.Text(row, "organization") == "org-later"))
                throw new Exception("Project paging lost its exact team");
            if (observed.Any(row => Format.Text(row, "_accountSession") != "fictional-session")) throw new Exception("Directory paging lost the account receipt");
            body.Children.Remove(page);
            Program.Log("PASS: production Teams directory pages preserve results through failure and open teams/projects beyond page one");
        }
    }
}
namespace Tokenstat.Host
{
    internal sealed class HostException(string code, string message) : Exception(message)
    {
        internal string Code { get; } = code;
    }
}
namespace Tokenstat.Pages
{
    internal static class SshVaultScope
    {
        internal static JsonObject? From(JsonNode account) => Format.Flag(account, "signedIn")
            ? new JsonObject { ["kind"] = "account", ["origin"] = Format.Text(account, "host"), ["identity"] = Format.Text(account, "handle") } : null;
    }
}
