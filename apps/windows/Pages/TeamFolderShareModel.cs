// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using static Tokenstat.Pages.TeamManagementModel;

namespace Tokenstat.Pages;

internal sealed class TeamFolderShareModel(TeamDirectoryClient client, JsonObject workspace, JsonObject organization, bool durable = false)
{
    internal JsonObject Workspace { get; } = (JsonObject)workspace.DeepClone();
    internal JsonObject Organization { get; private set; } = (JsonObject)organization.DeepClone();
    internal string Name { get; set; } = Text(workspace, "name");
    internal string AccessRole { get; set; } = "contributor";
    internal HashSet<string> Included { get; } = [];
    internal TeamManagementRows Members { get; private set; } = new([]);
    internal TeamManagementRows Repositories { get; private set; } = new([]);
    internal JsonObject? Existing { get; private set; }
    internal JsonObject? Created { get; private set; }
    internal JsonObject? SavedSetup { get; private set; }
    internal bool NeedsRepositoryChoice => Flag(SavedSetup, "needsRepositoryChoice");
    private string _requestId = Guid.NewGuid().ToString();
    private TeamPublicationReview? _review;
    private string[]? _reviewedMembers;
    private string? _reviewedAccess;
    internal bool Locked => SavedSetup is not null || Created is not null || _reviewedMembers is not null;
    internal bool CanShare => Verified && (SavedSetup is not null ? !NeedsRepositoryChoice || Existing is not null
        : Existing is not null || CanCreate && ValidName(Name) && (Locked || Collision is null));
    internal bool Verified { get; private set; }
    internal bool CanCreate => Verified && Text(Organization, "role") is "owner" or "admin";
    internal JsonObject? Collision => Repositories.Rows.FirstOrDefault(row => Text(row, "name") == Name.Trim());
    private string Org => Text(Organization, "id");
    internal async Task Load()
    {
        var details = await client.Request("organizations.get", new() { ["organization"] = Org });
        var org = details["organization"] as JsonObject ?? throw new InvalidDataException();
        Require(Text(org, "id") == Org && Text(org, "state") == "active" && Flag(org, "eligible"));
        Organization = org;
        await LoadRepositories(); if (durable) await RestoreSetup(); await LoadMembers();
        if (SavedSetup is not null)
        {
            for (var page = 0; Members.Next is not null && page < 10; page++) await LoadMembers(true);
            Require(Members.Next is null);
        }
        Verified = true;
    }
    internal async Task LoadRepositories(bool more = false)
    {
        var offset = more ? Repositories.Next ?? throw new InvalidDataException() : 0;
        var page = TeamDirectoryPage.Read(await client.Request("repositories.list", new() { ["organization"] = Org, ["page"] = new JsonObject { ["limit"] = 100, ["offset"] = offset } }), "repositories", offset);
        Require(page.Rows.All(row => Text(row, "organizationId") == Org));
        Repositories = new(more ? TeamCatalogPage.Append(Repositories.Rows, page.Rows) : page.Rows, page.Next, true);
    }
    internal async Task LoadMembers(bool more = false)
    {
        var offset = more ? Members.Next ?? throw new InvalidDataException() : 0;
        var page = TeamDirectoryPage.Read(await client.Request("members.list", new() { ["organization"] = Org, ["page"] = new JsonObject { ["limit"] = 100, ["offset"] = offset } }), "members", offset);
        Members = new(more ? TeamCatalogPage.Append(Members.Rows, page.Rows) : page.Rows, page.Next, true);
        if (!Locked) foreach (var row in page.Rows.Where(row => Text(row, "id") != client.Person && Flag(row, "eligible"))) Included.Add(Text(row, "id"));
    }
    internal void ChooseExisting(string? id)
    {
        Require(!Locked || NeedsRepositoryChoice); Existing = id is null ? null : Repositories.Rows.Single(row => Text(row, "id") == id && Text(row, "role") is "contributor" or "maintainer");
    }
    internal async Task<(JsonObject Repository, JsonObject Publication)> Share()
    {
        if (durable) return await ShareDurably();
        Require(Verified && (Existing is not null || CanCreate && ValidName(Name)) && AccessRole is "viewer" or "contributor");
        if (Created is null && Existing is null)
        {
            // A name collision always requires a fresh, explicit decision to
            // use the existing project. Never attach a folder by name alone.
            Require(Collision is null);
            var result = await client.Request("repositories.create", new() { ["organization"] = Org, ["name"] = Name.Trim() });
            var created = result["repository"] as JsonObject ?? throw new InvalidDataException();
            Require(Text(created, "organizationId") == Org && Text(created, "id").Length > 0 && Text(created, "name") == Name.Trim() && Text(created, "role") == "maintainer");
            Created = created;
        }
        var repository = Created ?? Existing!;
        if (_reviewedMembers is null)
        {
            Require(Included.All(id => Members.Rows.Any(row => Text(row, "id") == id && Flag(row, "eligible") && id != client.Person)));
            _reviewedMembers = Included.Order(StringComparer.Ordinal).ToArray(); _reviewedAccess = AccessRole;
        }
        if (Created is not null)
        {
            var members = new List<JsonObject>(); var offset = 0;
            while (true)
            {
                var page = TeamDirectoryPage.Read(await client.Request("repositories.members", new() { ["organization"] = Org, ["repository"] = Text(repository, "id"), ["page"] = new JsonObject { ["limit"] = 100, ["offset"] = offset } }), "members", offset);
                members = TeamCatalogPage.Append(members, page.Rows); if (page.Next is not { } next) break; offset = next;
            }
            var grants = new List<JsonObject>();
            foreach (var id in _reviewedMembers)
            {
                var member = members.SingleOrDefault(row => Text(row, "id") == id) ?? throw new InvalidDataException();
                Require(Flag(member, "eligible"));
                if (Text(member, "role") == _reviewedAccess || Text(member, "role") == "maintainer") continue;
                Require(member["role"] is null && Revision(member) == 0); grants.Add(member);
            }
            foreach (var member in grants) await client.Request("repositories.access", new() { ["organization"] = Org, ["repository"] = Text(repository, "id"), ["user"] = Text(member, "id"),
                ["input"] = new JsonObject { ["role"] = _reviewedAccess, ["expectedRevision"] = Revision(member) } });
        }
        var publisher = new TeamPublisherModel(client, repository);
        _review ??= await publisher.PrepareCheckout(Text(Workspace, "id"));
        var answer = await publisher.PublishCheckout(_review);
        return (repository, answer["publication"]!.AsObject());
    }

