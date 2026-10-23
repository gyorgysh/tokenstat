// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Tokenstat.Pages;

internal static class ChatLocalSharingTests
{
    internal static async Task RunAsync()
    {
        static void Check(bool value, string message) { if (!value) throw new Exception(message); }
        var share = "share_" + new string('a', 32); var calls = new List<(string Method, JsonObject Body)>();
        var revision = 3L; var held = false; var ready = false; var releaseFails = true;
        JsonNode Info() => new JsonObject { ["sharing"] = new JsonObject { ["id"] = share, ["revision"] = revision, ["phase"] = revision == 3 ? "active" : "withdrawn", ["privateReady"] = ready, ["accountCleanupPending"] = true, ["agentRunHeld"] = held } };
        Task<JsonNode> Local(string method, JsonObject body)
        {
            Check(body["workspaceId"]!.GetValue<string>() == "folder" && body["id"]!.GetValue<string>() == "chat"
                && !body.ContainsKey("_accountScope") && !body.ContainsKey("_accountSession") && !body.ContainsKey("peer"), "Local sharing recovery used an account or remote route");
            calls.Add((method, (JsonObject)body.DeepClone()));
            switch (method)
            {
                case "chat.sharing.info": return Task.FromResult(Info());
                case "chat.sharing.stopLocal":
                    Check(body["share"]!.GetValue<string>() == share && body["expectedRevision"]!.GetValue<long>() == 3 && body["confirmStop"]!.GetValue<bool>(), "Local Stop changed the reviewed sharing revision");
                    revision = 4; held = true;
                    return Task.FromResult<JsonNode>(new JsonObject { ["stoppedLocally"] = true, ["privateReady"] = false, ["localRecoveryNeeded"] = true, ["accountCleanupPending"] = true });
                case "chat.sharing.recoverRun":
                    Check(body["confirmRecovery"]!.GetValue<bool>(), "Run release was not explicit");
                    if (releaseFails) throw new IOException("Fictional agent is still running");
                    held = false; ready = true; return Task.FromResult<JsonNode>(new JsonObject { ["recovered"] = true });
                default: throw new Exception("Unexpected local sharing call");
            }
        }
        var model = new ChatLocalSharingModel("folder", "chat", share, false, () => true, Local);
        await model.LoadAsync(); var reviewed = model.Snapshot!;
        Check(model.CanStop && !model.PrivateReady, "Signed-out sharing could not be reviewed locally");
        await model.StopAsync(reviewed, false); await model.StopAsync(reviewed with { Revision = 2 }, true);
        Check(calls.Count == 1, "Stop skipped consent or accepted a different reviewed revision");
        await model.StopAsync(reviewed, true);
        Check(!model.PrivateReady && !model.CanStop && model.Result is { RecoveryNeeded: true, CleanupPending: true }, "An unresolved run resumed private editing");
        await model.LoadAsync(); Check(model.CanRelease && !model.CanStop, "Interrupted run recovery was hidden or offered another sharing withdrawal");
        await model.ReleaseAsync(); Check(!model.PrivateReady && model.Error is not null && model.CanRelease, "A still-running agent was treated as released");
        releaseFails = false; await model.ReleaseAsync(); Check(model.PrivateReady && !model.CanRelease, "Proven local recovery did not restore private readiness");

        JsonObject? sourceStop = null;
        var sourceOnly = new ChatLocalSharingModel("folder", "chat", share, false, () => true, (method, body) => {
            if (method == "chat.sharing.info") return Task.FromResult<JsonNode>(new JsonObject { ["sharing"] = new JsonObject { ["id"] = share, ["revision"] = 0L, ["phase"] = "active", ["privateReady"] = false, ["sourceOnly"] = true, ["accountCleanupPending"] = true } });
            sourceStop = body; return Task.FromResult<JsonNode>(new JsonObject { ["stoppedLocally"] = true, ["privateReady"] = true, ["localRecoveryNeeded"] = false, ["accountCleanupPending"] = true });
        });
        await sourceOnly.LoadAsync(); await sourceOnly.StopAsync(sourceOnly.Snapshot!, true);
        Check(sourceOnly.PrivateReady && sourceStop?["sourceOnly"]?.GetValue<bool>() == true && sourceStop["expectedRevision"]!.GetValue<long>() == 0, "Missing publication records could not use exact source-only cleanup");

        var current = true; var pending = new TaskCompletionSource<JsonNode>(); var staleCalls = 0;
        var stale = new ChatLocalSharingModel("folder", "chat", share, false, () => current, (_, _) => { staleCalls++; return pending.Task; });
        var loading = stale.LoadAsync(); current = false; pending.SetResult(Info()); await loading;
        Check(!stale.Loaded && stale.Snapshot is null && staleCalls == 1, "An old account's local sharing read reached another view");
        await stale.StopAsync(reviewed, true); Check(staleCalls == 1, "A retired view stopped sharing");
        var foreign = new ChatLocalSharingModel("folder", "chat", "share_" + new string('b', 32), false, () => true, (_, _) => Task.FromResult(Info()));
        await foreign.LoadAsync(); Check(!foreign.Loaded && foreign.Snapshot is null && !foreign.CanStop, "Cleanup retargeted a replacement share");
        Check(!ChatLocalSharingModel.Paused(new JsonObject()) && ChatLocalSharingModel.Paused(new JsonObject { ["teamShare"] = "malformed marker" })
            && ChatLocalSharingModel.Paused(new JsonObject { ["teamRunFence"] = new JsonObject() }), "Personal sends were allowed with a shared marker or unresolved fence");
        Console.WriteLine("Windows local sharing: signed-out exact cleanup, consent, missing records, held-run proof and stale-view isolation pass.");
    }
}
