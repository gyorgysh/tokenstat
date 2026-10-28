// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text;
using System.Text.Json.Nodes;

namespace Tokenstat.Pages;

internal sealed class TeamAskNotAccepted(string message) : Exception(message);
/// <summary>The sharing computer is holding the request until its owner answers.</summary>
internal sealed class TeamAskAwaitingApproval() : Exception("agent_waiting_approval");

internal sealed class TeamAskModel(TeamAskRecoveryStore storage, TeamCommentTarget target, string label,
    Func<bool> current, Func<string, JsonObject, Task<JsonNode>> call)
{
    internal string Text { get; set; } = "";
    internal bool Loaded { get; private set; }
    internal bool Busy { get; private set; }
    internal bool Stopping { get; private set; }
    internal JsonObject? Fence { get; private set; }
    internal string? Error { get; private set; }
    private TeamAskRecoveryStore.Snapshot? _saved;
    /// The sharing computer holds this request until its owner answers. The
    /// same request is sent again until it starts, is declined, or the
    /// owner's window to answer has passed.
    internal bool AwaitingApproval { get; private set; }
    private DateTimeOffset? _approvalSince;
    internal bool Pending => _saved is not null && Fence is null;
    internal bool CanAsk => Loaded && current() && !Busy && Fence is null && !string.IsNullOrWhiteSpace(Text) && Encoding.UTF8.GetByteCount(Text) <= 8192;
    internal Action? Changed;
    private async Task ReplaceAsync(TeamAskRecord? record)
    {
        var expected = _saved;
        _saved = await Task.Run(() => storage.Replace(target, record, expected, label));
    }
    internal async Task RestoreAsync(bool force = false)
    {
        if (Loaded && !force || Fence is not null || Busy || !current()) return;
        Busy = true;
        try
        {
            var saved = await Task.Run(() => storage.Load(target));
            if (!current()) return;
            _saved = saved; Fence = saved?.Record.Fence; Text = saved?.Record.Question ?? ""; Loaded = true;
            Error = Pending ? "ask_unconfirmed" : null;
        }
        catch { Loaded = false; Error = "ask_save_failed"; }
        finally { Busy = false; Changed?.Invoke(); }
    }
    internal async Task AskAsync()
    {
        if (!CanAsk) return;
        Busy = true; Error = null; AwaitingApproval = false; Changed?.Invoke();
        try
        {
            if (_saved is null)
            {
                var review = await call("team.chat.ask.review", new());
                if (!current()) return;
                if (review["agentRuns"] is not JsonValue enabled || !enabled.TryGetValue<bool>(out var ready) || !ready) { Error = "agent_runs_off"; return; }
                await ReplaceAsync(new(new JsonObject { ["text"] = Text.Trim(), ["review"] = review["review"]?.DeepClone(),
                    ["clientMessageId"] = Guid.NewGuid().ToString(), ["clientMessageCreatedAtMs"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() }));
            }
            if (!current() || _saved is not { } original) return;
            var response = await call("team.chat.ask", (JsonObject)original.Record.Input.DeepClone());
            if (response["state"] is JsonValue state && state.TryGetValue<string>(out var name) && name == "running" && TeamAskRecord.ValidFence(response["fence"]))
            {
                Fence = (JsonObject)response["fence"]!.DeepClone();
                // Keep Stop if the reply cannot be saved. The original durable
                // attempt can recover this same fence after restarting.
                await ReplaceAsync(original.Record with { Fence = Fence }); Text = "";
            }
            else if (original.Record.Terminal(response, target.Share)) { await ReplaceAsync(null); Text = ""; }
            else Error = "ask_unconfirmed";
        }
        catch (TeamAskAwaitingApproval)
        {
            var since = _approvalSince ??= DateTimeOffset.UtcNow;
            if (DateTimeOffset.UtcNow - since >= TimeSpan.FromMinutes(15)) { _approvalSince = null; Error = "agent_approval_expired"; }
            else { AwaitingApproval = true; Error = "agent_waiting_approval"; _ = RetryAfterApprovalAsync(); }
        }
        catch (TeamAskNotAccepted refusal)
        {
            try { await ReplaceAsync(null); Error = refusal.Message; }
            catch { Error = "ask_save_failed"; }
        }
        catch (Exception error) { Error = error is TeamDraftException or InvalidDataException ? "ask_save_failed" : error.Message; }
        finally { if (!AwaitingApproval) _approvalSince = null; Busy = false; Changed?.Invoke(); }
    }
    private async Task RetryAfterApprovalAsync()
    {
        await Task.Delay(TimeSpan.FromSeconds(4));
        if (AwaitingApproval && current()) await AskAsync();
    }
    internal async Task CheckAsync()
    {
        if (Fence is not { } fence || Busy || !current()) return;
        try
        {
            var response = await call("team.chat.ask.status", new() { ["fence"] = fence.DeepClone() });
            if (!current() || !JsonNode.DeepEquals(Fence, fence)) return;
            if (response["running"] is not JsonValue value || !value.TryGetValue<bool>(out var active)) { Error = "run_status_unconfirmed"; return; }
            if (!active) { await ReplaceAsync(null); Fence = null; Stopping = false; Text = ""; Error = null; }
            else if (Error == "run_status_unconfirmed") Error = null;
        }
        catch { Error = "run_status_unconfirmed"; }
        finally { Changed?.Invoke(); }
    }
    internal async Task StopAsync()
    {
        if (Fence is not { } fence || Stopping || !current()) return;
        Stopping = true; Error = null; Changed?.Invoke();
        try
        {
            var response = await call("team.chat.ask.stop", new() { ["fence"] = fence.DeepClone() });
            if (response["stopping"] is not JsonValue value || !value.TryGetValue<bool>(out _)) throw new InvalidDataException("run_status_unconfirmed");
        }
        catch (Exception error) { Error = error.Message; Stopping = false; }
        finally { Changed?.Invoke(); }
    }
}
