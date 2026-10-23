// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Tokenstat.Pages;

/// A Team operation stays bound to the login that opened its review.
internal sealed class TeamDirectoryClient(JsonObject scope, string? session, string person,
    Func<string, JsonObject?, Task<JsonNode>> call)
{
    private readonly JsonObject _scope = (JsonObject)scope.DeepClone();
    internal string Person { get; } = person;
    internal string Origin => TeamManagementModel.Text(_scope, "origin");
    internal async Task<JsonNode> Call(string method, JsonObject? fields = null)
    {
        var body = (JsonObject?)fields?.DeepClone() ?? new();
        body["_accountScope"] = _scope.DeepClone();
        if (session is not null) body["_accountSession"] = session;
        return await call(method, body);
    }
    internal Task<JsonNode> Request(string operation, JsonObject? fields = null)
    {
        var body = (JsonObject?)fields?.DeepClone() ?? new(); body["operation"] = operation;
        return Call("teams.directory", body);
    }
    internal async Task<JsonObject> Create(string name, string slug)
    {
        TeamManagementModel.Require(TeamManagementModel.ValidName(name) && TeamManagementModel.ValidSlug(slug));
        var answer = await Request("organizations.create", new() { ["input"] = new JsonObject { ["name"] = name.Trim(), ["slug"] = slug } });
        var org = answer["organization"] as JsonObject ?? throw new InvalidDataException();
        TeamManagementModel.Require(TeamManagementModel.Text(org, "id").Length > 0 && TeamManagementModel.Text(org, "ownerId") == Person && TeamManagementModel.Text(org, "role") == "owner");
        return org;
    }
    internal string InvitationUrl(JsonNode reply)
    {
        var url = TeamManagementModel.Text(reply, "invitationURL");
        TeamManagementModel.Require(Uri.TryCreate(url, UriKind.Absolute, out var uri) && Uri.TryCreate(Origin, UriKind.Absolute, out var origin)
            && uri.Scheme == origin.Scheme && uri.Authority == origin.Authority && uri.UserInfo.Length == 0);
        return url;
    }
}

internal sealed record TeamManagementRows(List<JsonObject> Rows, int? Next = null, bool Loaded = false);

