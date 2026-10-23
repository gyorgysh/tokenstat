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
using static Tokenstat.Pages.TeamManagementModel;

namespace NativeUiTests;

internal static class TeamChatSelectionSmoke
{
    private static IEnumerable<DependencyObject> Nodes(DependencyObject root) {
        yield return root;
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
            foreach (var child in Nodes(VisualTreeHelper.GetChild(root, i))) yield return child;
    }
    private static async Task Wait(FrameworkElement root, Func<bool> ready) {
        for (var i = 0; i < 300 && !ready(); i++) { root.UpdateLayout(); await Task.Delay(20); }
        if (!ready()) throw new Exception("Native chat selection did not reach its expected state");
    }
    private static Button? Button(DependencyObject root, string id) => Nodes(root).OfType<Button>().SingleOrDefault(b => AutomationProperties.GetAutomationId(b) == id);
    private static async Task Click(FrameworkElement root, string id) {
        await Wait(root, () => Button(root, id) is { IsEnabled: true });
        ((IInvokeProvider)new ButtonAutomationPeer(Button(root, id)!).GetPattern(PatternInterface.Invoke)).Invoke();
    }
    internal static async Task RunAsync(StackPanel body)
    {
        JsonObject? selection = null; var writes = 0; var publications = 0;
        var repo = new JsonObject { ["id"] = "repo", ["organizationId"] = "org", ["name"] = "Fictional project" };
        JsonObject Reply() => new() { ["selection"] = selection?.DeepClone() };
        Task<JsonNode> Host(string method, JsonObject? fields) {
            if (method == "account.status") return Task.FromResult<JsonNode>(new JsonObject { ["signedIn"] = true, ["host"] = "https://fixture.invalid", ["handle"] = "fictional", ["accountId"] = "owner", ["accountSession"] = "session" });
            if (Text(fields, "_accountSession") != "session") throw new Exception("Native review lost its account receipt");
            if (method == "teams.capabilities") return Task.FromResult<JsonNode>(new JsonObject { ["enabled"] = true, ["ready"] = true, ["actorId"] = "owner", ["canReviewChatSelection"] = true, ["canPublishCheckouts"] = true, ["canPublishChats"] = true });
            if (method == "teams.directory") return Task.FromResult<JsonNode>(new JsonObject { ["organizations"] = new JsonArray(), ["nextOffset"] = null });
            if (method == "teams.chatSharing.read") return Task.FromResult<JsonNode>(Reply());
            if (method == "teams.chat.options") return Task.FromResult<JsonNode>(new JsonObject { ["chats"] = new JsonArray(new[] { "first", "second", "unselected" }.Select(id => (JsonNode)new JsonObject { ["id"] = id, ["title"] = id, ["shared"] = false }).ToArray()), ["nextOffset"] = null });
            if (method == "teams.chatSharing.begin") {
                if (!Flag(fields, "confirmSelection") || fields!["conversations"]!.AsArray().Count != 2) throw new Exception("Native review changed the chosen audience");
                writes++;
                selection = new() { ["id"] = "review", ["organizationId"] = "org", ["repositoryId"] = "repo", ["checkoutId"] = "checkout", ["allowsAgentRuns"] = false, ["discarded"] = false, ["complete"] = false,
                    ["items"] = new JsonArray(new[] { "first", "second" }.Select(id => (JsonNode)new JsonObject { ["conversation"] = id, ["title"] = id, ["available"] = true, ["shared"] = false, ["skipped"] = false }).ToArray()) };
                return Task.FromResult<JsonNode>(Reply());
            }
            if (method == "teams.chatSharing.preview") {
                var reply = Reply(); reply["preview"] = new JsonObject { ["conversation"] = Text(fields, "conversation"), ["checkoutId"] = "checkout", ["repository"] = repo.DeepClone(), ["preview"] = new string('a', 64),
                    ["audience"] = "currentAndFutureRepositoryMembers", ["allowsAgentRuns"] = false, ["history"] = new JsonObject { ["title"] = Text(fields, "conversation"), ["backend"] = "codex", ["events"] = new JsonArray(new JsonObject { ["kind"] = "user", ["seq"] = 1L, ["text"] = "Fictional private history" }) } };
                return Task.FromResult<JsonNode>(reply);
            }
            if (method == "teams.chatSharing.publish") {
                if (!Flag(fields, "confirmHistory")) throw new Exception("Native review published without fresh confirmation");
                publications++; var item = selection!["items"]!.AsArray().Single(i => Text(i, "conversation") == Text(fields, "conversation"))!;
                item["shared"] = true; selection["complete"] = publications == 2; return Task.FromResult<JsonNode>(Reply());
            }
            throw new Exception("Unexpected native chat selection operation");
        }
        var page = new TeamsPage(Host); body.Children.Add(page); body.UpdateLayout();
        try {
            await Wait(page, () => Nodes(page).OfType<TextBlock>().Any(t => t.Text == L10n.Text("common.teams.no_organizations")));
            var client = new TeamDirectoryClient(new() { ["origin"] = "https://fixture.invalid" }, "session", "owner", Host);
            var publisher = new TeamPublisherModel(client, repo);
            async Task Open() => await (Task)typeof(TeamsPage).GetMethod("ShowTeamLocalChatsAsync", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(page,
                [publisher, repo, new JsonObject { ["id"] = "checkout" }, (Func<Task>)(() => Task.CompletedTask)])!;
            await Open();
            var start = Button(page, "team.chat.selection.begin")!;
            if (start.IsEnabled || writes != 0) throw new Exception("Loading selected private chats granted sharing consent");
            foreach (var id in new[] { "first", "second" }) Nodes(page).OfType<CheckBox>().Single(b => AutomationProperties.GetAutomationId(b) == "team.chat.selection.option." + id).IsChecked = true;
            await Click(page, "team.chat.selection.begin");
            await Wait(page, () => Button(page, "team.chat.selection.review.first") is not null);
            await Open();
            if (writes != 1 || publications != 0) throw new Exception("Reopening changed or published the saved selection");
            foreach (var id in new[] { "first", "second" }) {
                await Click(page, "team.chat.selection.review." + id);
                await Wait(page, () => Nodes(page).OfType<CheckBox>().Any());
                var consent = Nodes(page).OfType<CheckBox>().Single();
                if (consent.IsChecked == true) throw new Exception("History confirmation was restored for another chat");
                consent.IsChecked = true;
                var share = Nodes(page).OfType<Button>().Single(b => AutomationProperties.GetName(b) == L10n.Text("common.teams.share_chat"));
                await Wait(page, () => share.IsEnabled);
                ((IInvokeProvider)new ButtonAutomationPeer(share).GetPattern(PatternInterface.Invoke)).Invoke();
                await Wait(page, () => Button(page, "team.chat.selection.review." + id) is null && Nodes(page).OfType<CheckBox>().All(b => b != consent));
            }
            if (publications != 2) throw new Exception("Private selection published an unselected chat");
            Program.Log("PASS: native private chat selections reopen without writes and require separate current-history confirmation");
        }
        finally { body.Children.Remove(page); }
    }
}
