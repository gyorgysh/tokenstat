// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using static Tokenstat.Pages.TeamManagementModel;

namespace Tokenstat.Pages;

/// Selection and original publication identities are owned by the publishing
/// host. Loading this model never confirms or publishes a private chat.
internal sealed class TeamChatSelectionModel(TeamPublisherModel publisher, string checkout)
{
    internal JsonObject? Selection { get; private set; }
    internal TeamManagementRows Options { get; private set; } = new([]);
    internal HashSet<string> Picked { get; } = new(StringComparer.Ordinal);
    private string _requestId = Guid.NewGuid().ToString();
    private JsonObject Fields => publisher.Target(checkout);
    internal void Choose(string id, bool included)
    {
        Require(Selection is null && Options.Rows.Any(r => Text(r, "id") == id && !Flag(r, "shared")));
        if (included) { Require(Picked.Count < 100 || Picked.Contains(id)); Picked.Add(id); } else Picked.Remove(id);
        _requestId = Guid.NewGuid().ToString();
    }
    private void Accept(JsonNode reply, string? expected = null)
    {
        var row = reply["selection"] as JsonObject;
        if (expected is not null) Require(row is not null && Text(row, "id") == expected);
        if (row is not null)
        {
            Require(Text(row, "organizationId") == publisher.Organization && Text(row, "repositoryId") == publisher.Repository
                && Text(row, "checkoutId") == checkout && row["allowsAgentRuns"]?.GetValue<bool>() == false && row["discarded"]?.GetValue<bool>() == false
                && row["items"] is JsonArray items && items.Count is > 0 and <= 100 && items.All(i => i is JsonObject && Text(i, "conversation").Length > 0));
        }
        Selection = row is null ? null : (JsonObject)row.DeepClone();
    }
    internal async Task LoadSaved() => Accept(await publisher.Call("teams.chatSharing.read", Fields));
    internal async Task LoadOptions(bool more = false)
    {
        var page = await publisher.Chats(checkout, false, more ? Options.Next ?? 0 : 0);
        Options = new(TeamCatalogPage.Append(more ? Options.Rows : [], page.Rows), page.Next, true);
    }
    internal async Task Begin()
    {
        Require(Selection is null && Picked.Count is > 0 and <= 100);
        var fields = Fields; fields["conversations"] = new JsonArray(Picked.Order(StringComparer.Ordinal).Select(id => (JsonNode?)JsonValue.Create(id)).ToArray());
        fields["requestId"] = _requestId; fields["confirmSelection"] = true;
        Accept(await publisher.Call("teams.chatSharing.begin", fields)); Require(Selection is not null);
    }
    internal async Task<TeamPublicationReview> Preview(string conversation)
    {
        Require(Selection is not null && Selection["items"]!.AsArray().Any(i => Text(i, "conversation") == conversation && !Flag(i, "shared") && !Flag(i, "skipped")));
        var fields = new JsonObject { ["selection"] = Text(Selection, "id"), ["conversation"] = conversation };
        var reply = await publisher.Call("teams.chatSharing.preview", fields); Accept(reply, Text(fields, "selection"));
        var preview = reply["preview"] as JsonObject ?? throw new InvalidDataException();
        Require(Text(preview, "conversation") == conversation && Text(preview, "checkoutId") == checkout
            && Text(preview["repository"], "id") == publisher.Repository && Text(preview["repository"], "organizationId") == publisher.Organization
            && Text(preview, "audience") == "currentAndFutureRepositoryMembers" && preview["allowsAgentRuns"]?.GetValue<bool>() == false
            && preview["history"]?["events"] is JsonArray && Text(preview, "preview").Length == 64);
        fields["preview"] = Text(preview, "preview"); fields["confirmHistory"] = true;
        return new((JsonObject)preview.DeepClone(), fields);
    }
    internal async Task Publish(TeamPublicationReview review)
    {
        Require(Selection is not null && Text(review.Fields, "selection") == Text(Selection, "id")
            && Text(review.Fields, "conversation") == Text(review.Preview, "conversation") && Text(review.Fields, "preview") == Text(review.Preview, "preview") && Flag(review.Fields, "confirmHistory"));
        Accept(await publisher.Call("teams.chatSharing.publish", review.Fields), Text(review.Fields, "selection"));
    }
    internal async Task Skip(string conversation)
    {
        Require(Selection is not null);
        var expected = Text(Selection, "id");
        Accept(await publisher.Call("teams.chatSharing.skip", new() { ["selection"] = expected, ["conversation"] = conversation, ["confirmSkip"] = true }), expected);
    }
    internal async Task Discard()
    {
        Require(Selection is not null);
        await publisher.Call("teams.chatSharing.discard", new() { ["selection"] = Text(Selection, "id"), ["confirmDiscard"] = true });
        Selection = null; Picked.Clear(); _requestId = Guid.NewGuid().ToString();
    }
}
