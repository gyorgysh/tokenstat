// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Tokenstat.Pages;
using static Tokenstat.Pages.TeamManagementModel;

internal static class TeamPublisherTests
{
    internal static async Task RunAsync()
    {
        static void Check(bool value, string message) { if (!value) throw new Exception(message); }
        static async Task Refuses(Func<Task> run) { try { await run(); } catch (InvalidDataException) { return; } throw new Exception("Unsafe publication accepted"); }
        string[] loadedCheck = ["sh", "-c", "cargo test", "", "folder with spaces"];
        Check(TeamPublisherModel.LaneCheckArguments(string.Join(" ", loadedCheck), loadedCheck).SequenceEqual(loadedCheck),
            "Saving another lane setting changed the loaded command's argument boundaries");
        Check(TeamPublisherModel.LaneCheckArguments("cargo test --workspace", loadedCheck).SequenceEqual(new[] { "cargo", "test", "--workspace" }),
            "An edited lane command did not use its new arguments");
        Check(TeamPublisherModel.LaneCheckArguments("", loadedCheck).Length == 0, "Clearing the lane check preserved old arguments");
        var repo = new JsonObject { ["id"] = "repo", ["organizationId"] = "org", ["name"] = "Fictional project" };
        var writes = new List<JsonObject>(); var lost = true; var wrong = false; var history = false;
        Task<JsonNode> Host(string method, JsonObject? fields)
        {
            Check(Text(fields, "_accountSession") == "original-session", "Publication crossed accounts");
            JsonNode reply;
            switch (method)
            {
                case "teams.checkout.preview": reply = new JsonObject { ["workspaceId"] = "folder", ["repository"] = repo.DeepClone(), ["sharesExistingChats"] = history, ["allowsAgentRuns"] = false, ["preview"] = new string('a', 64) }; break;
                case "teams.chat.preview": reply = new JsonObject { ["conversation"] = "chat", ["checkoutId"] = wrong ? "another" : "checkout", ["repository"] = repo.DeepClone(), ["audience"] = "currentAndFutureRepositoryMembers", ["allowsAgentRuns"] = false,
                    ["preview"] = new string('b', 64), ["history"] = new JsonObject { ["events"] = new JsonArray() } }; break;
                case "teams.checkout.publish":
                    writes.Add((JsonObject)fields!.DeepClone()); if (lost) { lost = false; throw new IOException("Fictional lost reply"); }
                    reply = new JsonObject { ["publication"] = new JsonObject { ["id"] = "checkout", ["organizationId"] = "org", ["repositoryId"] = "repo", ["workspaceId"] = wrong ? "another" : "folder" } }; break;
                case "teams.chat.publish": writes.Add((JsonObject)fields!.DeepClone()); reply = new JsonObject { ["publication"] = new JsonObject { ["id"] = "share", ["checkoutId"] = "checkout" } }; break;
                case "teams.checkout.withdraw": case "teams.chat.withdraw": writes.Add((JsonObject)fields!.DeepClone()); reply = new JsonObject { ["withdrawn"] = true }; break;
                default: throw new Exception("Unexpected fictional publisher method");
            }
            return Task.FromResult(reply);
        }
        var client = new TeamDirectoryClient(new() { ["origin"] = "https://fixture.invalid" }, "original-session", "owner", Host);
        var model = new TeamPublisherModel(client, repo);
        history = true; await Refuses(() => model.PrepareCheckout("folder")); history = false;
        var review = await model.PrepareCheckout("folder"); Check(writes.Count == 0, "Review silently published");
        try { await model.PublishCheckout(review); } catch (IOException) { }
        await model.PublishCheckout(review);
        Check(JsonNode.DeepEquals(writes[0], writes[1]) && Text(writes[0], "requestId").Length > 0 && Flag(writes[0], "confirmSharing"), "Lost publication reply changed its original reviewed request");
        wrong = true; await Refuses(() => model.PublishCheckout(review)); await Refuses(() => model.PrepareChat("checkout", "chat")); wrong = false;
        var chat = await model.PrepareChat("checkout", "chat");
        await model.PublishChat(chat);
        Check(Flag(writes.Last(), "confirmHistory") && Text(writes.Last(), "conversation") == "chat" && Text(writes.Last(), "checkout") == "checkout", "History consent lost its exact local chat");
        await model.WithdrawChat("checkout", new() { ["id"] = "share", ["checkoutId"] = "checkout", ["revision"] = 7L });
        Check(Revision(writes.Last(), "expectedRevision") == 7 && Text(writes.Last(), "share") == "share", "Chat withdrawal lost its reviewed revision");
        await Refuses(() => model.WithdrawChat("other", new() { ["id"] = "share", ["checkoutId"] = "checkout", ["revision"] = 7L }));
        await model.WithdrawCheckout(new() { ["id"] = "checkout", ["organizationId"] = "org", ["repositoryId"] = "repo", ["revision"] = 9L });
        Check(Revision(writes.Last(), "expectedRevision") == 9 && Text(writes.Last(), "checkout") == "checkout", "Checkout withdrawal lost its reviewed revision");
        Check(writes.All(row => row["page"] is null), "Publisher write inherited a read page");
        Console.WriteLine("Windows publisher: private-history and execution exclusions, bound previews, exact lost-reply retry and reviewed withdrawal revisions pass.");
    }
}
