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

internal static class TeamManagementSmoke
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
        await Wait(page, () => Find(page, name) is { IsEnabled: true }, "Missing enabled management action: " + name);
        if (new ButtonAutomationPeer(Find(page, name)!).GetPattern(PatternInterface.Invoke) is not IInvokeProvider invoke) throw new Exception("Management action is inaccessible");
        invoke.Invoke();
    }
    private static bool Shows(DependencyObject page, string text) => Descendants(page).OfType<TextBlock>().Any(row => row.Text == text);
    private static JsonObject Page(string key, params JsonObject[] rows) => new() { [key] = new JsonArray(rows.Select(row => row.DeepClone()).ToArray()), ["nextOffset"] = null };
    private static JsonNode Account() => new JsonObject { ["signedIn"] = true, ["host"] = "https://fixture.invalid", ["handle"] = "fictional", ["accountId"] = "owner", ["accountSession"] = "fictional-session" };
    private static JsonNode Capabilities() => new JsonObject { ["enabled"] = true, ["ready"] = true, ["actorId"] = "owner" };
    internal static async Task RunAsync(StackPanel body)
    {
        var org = new JsonObject { ["id"] = "org", ["name"] = "Fictional team", ["state"] = "active", ["role"] = "owner", ["ownerId"] = "owner", ["eligible"] = true, ["revision"] = 8L, ["membershipRevision"] = 3L };
        var member = new JsonObject { ["id"] = "member", ["name"] = "Fictional teammate", ["handle"] = "fictional-mate", ["role"] = "member", ["eligible"] = true, ["ownershipEligible"] = true, ["revision"] = 6L };
        var repo = new JsonObject { ["id"] = "repo", ["organizationId"] = "org", ["name"] = "Fictional project", ["role"] = "maintainer" };
        var access = new JsonObject { ["id"] = "member", ["name"] = "Fictional teammate", ["eligible"] = true, ["role"] = null, ["revision"] = 4L };
        var writes = new List<JsonObject>(); JsonObject? ownership = null; var deleted = false;
        Task<JsonNode> Host(string method, JsonObject? fields)
        {
            if (method == "account.status") return Task.FromResult(Account());
            if (Text(fields, "_accountSession") != "fictional-session") throw new Exception("Native management lost account receipt");
            if (method == "teams.capabilities") return Task.FromResult(Capabilities());
            if (method != "teams.directory") throw new Exception("Unexpected fictional management method");
            var operation = Text(fields, "operation");
            JsonNode result;
            switch (operation)
            {
                case "organizations.list": result = deleted ? Page("organizations") : Page("organizations", org); break;
                case "organizations.get": result = new JsonObject { ["organization"] = org.DeepClone(), ["ownershipRequest"] = ownership?.DeepClone() }; break;
                case "members.list": result = Page("members", member); break;
                case "repositories.list": result = Page("repositories", repo); break;
                case "checkouts.list": result = Page("checkouts"); break;
                case "repositories.members": result = Page("members", access); break;
                case "invitations.list": result = Page("invitations"); break;
                default:
                    if (fields?["page"] is not null || Text(fields, "organization") != "org") throw new Exception("Native mutation has wrong scope or read pagination");
                    writes.Add((JsonObject)fields!.DeepClone()); result = new JsonObject();
                    if (operation == "members.role") member["role"] = fields["input"]!["role"]!.DeepClone();
                    if (operation == "repositories.access") access["role"] = fields["input"]!["role"]?.DeepClone();
                    if (operation == "invitations.create") result = new JsonObject { ["invitationURL"] = "https://fixture.invalid/invite/fictional" };
                    if (operation == "organizations.rename") { org["name"] = fields["input"]!["name"]!.DeepClone(); org["revision"] = 9L; }
                    if (operation == "ownership.request") ownership = new() { ["requestId"] = "request", ["fromUserId"] = "owner", ["toUserId"] = "member", ["revision"] = 5L, ["current"] = true };
                    if (operation == "ownership.cancel") ownership = null;
                    if (operation == "organizations.delete") deleted = true;
                    break;
            }
            return Task.FromResult(result);
        }
        var page = new TeamsPage(Host); body.Children.Add(page); body.UpdateLayout();
        try
        {
            await Click(page, L10n.Text("common.teams.organization_settings"));
            await Click(page, L10n.Text("common.teams.change_role"));
            await Wait(page, () => Descendants(page).OfType<ComboBox>().Any(), "Native role picker missing");
            Descendants(page).OfType<ComboBox>().Single().SelectedIndex = 1;
            await Click(page, L10n.Text("common.save"));
            await Wait(page, () => writes.Any(row => Text(row, "operation") == "members.role"), "Native member role was not saved");
            var roleWrite = writes.Single(row => Text(row, "operation") == "members.role");
            if (Text(roleWrite, "user") != "member" || Revision(roleWrite["input"]!, "expectedRevision") != 6) throw new Exception("Native role review lost person or revision");
            await Click(page, L10n.Text("common.teams.invite_member"));
            await Wait(page, () => Descendants(page).OfType<TextBox>().Any(text => (string?)text.Header == L10n.Text("common.teams.tokenstat_handle")), "Native invitation form missing");
            Descendants(page).OfType<TextBox>().Single().Text = "fictional-invitee";
            await Click(page, L10n.Text("common.teams.invite_member"));
            await Wait(page, () => Shows(page, L10n.Text("common.teams.invitation_ready")), "Invitation link was not reviewed");
            var invite = writes.Single(row => Text(row, "operation") == "invitations.create");
            if (invite["input"]?["assignments"]?.AsArray().Count != 0 || Text(invite["input"], "role") != "member") throw new Exception("Untouched invitation granted access");
            await Click(page, L10n.Text("common.done"));
            await Click(page, L10n.Text("common.teams.repositories"));
            await Click(page, L10n.Text("common.teams.repository_access"));
            await Click(page, L10n.Text("common.teams.manage_access"));
            await Wait(page, () => Descendants(page).OfType<ComboBox>().Any(), "Native access picker missing");
            Descendants(page).OfType<ComboBox>().Single().SelectedIndex = 2;
            await Click(page, L10n.Text("common.save"));
            await Wait(page, () => writes.Any(row => Text(row, "operation") == "repositories.access"), "Native access change was not saved");
            var grant = writes.Single(row => Text(row, "operation") == "repositories.access");
            if (Text(grant, "repository") != "repo" || Text(grant, "user") != "member" || Text(grant["input"], "role") != "contributor" || Revision(grant["input"]!, "expectedRevision") != 4) throw new Exception("Native project access lost its exact review");
            await Click(page, L10n.Text("common.back"));
            await Click(page, L10n.Text("common.settings"));
            await Click(page, L10n.Text("common.teams.rename_organization"));
            await Wait(page, () => Descendants(page).OfType<TextBox>().Any(), "Native rename form missing");
            Descendants(page).OfType<TextBox>().Single().Text = "Renamed fictional team";
            await Click(page, L10n.Text("common.save"));
            await Wait(page, () => Text(org, "name") == "Renamed fictional team" && Find(page, L10n.Text("common.teams.transfer_ownership")) is not null, "Native team rename did not refresh settings");
            org["state"] = "paused"; org["eligible"] = false;
            await Click(page, L10n.Text("common.refresh"));
            await Click(page, L10n.Text("common.teams.transfer_ownership"));
            await Click(page, "Fictional teammate");
            await Wait(page, () => Find(page, L10n.Text("common.teams.send_ownership_request")) is not null, "Ownership review missing");
            if (Find(page, L10n.Text("common.teams.send_ownership_request"))!.IsEnabled) throw new Exception("Ownership transfer skipped confirmation");
            Descendants(page).OfType<CheckBox>().Single().IsChecked = true;
            await Click(page, L10n.Text("common.teams.send_ownership_request"));
            await Click(page, L10n.Text("common.teams.cancel_ownership_request"));
            await Wait(page, () => Descendants(page).OfType<CheckBox>().Any(), "Ownership cancellation review missing");
            Descendants(page).OfType<CheckBox>().Single().IsChecked = true;
            await Click(page, L10n.Text("common.teams.cancel_ownership_request"));
            await Wait(page, () => ownership is null && Find(page, L10n.Text("common.teams.delete_organization")) is not null, "Ownership cancellation did not refresh");
            await Click(page, L10n.Text("common.teams.delete_organization"));
            await Wait(page, () => Descendants(page).OfType<TextBox>().Any(), "Typed deletion review missing");
            if (Find(page, L10n.Text("common.teams.delete_organization"))!.IsEnabled) throw new Exception("Deletion skipped typed team name");
            Descendants(page).OfType<TextBox>().Single().Text = "Renamed fictional team";
            await Click(page, L10n.Text("common.teams.delete_organization"));
            await Wait(page, () => deleted && Shows(page, L10n.Text("common.teams.no_organizations")), "Paused owner deletion did not leave removed team");
        }
        finally { body.Children.Remove(page); }
        Program.Log("PASS: production Windows management reviews member roles, default-no-access invitations, exact project access, rename, paused ownership transfer/cancel and typed deletion");
        await InboxAsync(body);
        await OldReplyAsync(body);
    }
    private static async Task InboxAsync(StackPanel body)
    {
        var accepted = 0;
        var org = new JsonObject { ["id"] = "joined", ["name"] = "Incoming fictional team", ["role"] = "member" };
        Task<JsonNode> Host(string method, JsonObject? fields)
        {
            if (method == "account.status") return Task.FromResult(Account());
            if (method == "teams.capabilities") return Task.FromResult(Capabilities());
            if (Text(fields, "_accountSession") != "fictional-session") throw new Exception("Inbox lost account receipt");
            JsonNode result = Text(fields, "operation") switch {
                "organizations.list" => accepted == 0 ? Page("organizations") : Page("organizations", org),
                "inbox.list" => Page("invitations", new JsonObject { ["id"] = "received", ["organizationName"] = "Incoming fictional team", ["role"] = "member" }),
                "inbox.get" => new JsonObject { ["invitation"] = new JsonObject { ["id"] = "received", ["organizationId"] = "joined", ["organizationName"] = "Incoming fictional team", ["role"] = "member", ["state"] = "pending" },
                    ["eligible"] = true, ["available"] = true, ["repositoryAccess"] = new JsonArray(new JsonObject { ["repositoryId"] = "project", ["name"] = "Reviewed fictional project", ["role"] = "viewer" }) },
                "inbox.accept" when ++accepted > 0 => new JsonObject { ["joined"] = true, ["organizationId"] = "joined" },
                "organizations.get" => new JsonObject { ["organization"] = org.DeepClone() },
                "repositories.list" => Page("repositories"),
                _ => throw new Exception("Unexpected native inbox request"),
            }; return Task.FromResult(result);
        }
        var page = new TeamsPage(Host); body.Children.Add(page); body.UpdateLayout();
        try
        {
            await Click(page, L10n.Text("common.teams.invitations_for_you"));
            await Click(page, L10n.Text("common.teams.review_invitation"));
            await Wait(page, () => Shows(page, "Reviewed fictional project · " + L10n.Text("common.teams.viewer")), "Incoming project access was not shown before joining");
            if (accepted != 0) throw new Exception("Reading an invitation silently joined");
            await Click(page, L10n.Text("common.teams.join_organization"));
            await Wait(page, () => accepted == 1 && Shows(page, "Incoming fictional team") && Find(page, L10n.Text("common.teams.organization_settings")) is not null, "Explicit join did not open the reviewed team");
        }
        finally { body.Children.Remove(page); }
        Program.Log("PASS: production Windows inbox reviews the incoming project roles before explicit account-bound acceptance");
    }
    private static async Task OldReplyAsync(StackPanel body)
    {
        var pending = new TaskCompletionSource<JsonNode>(); var reading = false; var switched = false; JsonObject? reviewedFields = null;
        var org = new JsonObject { ["id"] = "old-org", ["name"] = "Old fictional team", ["role"] = "owner", ["revision"] = 1L, ["state"] = "active", ["eligible"] = true };
        Task<JsonNode> Host(string method, JsonObject? fields)
        {
            if (method == "account.status")
            {
                var account = Account(); if (switched) { account["accountSession"] = "new-session"; account["accountId"] = "new-person"; } return Task.FromResult(account);
            }
            if (method == "teams.capabilities") { var caps = Capabilities(); if (switched) caps["actorId"] = "new-person"; return Task.FromResult(caps); }
            return Text(fields, "operation") switch {
                "organizations.list" => Task.FromResult<JsonNode>(switched ? Page("organizations") : Page("organizations", org)),
                "repositories.list" or "checkouts.list" => Task.FromResult<JsonNode>(Page(Text(fields, "operation").Split('.')[0])),
                "organizations.get" => Hold(),
                "members.list" => Task.FromResult<JsonNode>(Page("members", new JsonObject { ["id"] = "old-member", ["name"] = "Old fictional member" })),
                _ => throw new Exception("Unexpected old-account operation"),
            };
            Task<JsonNode> Hold() { reading = true; reviewedFields = (JsonObject)fields!.DeepClone(); return pending.Task; }
        }
        var page = new TeamsPage(Host); body.Children.Add(page); body.UpdateLayout();
        try
        {
            await Click(page, L10n.Text("common.teams.organization_settings"));
            await Wait(page, () => reading, "Old management read was not held"); switched = true;
            await Click(page, L10n.Text("common.back"));
            await Wait(page, () => Shows(page, L10n.Text("common.teams.no_organizations")), "New login did not replace old team");
            pending.SetResult(new JsonObject { ["organization"] = org.DeepClone() });
            await Task.Delay(100); page.UpdateLayout();
            if (Shows(page, "Old fictional member") || Find(page, L10n.Text("common.teams.invite_member")) is not null || Text(reviewedFields, "_accountSession") != "fictional-session")
                throw new Exception("Old management reply crossed navigation or account scope");
        }
        finally { body.Children.Remove(page); }
        Program.Log("PASS: production Windows rejects late management replies after navigation and account replacement");
    }
}
