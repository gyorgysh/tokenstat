// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
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

internal static class TeamPublisherSmoke
{
    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        yield return root;
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
            foreach (var child in Descendants(VisualTreeHelper.GetChild(root, i))) yield return child;
    }
    private static async Task Wait(FrameworkElement page, Func<bool> ready, string reason)
    {
        var deadline = DateTime.UtcNow.AddSeconds(6);
        while (!ready() && DateTime.UtcNow < deadline) { page.UpdateLayout(); await Task.Delay(20); }
        if (!ready()) throw new Exception(reason);
    }
    private static Button? Find(DependencyObject page, string name) => Descendants(page).OfType<Button>().SingleOrDefault(button => AutomationProperties.GetName(button) == name);
    private static async Task Click(FrameworkElement page, string name)
    {
        await Wait(page, () => Find(page, name) is { IsEnabled: true }, "Missing publisher action: " + name);
        if (new ButtonAutomationPeer(Find(page, name)!).GetPattern(PatternInterface.Invoke) is not IInvokeProvider invoke) throw new Exception("Publisher action is inaccessible"); invoke.Invoke();
    }
    private static bool Shows(DependencyObject page, string text) => Descendants(page).OfType<TextBlock>().Any(row => row.Text == text);
    private static JsonObject Page(string key, params JsonObject[] rows) => new() { [key] = new JsonArray(rows.Select(row => row.DeepClone()).ToArray()), ["nextOffset"] = null };
    internal static async Task RunAsync(StackPanel body)
    {
        var org = new JsonObject { ["id"] = "org", ["name"] = "Fictional team", ["role"] = "owner" };
        var repo = new JsonObject { ["id"] = "repo", ["name"] = "Fictional project", ["organizationId"] = "org", ["role"] = "maintainer" };
        var publication = new JsonObject { ["id"] = "checkout", ["organizationId"] = "org", ["repositoryId"] = "repo", ["workspaceId"] = "folder", ["phase"] = "active", ["revision"] = 5L, ["accountCleanupPending"] = false };
        var checkoutShared = false; var chatShared = false; var publishAttempts = new List<JsonObject>(); var writes = new List<JsonObject>(); var granted = false;
        JsonObject? laneSettings = null;
        Task<JsonNode> Host(string method, JsonObject? fields)
        {
            if (method == "account.status") return Task.FromResult<JsonNode>(new JsonObject { ["signedIn"] = true, ["host"] = "https://fixture.invalid", ["handle"] = "fictional", ["accountId"] = "owner", ["accountSession"] = "fictional-session" });
            if (Text(fields, "_accountSession") != "fictional-session") throw new Exception("Publishing lost its captured account receipt");
            JsonNode result;
            switch (method)
            {
                case "teams.capabilities": result = new JsonObject { ["enabled"] = true, ["ready"] = true, ["actorId"] = "owner", ["canPublishCheckouts"] = true }; break;
                case "teams.directory":
                    result = Text(fields, "operation") switch {
                        "organizations.list" => Page("organizations", org), "repositories.list" => Page("repositories", repo), "checkouts.list" => Page("checkouts"),
                        "execution.list" => new JsonObject { ["revision"] = 4L, ["grants"] = new JsonArray() },
                        "repositories.members" => Page("members", new JsonObject { ["id"] = "mate", ["name"] = "Fictional teammate", ["role"] = "contributor", ["eligible"] = true }),
                        "execution.devices" => new JsonObject { ["devices"] = new JsonArray(new JsonObject { ["id"] = "machine", ["key"] = new string('d', 64), ["kind"] = "Fictional phone" }) },
                        "execution.set" => Grant(),
                        _ => throw new Exception("Unexpected publishing directory operation"),
                    }; break;
                case "teams.checkout.list": result = checkoutShared ? Page("publications", publication) : Page("publications"); break;
                case "teams.checkout.options": result = Page("workspaces", new JsonObject { ["id"] = "folder", ["name"] = "Fictional folder", ["path"] = "fictional/folder" }); break;
                case "teams.checkout.preview": result = new JsonObject { ["repository"] = repo.DeepClone(), ["workspaceId"] = "folder", ["workspaceName"] = "Fictional folder", ["preview"] = new string('a', 64), ["sharesExistingChats"] = false, ["allowsAgentRuns"] = false }; break;
                case "teams.checkout.publish":
                    publishAttempts.Add((JsonObject)fields!.DeepClone()); checkoutShared = true;
                    if (publishAttempts.Count == 1) throw new Tokenstat.Host.HostException("teams_unreachable", "Fictional lost publication reply");
                    result = new JsonObject { ["publication"] = publication.DeepClone() }; break;
                case "teams.chat.options": result = Page("chats", new JsonObject { ["id"] = "chat", ["title"] = "Private fictional chat", ["backend"] = "claude", ["shared"] = chatShared }); break;
                case "teams.chat.list": result = chatShared ? Page("publications", new JsonObject { ["id"] = "share", ["checkoutId"] = "checkout", ["conversationId"] = "chat", ["phase"] = "active", ["revision"] = 2L }) : Page("publications"); break;
                case "teams.chat.preview": result = new JsonObject { ["repository"] = repo.DeepClone(), ["conversation"] = "chat", ["checkoutId"] = "checkout", ["audience"] = "currentAndFutureRepositoryMembers", ["allowsAgentRuns"] = false, ["preview"] = new string('b', 64),
                    ["history"] = JsonNode.Parse("""{"events":[{"seq":1,"kind":"user","text":"Private fictional history"}]}""") }; break;
                case "teams.chat.publish": writes.Add((JsonObject)fields!.DeepClone()); chatShared = true; result = new JsonObject { ["publication"] = new JsonObject { ["id"] = "share", ["checkoutId"] = "checkout" } }; break;
                case "teams.lanes.get": result = new JsonObject { ["settings"] = laneSettings?.DeepClone(), ["supportsCheckoutUpdates"] = true }; break;
                case "teams.lanes.set": writes.Add((JsonObject)fields!.DeepClone()); laneSettings = (JsonObject)fields["settings"]!.DeepClone(); result = new JsonObject { ["settings"] = laneSettings.DeepClone() }; break;
                default: throw new Exception("Unexpected fictional publisher call");
            }
            return Task.FromResult(result);
            JsonNode Grant() { writes.Add((JsonObject)fields!.DeepClone()); granted = true; return new JsonObject(); }
        }
        var page = new TeamsPage(Host); body.Children.Add(page); body.UpdateLayout();
        try
        {
            await Click(page, L10n.Text("common.teams.project_settings"));
            await Click(page, L10n.Text("common.teams.share_checkout"));
            await Click(page, L10n.Text("common.teams.review_sharing"));
            await Wait(page, () => Descendants(page).OfType<CheckBox>().Any(), "Folder sharing consent missing");
            if (Find(page, L10n.Text("common.teams.share_checkout"))!.IsEnabled || checkoutShared || chatShared || granted) throw new Exception("Folder review granted sharing, history or execution implicitly");
            Descendants(page).OfType<CheckBox>().Single().IsChecked = true;
            await Click(page, L10n.Text("common.teams.share_checkout"));
            await Wait(page, () => Shows(page, "Fictional lost publication reply"), "Uncertain publication outcome missing");
            await Click(page, L10n.Text("common.teams.share_checkout"));
            await Click(page, L10n.Text("common.teams.share_chat"));
            if (publishAttempts.Count != 2 || !JsonNode.DeepEquals(publishAttempts[0], publishAttempts[1])) throw new Exception("Native publication retry changed its immutable request");
            await Click(page, L10n.Text("common.teams.review_sharing"));
            await Wait(page, () => Shows(page, "Private fictional history"), "History was not displayed before sharing");
            if (Find(page, L10n.Text("common.teams.share_chat"))!.IsEnabled || chatShared) throw new Exception("Private history skipped review consent");
            Descendants(page).OfType<CheckBox>().Single().IsChecked = true;
            await Click(page, L10n.Text("common.teams.share_chat"));
            await Wait(page, () => chatShared && Find(page, L10n.Text("common.teams.stop_sharing")) is not null, "Shared history did not reload");
            await Click(page, L10n.Text("common.back"));
            await Click(page, L10n.Text("common.teams.project_settings"));
            await Wait(page, () => Descendants(page).OfType<ComboBox>().Any(), "Workflow settings missing");
            var workflow = Descendants(page).OfType<ComboBox>().Single(); workflow.SelectedIndex = 2;
            var check = Descendants(page).OfType<TextBox>().Single(text => (string?)text.Header == L10n.Text("common.teams.check_command")); check.Text = "fictional-check --test";
            // WinUI dispatches programmatic TextChanged/SelectionChanged after
            // the property setters return, as separate routed UI events.
            await Wait(page, () => !Find(page, L10n.Text("common.save"))!.IsEnabled, "Changed-code checks did not require disclosure after their edit event");
            if (Find(page, L10n.Text("common.save"))!.IsEnabled) throw new Exception("Checks on changed code skipped disclosure");
            Descendants(page).OfType<CheckBox>().Single(box => (string?)box.Content == L10n.Text("common.teams.check_confirm")).IsChecked = true;
            await Wait(page, () => Find(page, L10n.Text("common.save"))!.IsEnabled, "Reviewed changed-code check could not be saved");
            await Click(page, L10n.Text("common.save"));
            await Wait(page, () => writes.Any(row => row["settings"] is not null), "Workflow setting not saved");
            await Wait(page, () => Descendants(page).OfType<ComboBox>().Any(box => !ReferenceEquals(box, workflow)), "Saved workflow did not reload");
            Descendants(page).OfType<ComboBox>().Single().SelectedIndex = 0;
            CheckBox? Updates() => Descendants(page).OfType<CheckBox>().SingleOrDefault(box => AutomationProperties.GetAutomationId(box) == "team.workflow.update-checkout");
            await Wait(page, () => Updates() is { Visibility: Visibility.Visible }, "Manual checkout opt-in missing");
            var unreviewedUpdates = Updates()!;
            if (unreviewedUpdates.IsChecked == true) throw new Exception("Manual checkout updates were enabled without consent");
            unreviewedUpdates.IsChecked = true;
            await Click(page, L10n.Text("common.save"));
            await Wait(page, () => laneSettings is not null && !Flag(laneSettings, "enabled") && Flag(laneSettings, "updateCheckout"), "Manual checkout opt-in was not saved separately from agent lanes");
            await Wait(page, () => Updates() is { IsChecked: true } box && !ReferenceEquals(box, unreviewedUpdates), "Checkout opt-in did not survive reload");
            var enabledUpdates = Updates()!; enabledUpdates.IsChecked = false;
            await Click(page, L10n.Text("common.save"));
            await Wait(page, () => !Flag(laneSettings, "updateCheckout"), "Checkout updates could not be turned off");
            await Wait(page, () => Updates() is { IsChecked: false } box && !ReferenceEquals(box, enabledUpdates), "Disabled checkout updates did not reload");
            await Click(page, L10n.Text("common.teams.agent_runs"));
            await Click(page, L10n.Text("common.teams.add_agent_grant"));
            await Click(page, "Fictional teammate");
            await Click(page, "Fictional phone · " + new string('d', 12));
            await Wait(page, () => Descendants(page).OfType<CheckBox>().Any(), "Host access grant warning missing");
            if (Find(page, L10n.Text("common.teams.allow_agent_runs"))!.IsEnabled || granted) throw new Exception("Execution grant skipped explicit device review");
            Descendants(page).OfType<CheckBox>().Single().IsChecked = true;
            await Click(page, L10n.Text("common.teams.allow_agent_runs"));
            await Wait(page, () => granted, "Device-specific grant was not saved");
            var grant = writes.Single(row => Text(row, "operation") == "execution.set");
            if (Text(grant["input"], "userId") != "mate" || Text(grant["input"], "deviceKey") != new string('d', 64) || Text(grant["input"], "machineId") != "machine" || Revision(grant["input"]!, "expectedRevision") != 4 || !Flag(grant["input"], "acknowledgeHostAccess")) throw new Exception("Native grant lost reviewed user, device, revision or acknowledgement");
        }
        finally { body.Children.Remove(page); }
        Program.Log("PASS: production Windows publishing reviews exact folder and history, retries original request, acknowledges changed-code checks and grants one reviewed teammate device");
    }
}
