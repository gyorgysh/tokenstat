// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using static Tokenstat.Pages.TeamManagementModel;

namespace Tokenstat.Pages;

internal sealed record TeamPublicationReview(JsonObject Preview, JsonObject Fields);

/// The publishing computer reviews exact local resources. No preview can
/// enable existing history or agent execution as a side effect.
internal sealed class TeamPublisherModel(TeamDirectoryClient client, JsonObject repository)
{
    internal string Organization { get; } = Text(repository, "organizationId");
    internal string Repository { get; } = Text(repository, "id");
    internal JsonObject Target(string? checkout = null) => checkout is null ? new() { ["organization"] = Organization, ["repository"] = Repository }
        : new() { ["organization"] = Organization, ["repository"] = Repository, ["checkout"] = checkout };
    private static bool ExplicitFalse(JsonNode node, string key) => node[key] is JsonValue value && value.TryGetValue<bool>(out var flag) && !flag;
    private void BoundRepository(JsonNode? row) => Require(row is JsonObject && Text(row, "id") == Repository && Text(row, "organizationId") == Organization);
    internal Task<JsonNode> Call(string method, JsonObject? fields = null) => client.Call(method, fields);
    internal Task<JsonNode> Directory(string operation, JsonObject? fields = null) => client.Request(operation, fields);
    internal async Task<TeamDirectoryPage> CheckoutOptions(int offset = 0) => TeamDirectoryPage.Read(await client.Call("teams.checkout.options", new() { ["page"] = new JsonObject { ["limit"] = 100, ["offset"] = offset } }), "workspaces", offset);
    internal async Task<TeamDirectoryPage> LocalCheckouts(int offset = 0)
    {
        var fields = Target(); fields["page"] = new JsonObject { ["limit"] = 100, ["offset"] = offset };
        var page = TeamDirectoryPage.Read(await client.Call("teams.checkout.list", fields), "publications", offset);
        Require(page.Rows.All(row => Text(row, "organizationId") == Organization && Text(row, "repositoryId") == Repository)); return page;
    }
    internal async Task<TeamPublicationReview> PrepareCheckout(string workspace)
    {
        Require(workspace.Length > 0); var fields = Target(); fields["workspace"] = workspace;
        var answer = await client.Call("teams.checkout.preview", fields); BoundRepository(answer["repository"]);
        Require(Text(answer, "workspaceId") == workspace && Text(answer, "preview").Length == 64 && ExplicitFalse(answer, "sharesExistingChats") && ExplicitFalse(answer, "allowsAgentRuns"));
        fields["preview"] = Text(answer, "preview"); fields["requestId"] = Guid.NewGuid().ToString(); fields["confirmSharing"] = true;
        return new((JsonObject)answer.DeepClone(), fields);
    }
    internal async Task<JsonNode> PublishCheckout(TeamPublicationReview review)
    {
        BoundRepository(review.Preview["repository"]);
        Require(Text(review.Fields, "organization") == Organization && Text(review.Fields, "repository") == Repository
            && Text(review.Fields, "workspace") == Text(review.Preview, "workspaceId") && Text(review.Fields, "preview") == Text(review.Preview, "preview") && Flag(review.Fields, "confirmSharing"));
        var reply = await client.Call("teams.checkout.publish", review.Fields);
        var row = reply["publication"] as JsonObject ?? throw new InvalidDataException();
        Require(Text(row, "id").Length > 0 && Text(row, "organizationId") == Organization && Text(row, "repositoryId") == Repository && Text(row, "workspaceId") == Text(review.Fields, "workspace"));
        return reply;
    }
    internal async Task<JsonNode> WithdrawCheckout(JsonObject row)
    {
        Require(Text(row, "organizationId") == Organization && Text(row, "repositoryId") == Repository);
        var answer = await client.Call("teams.checkout.withdraw", new() { ["checkout"] = Text(row, "id"), ["expectedRevision"] = Revision(row) });
        Require(Flag(answer, "withdrawn")); return answer;
    }
    internal async Task<TeamDirectoryPage> Chats(string checkout, bool publications, int offset = 0)
    {
        var fields = Target(checkout); fields["page"] = new JsonObject { ["limit"] = 100, ["offset"] = offset };
        var page = TeamDirectoryPage.Read(await client.Call(publications ? "teams.chat.list" : "teams.chat.options", fields), publications ? "publications" : "chats", offset);
        if (publications) Require(page.Rows.All(row => Text(row, "checkoutId") == checkout)); return page;
    }
    internal async Task<TeamPublicationReview> PrepareChat(string checkout, string conversation)
    {
        var fields = Target(checkout); fields["conversation"] = conversation;
        var answer = await client.Call("teams.chat.preview", fields); BoundRepository(answer["repository"]);
        Require(Text(answer, "conversation") == conversation && Text(answer, "checkoutId") == checkout && Text(answer, "preview").Length == 64
            && Text(answer, "audience") == "currentAndFutureRepositoryMembers" && ExplicitFalse(answer, "allowsAgentRuns") && answer["history"]?["events"] is JsonArray);
        fields["preview"] = Text(answer, "preview"); fields["requestId"] = Guid.NewGuid().ToString(); fields["confirmHistory"] = true;
        return new((JsonObject)answer.DeepClone(), fields);
    }
    internal async Task<JsonNode> PublishChat(TeamPublicationReview review)
    {
        BoundRepository(review.Preview["repository"]);
        Require(Text(review.Fields, "organization") == Organization && Text(review.Fields, "repository") == Repository
            && Text(review.Fields, "checkout") == Text(review.Preview, "checkoutId") && Text(review.Fields, "conversation") == Text(review.Preview, "conversation")
            && Text(review.Fields, "preview") == Text(review.Preview, "preview") && Flag(review.Fields, "confirmHistory"));
        var reply = await client.Call("teams.chat.publish", review.Fields);
        Require(Text(reply["publication"], "id").Length > 0 && Text(reply["publication"], "checkoutId") == Text(review.Fields, "checkout")); return reply;
    }
    internal async Task<JsonNode> WithdrawChat(string checkout, JsonObject row)
    {
        Require(Text(row, "checkoutId") == checkout); var fields = Target(checkout);
        fields["share"] = Text(row, "id"); fields["expectedRevision"] = Revision(row);
        var answer = await client.Call("teams.chat.withdraw", fields); Require(Flag(answer, "withdrawn")); return answer;
    }
}
