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

internal static class TeamFolderShareSmoke
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
        await Wait(page, () => Find(page, name) is { IsEnabled: true }, "Missing folder sharing action: " + name);
        if (new ButtonAutomationPeer(Find(page, name)!).GetPattern(PatternInterface.Invoke) is not IInvokeProvider invoke) throw new Exception("Folder sharing action is inaccessible"); invoke.Invoke();
    }
    private static bool Shows(DependencyObject page, string text) => Descendants(page).OfType<TextBlock>().Any(row => row.Text == text);
    private static JsonObject Page(string key, params JsonObject[] rows) => new() { [key] = new JsonArray(rows.Select(row => row.DeepClone()).ToArray()), ["nextOffset"] = null };
    internal static async Task RunAsync(StackPanel body)
    {
        await ShareAsync(body, false); await ShareAsync(body, true); await ShareAsync(body, true, recovery: true);
        await ShareAsync(body, true, recovery: true, unavailable: true);
        Program.Log("PASS: Windows selected-folder form reviews eligible teammates and consent, explicitly chooses existing projects and opens all-teammate project discovery");
    }
    private static async Task ShareAsync(StackPanel body, bool existing, bool recovery = false, bool unavailable = false)
    {
        var org = new JsonObject { ["id"] = "org", ["name"] = "Fictional team", ["role"] = "owner", ["state"] = "active", ["eligible"] = true };
        var repo = new JsonObject { ["id"] = "repo", ["name"] = "Fictional folder", ["organizationId"] = "org", ["role"] = "maintainer" };
        var workspace = new JsonObject { ["id"] = "folder", ["name"] = "Fictional folder", ["path"] = "fictional/folder" };
        var member = new JsonObject { ["id"] = "mate", ["name"] = "Reviewed fictional teammate", ["eligible"] = true, ["role"] = null, ["revision"] = 0L };
        var created = existing; var published = false; var stoppedSetup = false; var writes = new List<JsonObject>();
        Task<JsonNode> Host(string method, JsonObject? fields)
        {
            if (method == "account.status") return Task.FromResult<JsonNode>(new JsonObject { ["signedIn"] = true, ["host"] = "https://fixture.invalid", ["handle"] = "fictional", ["accountId"] = "owner", ["accountSession"] = "fictional-session" });
            if (Text(fields, "_accountSession") != "fictional-session") throw new Exception("Project form lost its reviewed account");
            var publication = new JsonObject { ["id"] = "checkout", ["organizationId"] = "org", ["repositoryId"] = "repo", ["workspaceId"] = "folder", ["phase"] = "active", ["accountCleanupPending"] = false };
            JsonNode result;
            if (method == "teams.capabilities") result = new JsonObject { ["enabled"] = true, ["ready"] = true, ["actorId"] = "owner", ["canPublishCheckouts"] = true, ["canResumeProjectSharing"] = recovery };
            else if (method == "teams.projectSharing.read" && stoppedSetup) result = new JsonObject { ["setup"] = null };
            else if (method == "teams.projectSharing.discard" && unavailable)
            {
                if (!Flag(fields, "confirmDiscard") || Text(fields, "setup") != "setup_original") throw new Exception("Unavailable setup stopped without its review");
                writes.Add((JsonObject)fields!.DeepClone()); stoppedSetup = true; result = new JsonObject { ["setup"] = null };
            }
            else if (method == "teams.projectSharing.read" && recovery) result = new JsonObject { ["setup"] = new JsonObject {
                ["id"] = "setup_original", ["organizationId"] = "org", ["workspaceId"] = "folder", ["name"] = "Fictional folder",
                ["memberIds"] = new JsonArray("mate"), ["role"] = "viewer", ["phase"] = "creating", ["needsRepositoryChoice"] = true,
                ["sharesExistingChats"] = false, ["allowsAgentRuns"] = false }, ["workspace"] = workspace.DeepClone() };
            else if (method == "teams.projectSharing.resume" && recovery)
            {
                if (Text(fields, "setup") != "setup_original" || Text(fields, "repository") != "repo" || !Flag(fields, "confirmSharing"))
                    throw new Exception("Restored project bypassed its original setup, explicit selection or fresh consent");
                writes.Add((JsonObject)fields!.DeepClone()); published = true;
                result = new JsonObject { ["repository"] = repo.DeepClone(), ["publication"] = publication };
            }
            else if (method == "teams.directory") result = Text(fields, "operation") switch {
                "organizations.list" => unavailable ? Page("organizations") : Page("organizations", org), "organizations.get" => new JsonObject { ["organization"] = org.DeepClone() },
                "repositories.list" => created ? Page("repositories", repo) : Page("repositories"), "repositories.get" => new JsonObject { ["repository"] = repo.DeepClone() },
                "members.list" => Page("members", member, new JsonObject { ["id"] = "ineligible", ["name"] = "Ineligible fictional teammate", ["eligible"] = false }),
                "repositories.create" => Create(), "repositories.members" => Page("members", member), "repositories.access" => Grant(),
                "checkouts.list" => Page("checkouts"), _ => throw new Exception("Unexpected folder directory operation"),
            };
            else if (method == "teams.checkout.preview") result = new JsonObject { ["workspaceId"] = "folder", ["repository"] = repo.DeepClone(), ["preview"] = new string('a', 64), ["sharesExistingChats"] = false, ["allowsAgentRuns"] = false };
            else if (method == "teams.checkout.publish") { writes.Add((JsonObject)fields!.DeepClone()); published = true; result = new JsonObject { ["publication"] = publication }; }
            else if (method == "teams.checkout.list") result = published ? Page("publications", publication) : Page("publications");
            else throw new Exception("Folder flow attempted an unrelated or execution operation");
            return Task.FromResult(result);
            JsonNode Create() { if (existing) throw new Exception("Same-named project was recreated"); created = true; writes.Add((JsonObject)fields!.DeepClone()); return new JsonObject { ["repository"] = repo.DeepClone() }; }
            JsonNode Grant() { writes.Add((JsonObject)fields!.DeepClone()); return new JsonObject(); }
        }
        var page = new TeamsPage(Host, folder: workspace); body.Children.Add(page); body.UpdateLayout();
        try
        {
            if (unavailable)
            {
                await Wait(page, () => Shows(page, L10n.Text("common.teams.project_setup_team_unavailable")), "Unavailable setup was hidden behind team selection");
                await Click(page, L10n.Text("common.teams.project_setup_start_over"));
                var review = Descendants(page).OfType<CheckBox>().Single(box => (string?)box.Content == L10n.Text("common.teams.confirm_understood"));
                if (review.IsChecked == true || Find(page, L10n.Text("common.teams.project_setup_start_over"))!.IsEnabled || writes.Count != 0)
                    throw new Exception("Unavailable setup bypassed fresh confirmation");
                review.IsChecked = true; await Click(page, L10n.Text("common.teams.project_setup_start_over"));
                await Wait(page, () => stoppedSetup && !Shows(page, L10n.Text("common.teams.project_setup_team_unavailable")), "Discard did not reopen fresh sharing choices");
                if (writes.Count != 1 || created != existing || published) throw new Exception("Discard changed a project or publication");
                return;
            }
            if (!recovery)
            {
                await Wait(page, () => Descendants(page).OfType<ComboBox>().Any(), "Folder did not open team selection");
                Descendants(page).OfType<ComboBox>().Single().SelectedIndex = 1;
            }
            await Wait(page, () => Descendants(page).OfType<TextBox>().Any(), "Selected team did not load the single sharing form");
            if (recovery)
            {
                if (!Shows(page, L10n.Text("common.teams.project_setup_unknown")) || Find(page, L10n.Text("common.teams.share_project"))!.IsEnabled || writes.Count > 0)
                    throw new Exception("Saved sharing resumed without a fresh project choice");
                var mate = Descendants(page).OfType<CheckBox>().Single(box => (string?)box.Content == "Reviewed fictional teammate");
                if (mate.IsChecked != true || mate.IsEnabled) throw new Exception("Restoring the native form lost or unlocked its saved audience");
                Descendants(page).OfType<ComboBox>().Single(box => (string?)box.Header == L10n.Text("common.teams.project_details")).SelectedIndex = 1;
                await Wait(page, () => Descendants(page).OfType<CheckBox>().Any(box => (string?)box.Content == L10n.Text("common.teams.confirm_understood")), "Restored sharing lost its confirmation");
            }
            else if (existing)
            {
                if (Find(page, L10n.Text("common.teams.share_project"))!.IsEnabled || published || writes.Count > 0) throw new Exception("Same-named project silently linked the folder");
                await Click(page, L10n.Text("common.teams.use_existing_project", "Fictional folder"));
                await Wait(page, () => Shows(page, L10n.Text("common.teams.project_existing_access")), "Existing-project access decision missing");
            }
            else
            {
                var mate = Descendants(page).OfType<CheckBox>().Single(box => (string?)box.Content == "Reviewed fictional teammate");
                var ineligible = Descendants(page).OfType<CheckBox>().Single(box => (string?)box.Content == "Ineligible fictional teammate");
                if (mate.IsChecked != true || !mate.IsEnabled || ineligible.IsEnabled || ineligible.IsChecked == true) throw new Exception("Team defaults included an ineligible or unreviewed teammate");
            }
            var confirmation = Descendants(page).OfType<CheckBox>().Single(box => (string?)box.Content == L10n.Text("common.teams.confirm_understood"));
            if (Find(page, L10n.Text("common.teams.share_project"))!.IsEnabled || published) throw new Exception("Project sharing skipped explicit consent");
            confirmation.IsChecked = true;
            await Click(page, L10n.Text("common.teams.share_project"));
            await Wait(page, () => published && Shows(page, L10n.Text("common.teams.all_teammates")), "Shared folder did not open the all-teammates project view");
            var grants = writes.Where(row => Text(row, "operation") == "repositories.access").ToList();
            if (existing ? grants.Count != 0 : grants.Count != 1 || Text(grants[0], "user") != "mate" || Text(grants[0]["input"], "role") != "contributor") throw new Exception("Project access differed from the native review");
            await Click(page, L10n.Text("common.teams.shared_projects"));
            await Wait(page, () => Find(page, L10n.Text("common.teams.open_shared_project")) is not null && Shows(page, L10n.Text("common.teams.shared_from_this_computer")), "Shared project discovery did not show the publishing computer");
        }
        finally { body.Children.Remove(page); }
    }
}
