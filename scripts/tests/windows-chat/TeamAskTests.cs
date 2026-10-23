// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Tokenstat.Pages;

internal static class TeamAskTests
{
    internal static async Task RunAsync()
    {
        static void Check(bool value, string message) { if (!value) throw new Exception(message); }
        var root = Path.Combine(Path.GetTempPath(), "team-ask-tests-" + Guid.NewGuid().ToString("N"));
        var target = new TeamCommentTarget("https://fixture.invalid", "person-fixture", "org-fixture", "repo-fixture", "checkout-fixture", "share-fixture", new('a', 64));
        var fence = new JsonObject { ["runId"] = "run_" + new string('a', 32), ["incarnation"] = new string('b', 64) };
        try
        {
            var reviews = 0; var sends = 0; var stops = 0; var lost = true; var current = true;
            JsonObject? original = null;
            JsonObject status = new() { ["running"] = "false" };
            Task<JsonNode> Call(string method, JsonObject input)
            {
                switch (method)
                {
                    case "team.chat.ask.review":
                        reviews++; return Task.FromResult<JsonNode>(new JsonObject { ["agentRuns"] = true, ["review"] = new string('c', 64) });
                    case "team.chat.ask":
                        sends++;
                        Check(JsonNode.DeepEquals(new TeamAskRecoveryStore(root).Load(target)!.Record.Input, input), "Ask was sent before its original request was durable");
                        if (original is null) original = (JsonObject)input.DeepClone();
                        else Check(JsonNode.DeepEquals(original, input), "Recovery changed the original Ask");
                        if (lost) throw new IOException("Fictional reply lost");
                        return Task.FromResult<JsonNode>(new JsonObject { ["state"] = "running", ["fence"] = fence.DeepClone() });
                    case "team.chat.ask.status":
                        Check(JsonNode.DeepEquals(input["fence"], fence), "Status changed the run fence"); return Task.FromResult<JsonNode>(status.DeepClone());
                    case "team.chat.ask.stop":
                        Check(JsonNode.DeepEquals(input["fence"], fence), "Stop changed the run fence");
                        if (++stops == 1) throw new IOException("Fictional Stop failed");
                        return Task.FromResult<JsonNode>(new JsonObject { ["stopping"] = false });
                    default: throw new Exception("Unexpected fictional Ask call");
                }
            }
            TeamAskModel Model() => new(new(root), target, "Fictional project", () => current, Call);
            var first = Model(); await first.RestoreAsync(); first.Text = "Original fictional Ask"; await first.AskAsync();
            Check(first.Pending && sends == 1, "Lost reply discarded its durable Ask");
            var pending = Model(); await pending.RestoreAsync();
            Check(pending.Pending && pending.Text == first.Text && sends == 1, "Restore resent work or lost the pending Ask");
            lost = false; await pending.AskAsync();
            Check(reviews == 1 && sends == 2 && JsonNode.DeepEquals(pending.Fence, fence), "Retry did not recover the same run");
            var running = Model(); await running.RestoreAsync();
            Check(JsonNode.DeepEquals(running.Fence, fence) && sends == 2, "Reopened reader lost Stop");
            await running.CheckAsync(); Check(running.Fence is not null, "Malformed status removed Stop");
            status = new() { ["running"] = true }; await running.CheckAsync();
            Check(running.Error is null && running.Fence is not null, "Healthy status did not clear the stale warning");
            await running.StopAsync(); Check(!running.Stopping && running.Fence is not null, "Failed Stop could not be retried");
            await running.StopAsync(); Check(running.Stopping && running.Fence is not null, "Stop acknowledgement was treated as completion");
            status = new() { ["running"] = false }; await running.CheckAsync();
            Check(running.Fence is null && new TeamAskRecoveryStore(root).Load(target) is null, "Confirmed completion did not retire recovery");
            var next = Model(); await next.RestoreAsync(); next.Text = "Next fictional Ask"; original = null; lost = true; await next.AskAsync();
            await pending.CheckAsync();
            Check(new TeamAskRecoveryStore(root).Load(target)!.Record.Question == "Next fictional Ask", "Stale completion erased a newer Ask");
            Check(new TeamAskRecoveryStore(root).Load(target with { Person = "other-person" }) is null, "Recovery crossed people");
            Check(new TeamAskRecoveryStore(root).Load(target with { Host = new('b', 64) }) is null, "Recovery crossed publishing computers");
            current = false; var oldSends = sends; await next.AskAsync();
            Check(sends == oldSends, "Old login sent saved work");
            var file = Directory.EnumerateFiles(root, "*.json", SearchOption.AllDirectories).Single(); File.WriteAllText(file, "broken");
            current = true; var corrupt = Model(); await corrupt.RestoreAsync(); corrupt.Text = "Must not replace saved work"; await corrupt.AskAsync();
            Check(!corrupt.Loaded && sends == oldSends && File.ReadAllText(file) == "broken", "Corrupt recovery became a fresh Ask");
            var refusedTarget = target with { Share = "share-refused" };
            var refused = new TeamAskModel(new(root), refusedTarget, "", () => true, (method, _) => method == "team.chat.ask.review"
                ? Task.FromResult<JsonNode>(new JsonObject { ["agentRuns"] = true, ["review"] = new string('c', 64) })
                : throw new TeamAskNotAccepted("Fictional stale review refused"));
            await refused.RestoreAsync(); refused.Text = "Keep the refused words"; await refused.AskAsync();
            Check(!refused.Pending && refused.Text == "Keep the refused words" && new TeamAskRecoveryStore(root).Load(refusedTarget) is null, "A definite validation refusal trapped the Ask");
            var wrongReceipt = new JsonObject { ["receipt"] = new JsonObject { ["shareId"] = "other-share", ["clientMessageId"] = original!["clientMessageId"]!.DeepClone(), ["state"] = "succeeded", ["runId"] = fence["runId"]!.DeepClone() } };
            Check(!new TeamAskRecord(original!).Terminal(wrongReceipt, target.Share), "A different chat's receipt retired saved work");
            Console.WriteLine("Team Ask durable recovery: original requests, Stop, CAS, account scope and corruption pass.");
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }
}