    private async Task RestoreSetup()
    {
        var answer = await client.Call("teams.projectSharing.read", new() { ["organization"] = Org, ["workspace"] = Text(Workspace, "id") });
        SavedSetup = answer["setup"] as JsonObject;
        if (SavedSetup is null) return;
        Require(Text(SavedSetup, "organizationId") == Org && Text(SavedSetup, "workspaceId") == Text(Workspace, "id")
            && !Flag(SavedSetup, "sharesExistingChats") && !Flag(SavedSetup, "allowsAgentRuns"));
        Name = Text(SavedSetup, "name"); AccessRole = Text(SavedSetup, "role");
        Included.Clear(); foreach (var id in SavedSetup["memberIds"]!.AsArray()) Included.Add(id!.GetValue<string>());
        Existing = null;
    }

    private async Task<(JsonObject Repository, JsonObject Publication)> ShareDurably()
    {
        Require(CanShare && AccessRole is "viewer" or "contributor");
        try
        {
            if (SavedSetup is null)
            {
                var fields = new JsonObject { ["organization"] = Org, ["workspace"] = Text(Workspace, "id"),
                    ["name"] = Existing is null ? Name.Trim() : Text(Existing, "name"),
                    ["memberIds"] = new JsonArray(Existing is null ? Included.Order(StringComparer.Ordinal).Select(id => (JsonNode?)JsonValue.Create(id)).ToArray() : []),
                    ["role"] = AccessRole, ["requestId"] = _requestId, ["confirmSharing"] = true };
                if (Existing is not null) fields["repository"] = Text(Existing, "id");
                SavedSetup = (await client.Call("teams.projectSharing.begin", fields))["setup"]!.AsObject();
                Require(Text(SavedSetup, "organizationId") == Org && Text(SavedSetup, "workspaceId") == Text(Workspace, "id"));
            }
            var resume = new JsonObject { ["setup"] = Text(SavedSetup, "id"), ["confirmSharing"] = true };
            if (NeedsRepositoryChoice && Existing is not null) resume["repository"] = Text(Existing, "id");
            var reply = await client.Call("teams.projectSharing.resume", resume);
            var repository = reply["repository"] as JsonObject ?? throw new InvalidDataException();
            var publication = reply["publication"] as JsonObject ?? throw new InvalidDataException();
            Require(Text(repository, "organizationId") == Org && Text(publication, "repositoryId") == Text(repository, "id")
                && Text(publication, "workspaceId") == Text(Workspace, "id") && Text(publication, "phase") == "active");
            return (repository, publication);
        }
        catch
        {
            try { await LoadRepositories(); await RestoreSetup(); }
            catch { Verified = false; }
            throw;
        }
    }

    internal async Task DiscardSetup()
    {
        Require(durable && SavedSetup is not null);
        await client.Call("teams.projectSharing.discard", new() { ["setup"] = Text(SavedSetup, "id"), ["confirmDiscard"] = true });
        SavedSetup = null; Created = null; Existing = null; _reviewedMembers = null; _reviewedAccess = null;
        _requestId = Guid.NewGuid().ToString(); Name = Text(Workspace, "name"); Included.Clear(); await Load();
    }
}
