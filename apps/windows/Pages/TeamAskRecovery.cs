// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Tokenstat.Pages;

internal sealed record TeamAskRecord(JsonObject Input, JsonObject? Fence = null)
{
    private static string? Text(JsonNode? node) => node is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;
    internal string Question => Text(Input["text"]) ?? "";
    internal static bool ValidFence(JsonNode? node) => node is JsonObject fields && fields.Count == 2
        && Regex.IsMatch(Text(fields["runId"]) ?? "", "\\Arun_[a-f0-9]{32}\\z")
        && Regex.IsMatch(Text(fields["incarnation"]) ?? "", "\\A[a-f0-9]{64}\\z");
    internal void Validate()
    {
        if (Input.Count != 4 || !Input.ContainsKey("text") || !Input.ContainsKey("review") || !Input.ContainsKey("clientMessageId") || !Input.ContainsKey("clientMessageCreatedAtMs")
            || string.IsNullOrWhiteSpace(Question) || Encoding.UTF8.GetByteCount(Question) > 8192
            || !Regex.IsMatch(Text(Input["review"]) ?? "", "\\A[a-f0-9]{64}\\z") || !Guid.TryParse(Text(Input["clientMessageId"]), out _)
            || Input["clientMessageCreatedAtMs"] is not JsonValue time || !time.TryGetValue<long>(out var ms) || ms <= 0
            || Encoding.UTF8.GetByteCount(Input.ToJsonString()) > 14 * 1024 || Fence is not null && !ValidFence(Fence))
            throw new InvalidDataException("ask_unconfirmed");
    }
    internal bool Terminal(JsonNode response, string share) => response["receipt"] is JsonObject receipt
        && Text(receipt["shareId"]) == share && JsonNode.DeepEquals(receipt["clientMessageId"], Input["clientMessageId"])
        && Text(receipt["state"]) is "notStarted" or "succeeded" or "failed" or "stopped" or "recovered"
        && Regex.IsMatch(Text(receipt["runId"]) ?? "", "\\Arun_[a-f0-9]{32}\\z");
}

/// Separate Ask envelopes reuse locked, atomic CAS files. They never enter
/// the Comment queue, and opening a chat never resends saved work.
internal sealed class TeamAskRecoveryStore(string directory)
{
    internal static readonly TeamAskRecoveryStore Shared = new(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "tokenstat", "team-asks"));
    internal sealed record Snapshot(TeamCommentDraft Saved, TeamAskRecord Record);
    private readonly TeamCommentDraftStore _files = new(directory);
    internal Snapshot? Load(TeamCommentTarget target)
    {
        var saved = _files.Load(target);
        if (saved is null) return null;
        if (saved.Attempt is not null) throw new InvalidDataException("ask_save_failed");
        var value = JsonNode.Parse(saved.Text) as JsonObject ?? throw new InvalidDataException("ask_save_failed");
        if (value["version"]?.GetValue<int>() != 1 || value["input"] is not JsonObject input || value["fence"] is not null and not JsonObject)
            throw new InvalidDataException("ask_save_failed");
        var record = new TeamAskRecord(input, value["fence"] as JsonObject); record.Validate();
        return new(saved, record);
    }
    internal Snapshot? Replace(TeamCommentTarget target, TeamAskRecord? record, Snapshot? expected, string label = "")
    {
        record?.Validate();
        var content = record is null ? "" : new JsonObject { ["version"] = 1, ["input"] = record.Input.DeepClone(), ["fence"] = record.Fence?.DeepClone() }.ToJsonString();
        try
        {
            var saved = _files.Save(target, content, expected?.Saved, expected?.Saved.Label ?? label);
            return record is not null && saved is not null ? new(saved, record) : null;
        }
        catch (TeamDraftException failure) when (failure.Key == "comment_draft_changed")
        {
            var current = Load(target);
            if (current is null && record is null || current is not null && record is not null
                && JsonNode.DeepEquals(current.Record.Input, record.Input) && JsonNode.DeepEquals(current.Record.Fence, record.Fence)) return current;
            throw;
        }
    }
}
