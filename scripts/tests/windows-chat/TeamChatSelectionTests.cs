// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Tokenstat.Pages;
using static Tokenstat.Pages.TeamManagementModel;

internal static class TeamChatSelectionTests
{
    internal static async Task RunAsync()
    {
        static void Check(bool test, string reason) { if (!test) throw new Exception(reason); }
        static async Task Refuses(Func<Task> action) { try { await action(); } catch (InvalidDataException) { return; } throw new Exception("Unbound private history review accepted"); }
        static JsonObject Chat(string id) => new() { ["id"] = id, ["title"] = id, ["shared"] = false };
        static JsonObject Item(string id) => new() { ["conversation"] = id, ["title"] = id, ["available"] = true, ["shared"] = false, ["skipped"] = false };
        var repo = new JsonObject { ["id"] = "repo", ["organizationId"] = "org" };
        JsonObject? selection = null; var writes = new List<JsonObject>(); var wrong = false; var lost = true;
        Task<JsonNode> Host(string method, JsonObject? fields)
        {
            Check(Text(fields, "_accountSession") == "session", "Chat review lost its original account receipt");
            JsonObject Result() => new() { ["selection"] = selection?.DeepClone() };
            if (method == "teams.chatSharing.read") return Task.FromResult<JsonNode>(Result());
            if (method == "teams.chat.options") {
                var later = fields!["page"]!["offset"]!.GetValue<int>() > 0;
                return Task.FromResult<JsonNode>(new JsonObject { ["chats"] = later ? new JsonArray(Chat("second"), Chat("future")) : new JsonArray(Chat("first")), ["nextOffset"] = later ? null : 1 });
            }
            if (method == "teams.chatSharing.begin") {
                writes.Add((JsonObject)fields!.DeepClone());
                selection = new() { ["id"] = "review", ["organizationId"] = "org", ["repositoryId"] = "repo", ["checkoutId"] = "checkout", ["allowsAgentRuns"] = false, ["discarded"] = false, ["complete"] = false, ["items"] = new JsonArray(Item("first"), Item("second")) };
                return Task.FromResult<JsonNode>(Result());
            }
            if (method == "teams.chatSharing.preview") {
                var reply = Result(); reply["preview"] = new JsonObject { ["conversation"] = Text(fields, "conversation"), ["checkoutId"] = wrong ? "foreign" : "checkout", ["repository"] = repo.DeepClone(),
                    ["audience"] = "currentAndFutureRepositoryMembers", ["allowsAgentRuns"] = false, ["preview"] = new string('a', 64), ["history"] = new JsonObject { ["events"] = new JsonArray() } };
                return Task.FromResult<JsonNode>(reply);
            }
            writes.Add((JsonObject)fields!.DeepClone());
            if (method == "teams.chatSharing.publish") {
                Check(Flag(fields, "confirmHistory"), "No current consent");
                selection!["items"]![0]!["shared"] = true;
                if (lost) { lost = false; throw new IOException("Fictional lost final reply"); }
            } else if (method == "teams.chatSharing.skip") selection!["items"]![1]!["skipped"] = true;
            else throw new Exception("Unexpected chat review method");
            return Task.FromResult<JsonNode>(Result());
        }
        var client = new TeamDirectoryClient(new() { ["origin"] = "https://fixture.invalid" }, "session", "owner", Host);
        var publisher = new TeamPublisherModel(client, repo);
        var model = new TeamChatSelectionModel(publisher, "checkout"); await model.LoadSaved(); await model.LoadOptions();
        model.Choose("first", true); await model.LoadOptions(true); model.Choose("second", true);
        Check(writes.Count == 0, "Opening or paging shared private history");
        await model.Begin(); Check(writes.Count == 1 && writes[0]["conversations"]!.AsArray().Count == 2, "The explicit selection changed");
        var restored = new TeamChatSelectionModel(publisher, "checkout"); await restored.LoadSaved();
        Check(writes.Count == 1 && restored.Selection!["items"]!.AsArray().Count == 2, "Restoring sent a publication or included a new chat");
        wrong = true; await Refuses(() => restored.Preview("first")); wrong = false;
        var review = await restored.Preview("first");
        var forged = new TeamPublicationReview(review.Preview, (JsonObject)review.Fields.DeepClone()); forged.Fields["selection"] = "another";
        await Refuses(() => restored.Publish(forged));
        try { await restored.Publish(review); } catch (IOException) { }
        await restored.LoadSaved();
        Check(writes.Count == 2 && Flag(restored.Selection!["items"]![0], "shared"), "Lost reply recovery sent a second publication");
        await restored.Skip("second");
        Check(writes.Count == 3 && Flag(restored.Selection!["items"]![1], "skipped"), "The explicit skip changed");
    }
}
