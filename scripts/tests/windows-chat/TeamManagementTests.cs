// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Tokenstat.Pages;
using static Tokenstat.Pages.TeamManagementModel;

internal static class TeamManagementTests
{
    private static void Check(bool value, string reason) { if (!value) throw new Exception(reason); }
    private static void Refuses(Action run) { try { run(); } catch (InvalidDataException) { return; } throw new Exception("Unsafe management input accepted"); }
    private static async Task RefusesAsync(Func<Task> run) { try { await run(); } catch (InvalidDataException) { return; } throw new Exception("Unsafe management response accepted"); }
    internal static async Task RunAsync()
    {
        var org = new JsonObject { ["id"] = "org", ["name"] = "Fictional team", ["state"] = "active", ["eligible"] = true, ["role"] = "owner", ["ownerId"] = "owner", ["revision"] = 8, ["membershipRevision"] = 3 };
        var member = new JsonObject { ["id"] = "member", ["name"] = "Fictional teammate", ["role"] = "member", ["revision"] = 6, ["ownershipEligible"] = true };
        var repo = new JsonObject { ["id"] = "repo", ["name"] = "Fictional project", ["organizationId"] = "org", ["role"] = "maintainer" };
        JsonObject? request = null; var writes = new List<JsonObject>();
        var scope = new JsonObject { ["kind"] = "account", ["origin"] = "https://fixture.invalid", ["identity"] = "owner" };
        var pageFailure = false;
        Task<JsonNode> Host(string method, JsonObject? fields)
        {
            Check(method == "teams.directory" && Text(fields, "_accountSession") == "original-session" && Text(fields?["_accountScope"], "origin") == "https://fixture.invalid", "Management changed accounts");
            var operation = Text(fields, "operation");
            if (operation == "organizations.get") return Task.FromResult<JsonNode>(new JsonObject { ["organization"] = org.DeepClone(), ["ownershipRequest"] = request?.DeepClone() });
            if (operation.EndsWith(".list", StringComparison.Ordinal))
            {
                if (fields?["page"]?["offset"]?.GetValue<int>() == 100 && pageFailure) throw new InvalidDataException();
                var section = operation.Split('.')[0];
                return Task.FromResult<JsonNode>(new JsonObject { [section] = new JsonArray((section == "members" ? member : section == "repositories" ? repo : new JsonObject { ["id"] = "invite", ["organizationId"] = "org" }).DeepClone()), ["nextOffset"] = section == "members" && fields?["page"]?["offset"]?.GetValue<int>() == 0 ? 100 : null });
            }
            Check(fields?["page"] is null, "A write inherited read pagination"); writes.Add((JsonObject)fields!.DeepClone());
            return Task.FromResult<JsonNode>(new JsonObject());
        }
        var client = new TeamDirectoryClient(scope, "original-session", "owner", Host); scope["origin"] = "https://different.invalid";
        var model = new TeamManagementModel(client, org);
        Refuses(() => model.Rename("Before fresh read"));
        await model.Refresh("members"); await model.Refresh("repositories");
        var noAccess = model.Invite("@fictional", "member", new Dictionary<string, string>());
        Check(noAccess["assignments"]!.AsArray().Count == 0, "Invitation invented project access");
        Refuses(() => model.Invite("fictional", "member", new Dictionary<string, string> { ["unreviewed"] = "contributor" }));
        await model.Mutate("members.role", model.MemberRole(member, "admin"), user: "member");
        Check(writes.Last()["input"]?["expectedRevision"]?.GetValue<long>() == 6 && Text(writes.Last(), "organization") == "org" && Text(writes.Last(), "user") == "member", "Role change lost its exact review");
        Refuses(() => model.MemberRole(new() { ["id"] = "owner", ["role"] = "owner", ["revision"] = 2 }, "member"));
        pageFailure = true; await RefusesAsync(() => model.Refresh("members", true));
        Check(model.Members.Rows.Count == 1 && model.Members.Next == 100, "Failed later page discarded members");
        var snapshot = (JsonObject)model.Organization.DeepClone();
        org["state"] = "paused"; org["eligible"] = false; org["revision"] = 9;
        await model.Refresh("settings");
        Check(model.CurrentOwner && !model.Manager, "Paused owner lost recovery or regained collaboration");
        Refuses(() => model.Rename("Forbidden")); Refuses(() => model.Transfer(member, snapshot));
        var paused = (JsonObject)model.Organization.DeepClone();
        await model.Mutate("ownership.request", model.Transfer(member, paused));
        Refuses(() => model.Delete("wrong name", paused));
        Check(Revision(model.Delete("Fictional team", paused), "expectedRevision") == 9, "Delete lost its reviewed organization revision");
        request = new() { ["requestId"] = "request", ["fromUserId"] = "owner", ["toUserId"] = "member", ["revision"] = 5, ["current"] = true };
        await model.Refresh("settings");
        Refuses(() => model.OwnershipDecision(request, false));
        var old = (JsonObject)request.DeepClone(); request["revision"] = 6; await model.Refresh("settings");
        Refuses(() => model.OwnershipDecision(old, true));
        await model.Mutate("ownership.cancel", model.OwnershipDecision(request, true));
        org["role"] = "member";
        var memberClient = new TeamDirectoryClient(new() { ["origin"] = "https://fixture.invalid" }, "original-session", "member", Host);
        var inactive = new TeamManagementModel(memberClient, org); await inactive.Refresh("settings");
        await inactive.Mutate("members.remove", inactive.Leave(inactive.Organization), user: "member");
        Check(Revision(writes.Last()["input"]!, "expectedRevision") == 3 && Text(writes.Last(), "user") == "member", "Inactive leave targeted another membership");
        await inactive.Mutate("ownership.accept", inactive.OwnershipDecision(request, false));
        Check(client.InvitationUrl(new JsonObject { ["invitationURL"] = "https://fixture.invalid/invite/example" }).Contains("/invite/", StringComparison.Ordinal), "Valid account invitation link rejected");
        Refuses(() => client.InvitationUrl(new JsonObject { ["invitationURL"] = "https://other.invalid/invite/example" }));
        Check(SuggestedSlug("Fictional Tëam") == "fictional-team" && ValidSlug("fictional-team") && !ValidSlug("no--thanks"), "Organization address validation drifted");
        await InboxAsync();
        Console.WriteLine("Windows management: exact account and row revisions, reviewed access, paused owner recovery, stale ownership, inactive leave and invitation inbox pass.");
    }
    private static async Task InboxAsync()
    {
        var gets = new Dictionary<string, TaskCompletionSource<JsonNode>>(); var accepted = 0;
        var org = new JsonObject { ["id"] = "org", ["name"] = "Fictional team" };
        var wrongOrganization = false;
        Task<JsonNode> Host(string method, JsonObject? fields)
        {
            switch (Text(fields, "operation"))
            {
                case "inbox.get": var tcs = new TaskCompletionSource<JsonNode>(); gets[Text(fields, "invitation")] = tcs; return tcs.Task;
                case "inbox.accept": accepted++; return Task.FromResult<JsonNode>(new JsonObject { ["joined"] = true, ["organizationId"] = wrongOrganization ? "another" : "org" });
                case "organizations.get": return Task.FromResult<JsonNode>(new JsonObject { ["organization"] = org.DeepClone() });
                default: throw new Exception("Unexpected inbox request");
            }
        }
        static JsonObject Preview(string id, bool available = true) => new() {
            ["invitation"] = new JsonObject { ["id"] = id, ["organizationId"] = "org", ["role"] = "member", ["state"] = "pending" },
            ["repositoryAccess"] = new JsonArray(new JsonObject { ["repositoryId"] = "repo", ["name"] = "Fictional project", ["role"] = "contributor" }), ["eligible"] = true, ["available"] = available,
        };
        var client = new TeamDirectoryClient(new() { ["origin"] = "https://fixture.invalid" }, "session", "member", Host); var model = new TeamInboxModel(client);
        await RefusesAsync(() => model.Accept());
        var first = model.Review("old"); model.Close(); var second = model.Review("current");
        gets["current"].SetResult(Preview("current")); await second; gets["old"].SetResult(Preview("old")); await first;
        Check(model.CanJoin && model.Selected == "current" && accepted == 0, "Late preview replaced review or silently joined");
        wrongOrganization = true; await RefusesAsync(() => model.Accept());
        wrongOrganization = false; Check(Text(await model.Accept(), "id") == "org" && accepted == 2, "Explicit acceptance did not navigate to reviewed team");
        var unavailable = model.Review("unavailable"); gets["unavailable"].SetResult(Preview("unavailable", false)); await unavailable;
        Check(!model.CanJoin, "Unavailable invitation could be joined");
        var malformed = model.Review("malformed"); gets["malformed"].SetResult(Preview("different")); await RefusesAsync(() => malformed);
        Check(!model.CanJoin, "Wrong invitation response granted access");
    }
}
