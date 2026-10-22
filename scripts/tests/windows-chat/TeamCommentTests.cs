// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Tokenstat.Pages;

internal static class TeamCommentTests
{
    private static void Check(bool answer, string message) { if (!answer) throw new Exception(message); }
    private static void Refuses(Action action) { try { action(); throw new Exception("expected refusal"); } catch (TeamDraftException) { } }
    private static JsonObject Receipt(TeamCommentTarget t, TeamCommentDraft d, string state) => new() {
        ["shareId"] = t.Share, ["clientMessageId"] = d.Attempt!.Id, ["state"] = state,
        ["sequence"] = state == "accepted" ? 0UL : null, ["acceptedAtMs"] = state == "accepted" ? 1L : null,
    };
    internal static async Task RunAsync()
    {
        var directory = Path.Combine(Path.GetTempPath(), "tokenstat-team-comment-tests-" + Guid.NewGuid());
        try
        {
            var store = new TeamCommentDraftStore(directory);
            var target = new TeamCommentTarget("https://fixture.invalid", "person-fixture", "org-fixture", "repo-fixture", "checkout-fixture", "share-fixture", "host-fixture");
            var original = store.Save(target, "  literal words 🙂\n", null, "Fictional chat")!;
            var reserved = store.Reserve(target, original);
            var restarted = new TeamCommentDraftStore(directory);
            Check(restarted.Load(target) == reserved && restarted.Reserve(target, reserved) == reserved, "restart and retry keep exact words, ID and original time");
            Refuses(() => store.Save(target, "changed", reserved, "label"));
            Check(store.Unsaved(target)?.Text == "changed", "editing an uncertain attempt retains an unsaved copy");
            store.ForgetUnsaved(target);
            Check(store.Resolve(target, reserved, Receipt(target, reserved, "unknown")) == reserved, "unknown receipt retains exact pending attempt");
            var foreign = Receipt(target, reserved, "accepted"); foreign["shareId"] = "another-share";
            Refuses(() => store.Resolve(target, reserved, foreign));
            var malformed = Receipt(target, reserved, "accepted"); malformed["sequence"] = -1;
            Refuses(() => store.Resolve(target, reserved, malformed));
            Check(store.Load(target) == reserved, "foreign or malformed receipts preserve pending writing");
            var released = store.Resolve(target, reserved, Receipt(target, reserved, "notAccepted"))!;
            Check(released.Attempt is null && released.Text == original.Text && released.Revision != reserved.Revision, "definite rejection releases words for editing");
            var later = store.Save(target, "new writing", released, "label")!;
            Refuses(() => store.Resolve(target, reserved, Receipt(target, reserved, "accepted")));
            Check(store.Load(target) == later, "a late accepted reply cannot erase a newer draft");
            Refuses(() => store.Save(target, "other window", released, "label"));
            Check(store.Unsaved(target)?.Text == "other window", "CAS conflict keeps the losing window's words available to copy");
            var review = store.List(target.Origin, target.Person).Entries.Single();
            store.Remember(target, "newer unsaved words", later, "label");
            Refuses(() => store.Discard(review));
            store.ForgetUnsaved(target);
            var fresh = store.List(target.Origin, target.Person).Entries.Single();
            store.Discard(fresh);
            Check(store.Load(target) is null, "explicit removal only removes the reviewed local version");
            Check(store.List(target.Origin, "another-person").Entries.Count == 0, "recovery never lists another person's writing");
            foreach (var other in new[] { target with { Origin = "https://other.invalid" }, target with { Person = "other" }, target with { Host = "other" }, target with { Share = "other" }, target with { Checkout = "other" } })
                Check(store.Load(other) is null, "draft target identity includes origin, person, physical publisher and resource");
            Check(!new TeamCommentDraft("", new string('é', 4097), null, "").CanSend, "send limit is UTF-8 bytes");
            Check(!new TeamCommentDraft("", new string('\u0001', 3000), null, "").CanSend, "escaped payload budget is bounded independently");
            var overlong = store.Save(target, new string('x', 8193), null, "label")!;
            Refuses(() => store.Reserve(target, overlong));
            var corruptPath = Directory.EnumerateFiles(directory, "*.json", SearchOption.AllDirectories).Single();
            File.WriteAllText(corruptPath, "{broken");
            Refuses(() => { try { store.Load(target); } catch (System.Text.Json.JsonException) { throw new TeamDraftException("comment_save_failed"); } });
            Check(store.List(target.Origin, target.Person).Unreadable && File.Exists(corruptPath), "corruption stays visible and is never silently discarded");
            File.Delete(corruptPath);
            var sentInputs = new List<string>();
            var model = new TeamCommentModel(store, target, "label", (method, body) => {
                sentInputs.Add(body["input"]!.ToJsonString()); throw new IOException("reply lost");
            });
            await model.RestoreAsync(); model.Edit("one literal message"); await model.SendAsync();
            Check(model.Pending && store.Load(target)?.Text == "one literal message", "lost send reply keeps a durable reservation");
            await model.SendAsync();
            Check(sentInputs.Count == 2 && sentInputs[0] == sentInputs[1], "explicit resend sends the identical immutable input");
            var second = new TeamCommentModel(new TeamCommentDraftStore(directory), target, "label", (method, body) => Task.FromResult<JsonNode>(new JsonObject { ["receipt"] = Receipt(target, store.Load(target)!, "accepted") }));
            await second.RestoreAsync();
            Check(second.Pending && second.Text == "one literal message", "new view recovers an uncertain send after app restart");
            await second.CheckAsync();
            Check(!second.Pending && second.Text.Length == 0 && store.Load(target) is null, "validated receipt check clears exactly the accepted attempt, including sequence zero");
            var failedPath = Path.Combine(directory, "not-a-directory"); File.WriteAllText(failedPath, "fixture");
            var sent = false;
            var blocked = new TeamCommentModel(new TeamCommentDraftStore(failedPath), target, "label", (_, _) => { sent = true; throw new Exception(); });
            await blocked.RestoreAsync(); blocked.Edit("words"); await blocked.SendAsync();
            Check(!sent && !blocked.Loaded, "unavailable storage cannot send without a durable attempt");
            Console.WriteLine("Teams comments: durable exact retries, strict receipts, account/resource isolation, CAS, recovery and storage failure pass.");
        }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
    }
}
