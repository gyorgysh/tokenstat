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
            var fence = new JsonObject { ["runId"] = "run_" + new string('a', 32), ["incarnation"] = new string('b', 64) };
            var root = Path.Combine(Path.GetTempPath(), "teams-ui-asks-" + Guid.NewGuid().ToString("N"));
            var binding = new TeamCommentTarget("https://fixture.invalid", "person-fixture", "org-fixture", "repo-fixture", "checkout-fixture", "share-fixture", new('a', 64));
            var recovery = new TeamAskRecoveryStore(root);
            recovery.Replace(binding, new(new JsonObject { ["text"] = "Fictional Ask", ["review"] = new string('c', 64),
                ["clientMessageId"] = Guid.NewGuid().ToString(), ["clientMessageCreatedAtMs"] = 1L }, fence), null);
            JsonNode? stopped = null;
            var calls = 0; var statusReads = 0; var stopAttempts = 0;
            Task<JsonNode> Host(string method, JsonObject? fields)
            {
                if (method == "account.status") return Task.FromResult<JsonNode>(new JsonObject {
                    ["signedIn"] = true, ["host"] = "https://fixture.invalid", ["handle"] = "fictional", ["accountId"] = "person-fixture", ["accountSession"] = "fictional-session",
                });
                if (method == "teams.capabilities") return Task.FromResult<JsonNode>(new JsonObject { ["enabled"] = true, ["ready"] = true, ["actorId"] = "person-fixture" });
                if (method == "teams.directory") return Task.FromResult<JsonNode>(new JsonObject { ["organizations"] = new JsonArray(), ["nextOffset"] = null });
                if (Format.Text(fields, "method") == "team.chat.details") { calls++; throw new Tokenstat.Host.HostException("team_connection_unavailable", "Fictional history read failure"); }
                if (Format.Text(fields, "method") == "team.chat.ask.stop")
                {
                    if (++stopAttempts == 1) throw new Tokenstat.Host.HostException("team_connection_unavailable", "Fictional Stop request failed");
                    stopped = fields?["params"]?["fence"]?.DeepClone();
                    return Task.FromResult<JsonNode>(new JsonObject { ["stopping"] = true });
                }
                if (Format.Text(fields, "method") == "team.chat.ask.status") { statusReads++; return Task.FromResult<JsonNode>(new JsonObject()); }
                throw new Exception("Unexpected fictional host call");
            }
            static IEnumerable<DependencyObject> Descendants(DependencyObject root)
            {
                yield return root;
                for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
                    foreach (var child in Descendants(VisualTreeHelper.GetChild(root, i))) yield return child;
            }
            async Task<TeamsPage> Open()
            {
                var page = new TeamsPage(Host, new TeamAskRecoveryStore(root)); body.Children.Add(page); body.UpdateLayout();
                var deadline = DateTime.UtcNow.AddSeconds(5);
                while (!Descendants(page).OfType<TextBlock>().Any(text => text.Text == L10n.Text("common.teams.no_organizations")) && DateTime.UtcNow < deadline) { page.UpdateLayout(); await Task.Delay(20); }
                if (!Descendants(page).OfType<TextBlock>().Any(text => text.Text == L10n.Text("common.teams.no_organizations")))
                    throw new Exception($"Teams directory did not initialize (loaded={page.IsLoaded}, size={page.ActualWidth}x{page.ActualHeight}, text={string.Join(" | ", Descendants(page).OfType<TextBlock>().Select(text => text.Text))})");
                const BindingFlags flags = BindingFlags.Instance | BindingFlags.NonPublic;
                var hosts = (Dictionary<string, string>)typeof(TeamsPage).GetField("_checkoutHosts", flags)!.GetValue(page)!;
                var checkout = (JsonObject)target.DeepClone(); checkout.Remove("share"); hosts[checkout.ToJsonString()] = binding.Host;
                var show = (Task<bool>)typeof(TeamsPage).GetMethod("ShowChatAsync", flags)!.Invoke(page, [target, "Fictional chat", "Fictional computer", null])!;
                if (await show) throw new Exception("Teams fixture did not exercise the history read failure");
                page.UpdateLayout(); return page;
            }
            TeamsPage? mounted = null;
            try
            {
                mounted = await Open();
                // A same-turn move can report the old Unloaded after Loaded.
                // Keep the current reader and its saved-run watch attached.
                body.Children.Remove(mounted); body.Children.Add(mounted); body.UpdateLayout();
                var deadline = DateTime.UtcNow.AddSeconds(7);
                while (!Descendants(mounted).OfType<TextBlock>().Any(text => text.Text == L10n.Text("common.teams.run_status_unconfirmed")) && DateTime.UtcNow < deadline) { mounted.UpdateLayout(); await Task.Delay(20); }
                if (statusReads == 0) throw new Exception($"The saved-run watch did not check status after page reattachment (loaded={mounted.IsLoaded}, historyReads={calls}, text={string.Join(" | ", Descendants(mounted).OfType<TextBlock>().Select(text => text.Text))})");
                if (!Descendants(mounted).OfType<TextBlock>().Any(text => text.Text == L10n.Text("common.teams.run_status_unconfirmed"))) throw new Exception("Malformed run status was not shown by the current reader");
                if (recovery.Load(binding)?.Record.Fence is null) throw new Exception("An unconfirmed status discarded the saved run");
                body.Children.Remove(mounted); mounted = await Open();
                if (calls != 2) throw new Exception("Reopening did not restore the production reader");
                var stop = Descendants(mounted).OfType<Button>().SingleOrDefault(button => AutomationProperties.GetName(button) == L10n.Text("common.teams.stop_agent"));
                if (stop is null || !stop.IsEnabled || stop.Visibility != Visibility.Visible) throw new Exception("Reopening or history failure hid the saved Stop control");
                var invoke = new ButtonAutomationPeer(stop).GetPattern(PatternInterface.Invoke) as IInvokeProvider ?? throw new Exception("Stop has no accessible invoke action");
                invoke.Invoke(); deadline = DateTime.UtcNow.AddSeconds(3);
                while ((stopAttempts == 0 || !stop.IsEnabled) && DateTime.UtcNow < deadline) await Task.Delay(20);
                if (stopAttempts != 1 || !stop.IsEnabled) throw new Exception("Failed Stop could not be retried");
                invoke.Invoke(); deadline = DateTime.UtcNow.AddSeconds(3);
                while (stopped is null && DateTime.UtcNow < deadline) await Task.Delay(20);
                if (!JsonNode.DeepEquals(fence, stopped)) throw new Exception("Stop lost the original saved run fence");
            }
            finally { if (mounted is not null) body.Children.Remove(mounted); if (Directory.Exists(root)) Directory.Delete(root, true); }
            Program.Log("PASS: production Teams restores accessible Stop from disk through page recreation, malformed status and history failure");
            await DirectoryAsync(body);
            await BackendChoicesAsync(body);
        }

        private static async Task BackendChoicesAsync(StackPanel body)
        {
            string[] ids = ["claude", "codex", "muse", "grok", "cursor", "agy", "opencode", "opencode2"];
            var advertised = true;
            var attempts = new List<JsonObject>();
            static JsonObject Page(string field, params JsonObject[] rows) => new() { [field] = new JsonArray(rows.Select(row => row.DeepClone()).ToArray()), ["nextOffset"] = null };
            Task<JsonNode> Host(string method, JsonObject? fields)
            {
                if (method == "account.status") return Task.FromResult<JsonNode>(new JsonObject {
                    ["signedIn"] = true, ["host"] = "https://fixture.invalid", ["handle"] = "fictional", ["accountId"] = "person", ["accountSession"] = "backend-session",
                });
                if (Format.Text(fields, "_accountSession") != "backend-session") throw new Exception("Backend picker lost its account receipt");
                if (method == "teams.capabilities") return Task.FromResult<JsonNode>(new JsonObject { ["enabled"] = true, ["ready"] = true, ["actorId"] = "person" });
                if (method == "teams.directory") return Task.FromResult<JsonNode>(Format.Text(fields, "operation") switch {
                    "organizations.list" => Page("organizations", new JsonObject { ["id"] = "org", ["name"] = "Fictional team" }),
                    "repositories.list" => Page("repositories", new JsonObject { ["id"] = "repo", ["name"] = "Fictional project", ["organizationId"] = "org", ["role"] = "maintainer" }),
                    "checkouts.list" => Page("checkouts", new JsonObject { ["id"] = "computer", ["deviceName"] = "Publishing computer", ["hostKey"] = "fictional-host" }),
                    _ => throw new Exception("Unexpected backend directory call"),
                });
                if (method == "teams.connection.call" && Format.Text(fields, "method") == "team.lanes")
                    return Task.FromResult<JsonNode>(new JsonObject { ["lanes"] = new JsonArray() });
                if (method == "teams.connection.call" && Format.Text(fields, "method") == "team.chat.catalog")
                {
                    var result = new JsonObject { ["shares"] = new JsonArray() };
                    if (advertised) result["backends"] = new JsonArray(ids.Select(id => (JsonNode)new JsonObject { ["id"] = id, ["label"] = "Publisher " + id }).ToArray());
                    return Task.FromResult<JsonNode>(result);
                }
                if (method == "teams.ask" && Format.Text(fields, "method") == "team.chat.new")
                {
                    attempts.Add((JsonObject)fields!["params"]!.DeepClone());
                    throw new Tokenstat.Host.HostException("teams_unreachable", "Fictional lost creation reply");
                }
                throw new Exception("Backend picker attempted local discovery or an unrelated method");
            }
            static IEnumerable<DependencyObject> Descendants(DependencyObject root)
            {
                yield return root;
                for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
                    foreach (var child in Descendants(VisualTreeHelper.GetChild(root, i))) yield return child;
            }
            var page = new TeamsPage(Host);
            ComboBox Agent() => Descendants(page).OfType<ComboBox>().Single(box => box.Header as string == L10n.Text("common.teams.agent"));
            TextBox Title() => Descendants(page).OfType<TextBox>().Single(box => box.Header as string == L10n.Text("common.teams.new_chat_title"));
            Button Start() => Descendants(page).OfType<Button>().Single(button => AutomationProperties.GetName(button) == L10n.Text("common.teams.new_chat"));
            async Task Wait(Func<bool> ready)
            {
                var deadline = DateTime.UtcNow.AddSeconds(5);
                while (!ready() && DateTime.UtcNow < deadline) { page.UpdateLayout(); await Task.Delay(20); }
                if (!ready()) throw new Exception("Publisher backend UI did not settle");
            }
            async Task Send()
            {
                var before = attempts.Count;
                if (new ButtonAutomationPeer(Start()).GetPattern(PatternInterface.Invoke) is not IInvokeProvider invoke) throw new Exception("New-chat action is inaccessible");
                invoke.Invoke();
                await Wait(() => attempts.Count == before + 1 && Start().IsEnabled);
            }
            body.Children.Add(page); body.UpdateLayout();
            try
            {
                await Wait(() => Descendants(page).OfType<ComboBox>().Any(box => box.Header as string == L10n.Text("common.teams.agent") && box.Items.Count == 9));
                var choices = Agent().Items.OfType<ComboBoxItem>().ToArray();
                if (!choices.Skip(1).Select(item => item.Tag as string).SequenceEqual(ids) || choices[6].Content as string != "Publisher agy")
                    throw new Exception("The Team picker did not use the publishing computer's complete catalog");
                Title().Text = "Retained backend draft";
                foreach (var id in ids)
                {
                    Agent().SelectedValue = id;
                    await Task.Delay(20);
                    await Send();
                    if (Format.Text(attempts[^1], "backend") != id || Title().Text != "Retained backend draft") throw new Exception("The selected publisher backend or draft was lost");
                }
                var original = (JsonObject)attempts[^1].DeepClone();
                advertised = false;
                const BindingFlags flags = BindingFlags.Instance | BindingFlags.NonPublic;
                await (Task)typeof(TeamsPage).GetMethod("LoadAsync", flags)!.Invoke(page, null)!;
                await Wait(() => Descendants(page).OfType<ComboBox>().Any(box => box.Header as string == L10n.Text("common.teams.agent") && box.Items.Count == 1));
                if (Title().Text != "Retained backend draft") throw new Exception("Catalog refresh cleared a new-chat draft");
                await Send();
                if (!JsonNode.DeepEquals(original, attempts[^1])) throw new Exception("Missing backend metadata changed an uncertain request's identity");
                Agent().SelectedValue = "";
                await Task.Delay(20);
                await Send();
                if (attempts[^1].ContainsKey("backend")) throw new Exception("Use Default must omit backend for an older publishing host");
            }
            finally { body.Children.Remove(page); }
            Program.Log("PASS: all publisher backends reach new-chat requests; old-host catalogs preserve drafts/retry identity and offer Default without a backend field");
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