/// Frozen row revisions and explicit permission checks complement the service's
/// authoritative validation. Read pagination is never attached to a write.
internal sealed class TeamManagementModel(TeamDirectoryClient client, JsonObject initial)
{
    internal static string Text(JsonNode? node, string key) => node?[key] is JsonValue value && value.TryGetValue<string>(out var text) ? text : "";
    internal static bool Flag(JsonNode? node, string key) => node?[key] is JsonValue value && value.TryGetValue<bool>(out var flag) && flag;
    internal static void Require(bool valid) { if (!valid) throw new InvalidDataException(); }
    internal static long Revision(JsonNode node, string key = "revision")
    {
        if (node[key] is JsonValue value)
        {
            if (value.TryGetValue<long>(out var number) && number >= 0) return number;
            if (value.TryGetValue<int>(out var small) && small >= 0) return small;
        }
        throw new InvalidDataException();
    }
    internal static bool ValidName(string name) => name.Trim().Length is > 0 and <= 80;
    internal static bool ValidSlug(string slug) => Regex.IsMatch(slug, "^[a-z][a-z0-9-]{1,46}[a-z0-9]$") && !slug.Contains("--", StringComparison.Ordinal);
    internal static string SuggestedSlug(string name)
    {
        var ascii = new string(name.Normalize(NormalizationForm.FormKD).Where(c => CharUnicodeInfo.GetUnicodeCategory(c) != UnicodeCategory.NonSpacingMark).ToArray());
        var slug = Regex.Replace(ascii.ToLowerInvariant(), "[^a-z0-9]+", "-");
        return slug[..Math.Min(48, slug.Length)].Trim('-');
    }
    internal static string Handle(string value) => value.Trim().TrimStart('@').ToLowerInvariant();
    internal static bool ValidHandle(string value) => Regex.IsMatch(Handle(value), "^[a-z0-9][a-z0-9-]{1,31}$");
    internal string OrganizationId { get; } = Text(initial, "id") is { Length: > 0 } id ? id : throw new InvalidDataException();
    internal JsonObject Organization { get; private set; } = (JsonObject)initial.DeepClone();
    internal JsonObject? OwnershipRequest { get; private set; }
    internal TeamManagementRows Members { get; private set; } = new([]);
    internal TeamManagementRows Repositories { get; private set; } = new([]);
    internal TeamManagementRows Invitations { get; private set; } = new([]);
    internal bool Busy { get; private set; }
    internal bool Verified { get; private set; }
    internal string Role => Text(Organization, "role");
    internal bool Active => Verified && Text(Organization, "state") == "active" && Flag(Organization, "eligible");
    internal bool Manager => Active && Role is "owner" or "admin";
    internal bool Owner => Active && Role == "owner";
    internal bool CurrentOwner => Verified && Role == "owner";
    private Task<JsonNode> Request(string operation, JsonObject? fields = null)
    {
        var body = (JsonObject?)fields?.DeepClone() ?? new(); body["organization"] = OrganizationId;
        return client.Request(operation, body);
    }
    internal TeamManagementRows Rows(string section) => section switch { "members" => Members, "repositories" => Repositories, "invitations" => Invitations, _ => new([]) };
    internal async Task Refresh(string section, bool more = false)
    {
        Require(!Busy); Busy = true;
        try
        {
            if (!more)
            {
                Verified = false;
                var details = await Request("organizations.get");
                var org = details["organization"] as JsonObject ?? throw new InvalidDataException();
                Require(Text(org, "id") == OrganizationId); Revision(org);
                Organization = org; OwnershipRequest = details["ownershipRequest"] as JsonObject; Verified = true;
                if (!Manager) Invitations = new([], Loaded: true);
            }
            if (section is not ("members" or "repositories" or "invitations") || section == "invitations" && !Manager) return;
            var before = Rows(section);
            if (more && before.Next is null) return;
            var offset = more ? before.Next!.Value : 0;
            var page = TeamDirectoryPage.Read(await Request(section + ".list", new() { ["page"] = new JsonObject { ["limit"] = 100, ["offset"] = offset } }), section, offset);
            if (section != "members") Require(page.Rows.All(row => Text(row, "organizationId") == OrganizationId));
            var rows = new TeamManagementRows(more ? TeamCatalogPage.Append(before.Rows, page.Rows) : page.Rows, page.Next, true);
            switch (section) { case "members": Members = rows; break; case "repositories": Repositories = rows; break; case "invitations": Invitations = rows; break; }
        }
        finally { Busy = false; }
    }
    internal JsonObject Rename(string name)
    {
        Require(Manager && ValidName(name)); return new() { ["name"] = name.Trim(), ["expectedRevision"] = Revision(Organization) };
    }
    internal JsonObject MemberRole(JsonObject member, string role)
    {
        Require(Owner && Text(member, "id").Length > 0 && Text(member, "id") != client.Person && Text(member, "role") is "member" or "admin" && role is "member" or "admin");
        return new() { ["role"] = role, ["expectedRevision"] = Revision(member) };
    }
    internal JsonObject RemoveMember(JsonObject member)
    {
        Require(Manager && Text(member, "id").Length > 0 && Text(member, "id") != client.Person && Text(member, "role") is "member" or "admin" && (Owner || Text(member, "role") == "member"));
        return new() { ["expectedRevision"] = Revision(member) };
    }
    internal JsonObject Invite(string handle, string role, IReadOnlyDictionary<string, string> assignments)
    {
        Require(Manager && ValidHandle(handle) && (role == "member" || Owner && role == "admin") && assignments.Count <= 50);
        Require(assignments.All(item => Repositories.Rows.Any(row => Text(row, "id") == item.Key) && item.Value is "viewer" or "contributor" or "maintainer"));
        return new() { ["handle"] = Handle(handle), ["role"] = role, ["assignments"] = new JsonArray(assignments.OrderBy(item => item.Key, StringComparer.Ordinal)
            .Select(item => (JsonNode)new JsonObject { ["repositoryId"] = item.Key, ["role"] = item.Value }).ToArray()) };
    }
    internal JsonObject Access(JsonObject repository, JsonObject member, string? role)
    {
        Require(Active && (Manager || Text(repository, "role") == "maintainer") && Text(repository, "organizationId") == OrganizationId
            && Text(member, "id").Length > 0 && role is null or "viewer" or "contributor" or "maintainer");
        return new() { ["role"] = role, ["expectedRevision"] = Revision(member) };
    }
    private void OriginalOrganization(JsonObject expected) => Require(Verified && Text(expected, "id") == OrganizationId && Revision(expected) == Revision(Organization));
    internal JsonObject Transfer(JsonObject member, JsonObject expected)
    {
        OriginalOrganization(expected);
        Require(CurrentOwner && Text(member, "id").Length > 0 && Text(member, "id") != Text(Organization, "ownerId") && Flag(member, "ownershipEligible"));
        return new() { ["userId"] = Text(member, "id"), ["expectedRevision"] = Revision(expected) };
    }
    internal JsonObject Delete(string typedName, JsonObject expected)
    {
        OriginalOrganization(expected); Require(CurrentOwner && typedName == Text(expected, "name"));
        return new() { ["confirmName"] = typedName, ["expectedRevision"] = Revision(expected) };
    }
    internal JsonObject Leave(JsonObject expected)
    {
        OriginalOrganization(expected); Require(Role is "member" or "admin" && client.Person.Length > 0);
        var revision = Revision(expected, "membershipRevision"); Require(revision > 0 && revision == Revision(Organization, "membershipRevision"));
        return new() { ["expectedRevision"] = revision };
    }
    internal JsonObject OwnershipDecision(JsonObject reviewed, bool cancelling)
    {
        Require(Verified && JsonNode.DeepEquals(reviewed, OwnershipRequest) && Text(reviewed, "requestId").Length > 0);
        Require(cancelling ? CurrentOwner && Text(reviewed, "fromUserId") == client.Person : Text(reviewed, "toUserId") == client.Person && Flag(reviewed, "current"));
        return new() { ["requestId"] = Text(reviewed, "requestId"), ["expectedRevision"] = Revision(reviewed) };
    }
    internal async Task<JsonNode> Mutate(string operation, JsonObject input, string? user = null, string? repository = null, string? invitation = null)
    {
        Require(!Busy && Verified);
        var permitted = operation switch {
            "members.role" => Owner,
            "members.remove" => user == client.Person ? Role is "member" or "admin" : Manager,
            "organizations.delete" or "ownership.request" => CurrentOwner,
            "ownership.accept" => OwnershipRequest is not null && JsonNode.DeepEquals(input, OwnershipDecision(OwnershipRequest, false)),
            "ownership.cancel" => OwnershipRequest is not null && JsonNode.DeepEquals(input, OwnershipDecision(OwnershipRequest, true)),
            "repositories.access" => Active && (Manager || Repositories.Rows.Any(row => Text(row, "id") == repository && Text(row, "role") == "maintainer")),
            "organizations.rename" or "invitations.create" or "invitations.renew" or "invitations.revoke" => Manager,
            _ => false,
        };
        Require(permitted); Busy = true;
        try
        {
            var fields = new JsonObject { ["input"] = input.DeepClone() };
            if (user is not null) fields["user"] = user;
            if (repository is not null) fields["repository"] = repository;
            if (invitation is not null) fields["invitation"] = invitation;
            return await Request(operation, fields);
        }
        finally { Busy = false; }
    }
    internal async Task<TeamDirectoryPage> RepositoryMembers(JsonObject repository, int offset = 0)
    {
        Require(Verified && Text(repository, "organizationId") == OrganizationId && (Manager || Text(repository, "role") == "maintainer"));
        return TeamDirectoryPage.Read(await Request("repositories.members", new() { ["repository"] = Text(repository, "id"),
            ["page"] = new JsonObject { ["limit"] = 100, ["offset"] = offset } }), "members", offset);
    }
}
