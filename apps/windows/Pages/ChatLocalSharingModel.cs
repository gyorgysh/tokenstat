// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Tokenstat.Pages;

/// Local-only recovery deliberately has no account receipt or peer routing.
/// The host owns the final sharing revision and proof that a run has ended.
internal sealed class ChatLocalSharingModel(string workspace, string chat, string expectedShare, bool held,
    Func<bool> current, Func<string, JsonObject, Task<JsonNode>> call)
{
    internal sealed record Sharing(string Id, long Revision, bool PrivateReady, bool SourceOnly, bool CleanupPending, bool AgentRunHeld, bool Withdrawn);
    internal sealed record Stopped(bool PrivateReady, bool RecoveryNeeded, bool CleanupPending);
    internal Sharing? Snapshot { get; private set; }
    internal Stopped? Result { get; private set; }
    internal bool Busy { get; private set; }
    internal bool Loaded { get; private set; }
    internal string? Error { get; private set; }
    internal bool PrivateReady => Result?.PrivateReady ?? (Loaded && !held && (Snapshot is null || Snapshot.PrivateReady && !Snapshot.AgentRunHeld));
    internal bool CanStop => current() && Loaded && !Busy && Snapshot is { PrivateReady: false, Withdrawn: false } && Result is null;
    internal bool CanRelease => current() && Loaded && !Busy && (Snapshot?.AgentRunHeld == true || held);
    internal Action? Changed;
    internal static bool Paused(JsonNode? record) => record?["teamShare"] is not null || record?["teamRunFence"] is not null;
    private static bool Flag(JsonNode? value, string key) => value?[key] is JsonValue field && field.TryGetValue<bool>(out var flag) ? flag : throw new InvalidDataException();
    private static string Text(JsonNode? value, string key) => value?[key] is JsonValue field && field.TryGetValue<string>(out var text) ? text : throw new InvalidDataException();
    private JsonObject Target() => new() { ["workspaceId"] = workspace, ["id"] = chat };
    private async Task<JsonNode> Call(string method, JsonObject input)
    {
        if (!current()) throw new OperationCanceledException();
        var reply = await call(method, input);
        if (!current()) throw new OperationCanceledException();
        return reply;
    }
    internal async Task LoadAsync()
    {
        if (Busy || !current()) return;
        Busy = true; Loaded = false; Error = null; Snapshot = null; Result = null; Changed?.Invoke();
        try
        {
            var reply = await Call("chat.sharing.info", Target());
            if (reply["sharing"] is { } row)
            {
                var id = Text(row, "id");
                if (!Regex.IsMatch(id, "\\Ashare_[a-f0-9]{32}\\z") || expectedShare.Length != 0 && id != expectedShare
                    || row["revision"] is not JsonValue revision || !revision.TryGetValue<long>(out var rev) || rev < 0 || rev > 9_007_199_254_740_991)
                    throw new InvalidDataException();
                var sourceOnly = row["sourceOnly"] is not null && Flag(row, "sourceOnly");
                var phase = Text(row, "phase");
                if (phase is not ("active" or "withdrawn")) throw new InvalidDataException();
                if (rev == 0 && !sourceOnly) throw new InvalidDataException();
                Snapshot = new(id, rev, Flag(row, "privateReady"), sourceOnly, Flag(row, "accountCleanupPending"), row["agentRunHeld"] is not null && Flag(row, "agentRunHeld"), phase == "withdrawn");
                if (row["agentRunHeld"] is not null) held = Snapshot.AgentRunHeld;
            }
            else if (expectedShare.Length != 0) throw new InvalidDataException();
            Loaded = true;
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { Error = error is InvalidDataException ? "local_record_unavailable" : error.Message; }
        finally { Busy = false; Changed?.Invoke(); }
    }
    internal async Task StopAsync(Sharing reviewed, bool confirmed)
    {
        if (!confirmed || !CanStop || reviewed != Snapshot) return;
        Busy = true; Error = null; Changed?.Invoke();
        try
        {
            var input = Target(); input["share"] = reviewed.Id; input["expectedRevision"] = reviewed.Revision;
            input["sourceOnly"] = reviewed.SourceOnly; input["confirmStop"] = true;
            var reply = await Call("chat.sharing.stopLocal", input);
            if (!Flag(reply, "stoppedLocally")) throw new InvalidDataException();
            var ready = Flag(reply, "privateReady"); var recovery = Flag(reply, "localRecoveryNeeded");
            if (ready && recovery) throw new InvalidDataException();
            Result = new(ready, recovery, Flag(reply, "accountCleanupPending"));
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { Error = error is InvalidDataException ? "local_recovery_retry" : error.Message; }
        finally { Busy = false; Changed?.Invoke(); }
    }
    internal async Task ReleaseAsync()
    {
        if (!CanRelease) return;
        Busy = true; Error = null; Changed?.Invoke();
        try
        {
            var input = Target(); input["confirmRecovery"] = true;
            var reply = await Call("chat.sharing.recoverRun", input);
            _ = Flag(reply, "recovered"); // false is a harmless already-recovered run.
            held = false;
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { Error = error.Message; }
        finally { Busy = false; Changed?.Invoke(); }
        if (Error is null && current()) await LoadAsync();
    }
}
