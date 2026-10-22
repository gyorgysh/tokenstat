// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;

namespace Tokenstat.Pages;

/// One immutable account/resource binding. It outlives a redraw so a late
/// receipt settles only the original local attempt, never a newer draft.
internal sealed class TeamCommentModel(TeamCommentDraftStore storage, TeamCommentTarget target, string label, Func<string, JsonObject, Task<JsonNode>> call)
{
    internal string Text { get; private set; } = "";
    internal string? RecoveredText { get; private set; }
    internal TeamCommentDraft? Draft { get; private set; }
    internal bool Loaded { get; private set; }
    internal bool Busy { get; private set; }
    internal bool Pending => Draft?.Attempt is not null;
    internal string? Error { get; private set; }
    internal string? Status { get; private set; }
    internal bool TooLong => !string.IsNullOrWhiteSpace(Text) && !new TeamCommentDraft("", Text, Draft?.Attempt, label).CanSend;
    internal bool CanSend => Loaded && !Busy && RecoveredText is null && new TeamCommentDraft("", Text, Draft?.Attempt, label).CanSend;
    internal Action? Changed { get; set; }
    private readonly SemaphoreSlim _saving = new(1, 1);
    private CancellationTokenSource? _autosave;
    internal async Task RestoreAsync()
    {
        if (Loaded) return;
        try
        {
            var saved = await Task.Run(() => storage.Load(target));
            var unsaved = storage.Unsaved(target);
            Draft = saved;
            if (unsaved is not null && unsaved.Expected != saved) { Text = saved?.Text ?? ""; RecoveredText = unsaved.Text; }
            else Text = unsaved?.Text ?? saved?.Text ?? "";
            Loaded = true;
            Error = unsaved is null ? null : RecoveredText is null ? "comment_save_failed" : "comment_draft_changed";
            if (Pending) Status = "comment_unconfirmed";
        }
        catch { Error = "comment_save_failed"; }
    }
    internal void Edit(string text)
    {
        if (!Loaded || Busy || Pending || RecoveredText is not null) return;
        Text = text; Status = null;
        storage.Remember(target, Text, Draft, label);
        _autosave?.Cancel();
        _autosave = new();
        _ = SaveLaterAsync(_autosave.Token);
    }
    private async Task SaveLaterAsync(CancellationToken token)
    {
        try { await Task.Delay(350, token); await FlushAsync(); }
        catch (OperationCanceledException) { }
        catch (Exception e) { Error = e is TeamDraftException f ? f.Key : "comment_save_failed"; }
        Changed?.Invoke();
    }
    private async Task FlushAsync()
    {
        await _saving.WaitAsync();
        try
        {
            if (!Loaded || Pending) return;
            if (RecoveredText is not null) throw new TeamDraftException("comment_draft_changed");
            while (Draft?.Text != Text && !(Draft is null && Text.Length == 0))
            {
                var words = Text; var expected = Draft;
                Draft = await Task.Run(() => storage.Save(target, words, expected, label));
            }
            storage.ForgetUnsaved(target); Error = null;
        }
        finally { _saving.Release(); }
    }
    internal async Task SendAsync()
    {
        if (!CanSend) return;
        Busy = true; Error = null; Status = null; _autosave?.Cancel();
        try
        {
            await FlushAsync();
            var saved = Draft ?? throw new TeamDraftException("comment_save_failed");
            var reserved = await Task.Run(() => storage.Reserve(target, saved));
            Draft = reserved;
            var response = await call("teams.comment.send", new JsonObject { ["target"] = Fields(), ["input"] = reserved.Input });
            await AcceptAsync(response["receipt"] ?? throw new TeamDraftException("comment_unconfirmed"), reserved);
        }
        catch (Exception e) { Error = e is TeamDraftException f ? f.Key : Pending ? null : "comment_save_failed"; if (Pending) Status = "comment_unconfirmed"; }
        finally { Busy = false; }
    }
    internal async Task CheckAsync()
    {
        if (!Loaded || Busy || Draft?.Attempt is not { } a) return;
        Busy = true; Error = null;
        var expected = Draft;
        try
        {
            var response = await call("teams.connection.call", new JsonObject { ["target"] = Fields(), ["method"] = "team.chat.receipt", ["params"] = new JsonObject { ["clientMessageId"] = a.Id } });
            await AcceptAsync(response["receipt"] ?? throw new TeamDraftException("comment_unconfirmed"), expected);
        }
        catch (Exception e) { Error = e is TeamDraftException f ? f.Key : "comment_unconfirmed"; }
        finally { Busy = false; }
    }
    private async Task AcceptAsync(JsonNode receipt, TeamCommentDraft expected)
    {
        var state = TeamCommentDraftStore.ReceiptState(target, expected, receipt);
        Draft = await Task.Run(() => storage.Resolve(target, expected, receipt));
        Text = Draft?.Text ?? "";
        Status = state == "accepted" ? "comment_posted" : state == "notAccepted" ? "comment_not_accepted" : "comment_unconfirmed";
    }
    internal async Task ReloadAsync()
    {
        if (Busy) return;
        Busy = true;
        _autosave?.Cancel(); await _saving.WaitAsync();
        try { Draft = await Task.Run(() => storage.Load(target)); storage.ForgetUnsaved(target); Text = Draft?.Text ?? ""; RecoveredText = null; Loaded = true; Error = null; Status = Pending ? "comment_unconfirmed" : null; }
        catch { Error = "comment_save_failed"; }
        finally { _saving.Release(); Busy = false; }
    }
    private JsonObject Fields() => new() { ["organization"] = target.Organization, ["repository"] = target.Repository, ["checkout"] = target.Checkout, ["share"] = target.Share };
}
