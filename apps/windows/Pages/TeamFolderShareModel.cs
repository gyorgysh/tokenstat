// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using static Tokenstat.Pages.TeamManagementModel;

namespace Tokenstat.Pages;

internal sealed class TeamFolderShareModel(TeamDirectoryClient client, JsonObject workspace, JsonObject organization)
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
    private TeamPublicationReview? _review;
    private string[]? _reviewedMembers;
    private string? _reviewedAccess;
    internal bool Locked => Created is not null || _reviewedMembers is not null;
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
        await LoadRepositories(); await LoadMembers(); Verified = true;
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
        Require(!Locked); Existing = id is null ? null : Repositories.Rows.Single(row => Text(row, "id") == id && Text(row, "role") is "contributor" or "maintainer");
    }
    internal async Task<(JsonObject Repository, JsonObject Publication)> Share()
    {
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
}
