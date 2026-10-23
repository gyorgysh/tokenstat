// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using static Tokenstat.Pages.TeamManagementModel;

namespace Tokenstat.Pages;

internal sealed class TeamInboxModel(TeamDirectoryClient client)
{
    internal TeamManagementRows Page { get; private set; } = new([]);
    internal JsonObject? Preview { get; private set; }
    internal string? Selected { get; private set; }
    internal bool Busy { get; private set; }
    internal bool Joining { get; private set; }
    private int _generation;
    internal bool CanJoin => !Busy && !Joining && Flag(Preview, "eligible") && Flag(Preview, "available") && Text(Preview?["invitation"], "state") == "pending";
    internal async Task Load(bool more = false)
    {
        Require(!Busy && !Joining);
        if (more && Page.Next is null) return;
        Busy = true;
        try
        {
            var offset = more ? Page.Next!.Value : 0;
            var page = TeamDirectoryPage.Read(await client.Request("inbox.list", new() { ["page"] = new JsonObject { ["limit"] = 100, ["offset"] = offset } }), "invitations", offset);
            Page = new(more ? TeamCatalogPage.Append(Page.Rows, page.Rows) : page.Rows, page.Next, true);
        }
        finally { Busy = false; }
    }
    internal void Close() { if (Joining) return; _generation++; Preview = null; Selected = null; Busy = false; }
    internal async Task Review(string id)
    {
        Require(!Joining); var generation = ++_generation;
        Selected = id; Preview = null; Busy = true;
        try
        {
            var answer = await client.Request("inbox.get", new() { ["invitation"] = id });
            if (_generation != generation || Selected != id) return;
            var invitation = answer["invitation"] as JsonObject ?? throw new InvalidDataException();
            Require(Text(invitation, "id") == id && Text(invitation, "organizationId").Length > 0 && Text(invitation, "role") is "member" or "admin");
            var access = answer["repositoryAccess"] as JsonArray ?? throw new InvalidDataException();
            Require(access.Count <= 50 && access.All(row => row is JsonObject && Text(row, "repositoryId").Length > 0 && Text(row, "name").Length > 0 && Text(row, "role") is "viewer" or "contributor" or "maintainer"));
            Require(access.Select(row => Text(row, "repositoryId")).Distinct().Count() == access.Count);
            Require(answer["eligible"] is JsonValue e && e.TryGetValue<bool>(out _) && answer["available"] is JsonValue a && a.TryGetValue<bool>(out _));
            Preview = answer.AsObject();
        }
        finally { if (_generation == generation) Busy = false; }
    }
    internal async Task<JsonObject> Accept()
    {
        Require(CanJoin && Selected is not null); var id = Selected!; var org = Text(Preview!["invitation"], "organizationId");
        Joining = true;
        try
        {
            var reply = await client.Request("inbox.accept", new() { ["invitation"] = id });
            Require(Flag(reply, "joined") && Text(reply, "organizationId") == org);
            var details = await client.Request("organizations.get", new() { ["organization"] = org });
            var organization = details["organization"] as JsonObject ?? throw new InvalidDataException();
            Require(Text(organization, "id") == org); return organization;
        }
        finally { Joining = false; }
    }
}
