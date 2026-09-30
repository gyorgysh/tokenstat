// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;

namespace Tokenstat.Pages;

/// <summary>Protect confirmed note changes from chat lists already in flight.</summary>
internal sealed class ChatSteerOverlay
{
    private sealed record Change(string Note, long Before);
    private readonly Dictionary<string, Change> _changes = new();
    private readonly Dictionary<string, long> _revisions = new();
    private long _nextRevision;
    private long _requests;
    private long _applied;

    public long BeginRead() => ++_requests;

    public long Revision(string chat) => _revisions.GetValueOrDefault(chat);

    public void Remember(string chat, string? note)
    {
        _revisions[chat] = ++_nextRevision;
        _changes[chat] = new Change(note?.Trim() ?? "", _requests);
    }

    public bool RememberIfCurrent(string chat, string? note, long revision)
    {
        if (Revision(chat) != revision) return false;
        Remember(chat, note);
        return true;
    }

    public static JsonNode MergeRecord(JsonNode record, JsonNode? current)
    {
        if (record is not JsonObject || current is null
            || record["id"]?.GetValue<string>() != current["id"]?.GetValue<string>()) return record;
        var copy = (JsonObject)record.DeepClone();
        var note = current["pendingSteer"]?.GetValue<string>()?.Trim() ?? "";
        if (note.Length == 0) copy.Remove("pendingSteer");
        else copy["pendingSteer"] = note;
        return copy;
    }

    public JsonArray Apply(JsonArray rows, long request, JsonArray current)
    {
        if (request < _applied) return current;
        _applied = request;
        var previousNotes = new Dictionary<string, string>();
        foreach (var row in current.OfType<JsonObject>())
        {
            var id = row["id"]?.GetValue<string>();
            if (!string.IsNullOrEmpty(id))
                previousNotes[id] = row["pendingSteer"]?.GetValue<string>()?.Trim() ?? "";
        }
        var present = new HashSet<string>();
        foreach (var row in rows.OfType<JsonObject>())
        {
            var id = row["id"]?.GetValue<string>();
            if (string.IsNullOrEmpty(id)) continue;
            present.Add(id);
            if (!_changes.TryGetValue(id, out var change)) continue;
            // A read started after the host acknowledged the mutation may
            // already show that a tool consumed the note. Trust that answer.
            if (request > change.Before)
            {
                _changes.Remove(id);
                continue;
            }
            if (change.Note.Length == 0) row.Remove("pendingSteer");
            else row["pendingSteer"] = change.Note;
        }
        foreach (var id in _changes.Keys.Where(id => !present.Contains(id)
            && request > _changes[id].Before).ToArray())
            _changes.Remove(id);
        foreach (var row in rows.OfType<JsonObject>())
        {
            var id = row["id"]?.GetValue<string>();
            if (string.IsNullOrEmpty(id)) continue;
            if (previousNotes.TryGetValue(id, out var previous)
                && previous != (row["pendingSteer"]?.GetValue<string>()?.Trim() ?? ""))
                _revisions[id] = ++_nextRevision;
        }
        return rows;
    }
}
