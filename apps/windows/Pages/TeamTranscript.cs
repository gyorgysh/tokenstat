// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text;
using System.Text.Json.Nodes;

namespace Tokenstat.Pages;

internal sealed record TeamAuthor(string Kind, string Name = "", string Backend = "", string Person = "", string Run = "", bool FormerInitiator = false);
internal enum TeamBlockKind { User, Text, Thinking, Tool, Edit, File, Notice, Error }
internal sealed record TeamBlock(string Id, TeamBlockKind Kind, TeamAuthor? Author, string Text = "", string Title = "", JsonObject? File = null, bool? Ok = null);

/// Shared host projections only; no personal conversation or workspace actions.
internal static class TeamTranscript
{
    private static string? Field(JsonNode? row, string key) => row?[key] is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;
    private static (string Id, string Name) Person(JsonObject raw)
    {
        var id = Field(raw, "id") ?? ""; var name = Field(raw, "name") ?? "";
        if (id.Length == 0 || Encoding.UTF8.GetByteCount(id) > 128 || name.Length == 0 || name.EnumerateRunes().Count() > 128) throw new InvalidDataException();
        return (id, name);
    }
    private static TeamAuthor Author(JsonObject row, string fallback)
    {
        var raw = row["author"] as JsonObject;
        if (Field(row, "kind") == "user")
        {
            switch (Field(raw, "kind"))
            {
                case null or "localBeforeTeams": return new("localBeforeTeams");
                case "person":
                    var mode = Field(row, "mode");
                    if (mode is not ("comment" or "ask")) throw new InvalidDataException();
                    var p = Person(raw!); return new(mode, p.Name, Person: p.Id);
                case "formerMember": return new("formerMember");
                default: throw new InvalidDataException();
            }
        }
        var backend = Field(row, "backend") is { Length: > 0 } b ? b : fallback;
        if (raw is null) return new("agent", Backend: backend);
        if (Field(raw, "kind") != "agent" || Field(row, "mode") != "agent" || Field(raw, "backend") != backend) throw new InvalidDataException();
        var run = Field(raw, "runId") ?? "";
        if (run.Length != 36 || !run.StartsWith("run_", StringComparison.Ordinal) || !run.AsSpan(4).ToString().All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f') || raw["initiatedBy"] is not JsonObject initiator) throw new InvalidDataException();
        switch (Field(initiator, "kind"))
        {
            case "person": var p = Person(initiator); return new("agent", p.Name, backend, p.Id, run);
            case "formerMember": return new("agent", Backend: backend, Run: run, FormerInitiator: true);
            default: throw new InvalidDataException();
        }
    }
    internal static List<TeamBlock> Project(IEnumerable<JsonObject> events, string backend)
    {
        var rows = new List<TeamBlock>(); var tools = new Dictionary<(string Backend, string Run, string Call), Queue<int>>();
        ulong? previous = null;
        var buffer = new StringBuilder(); var bufferKind = TeamBlockKind.Text; TeamAuthor? bufferAuthor = null; var bufferId = "";
        void Flush()
        {
            if (buffer.Length > 0) rows.Add(new(bufferId, bufferKind, bufferAuthor, buffer.ToString()));
            buffer.Clear(); bufferAuthor = null;
        }
        foreach (var row in events)
        {
            if (row["seq"] is not JsonValue sequence || !sequence.TryGetValue<ulong>(out var seq) || previous is { } old && seq <= old) throw new InvalidDataException();
            previous = seq; var id = $"s{seq}"; var kind = Field(row, "kind");
            if (kind == "user") { Flush(); tools.Clear(); rows.Add(new(id, TeamBlockKind.User, Author(row, backend), Field(row, "text") ?? "")); continue; }
            if (kind == "agent")
            {
                var by = Author(row, backend);
                if (row["event"] is not JsonObject e) throw new InvalidDataException();
                var eventKind = Field(e, "kind");
                if (eventKind is "text" or "thinking")
                {
                    var nextKind = eventKind == "text" ? TeamBlockKind.Text : TeamBlockKind.Thinking;
                    if (buffer.Length > 0 && (bufferKind != nextKind || bufferAuthor != by)) Flush();
                    if (buffer.Length == 0) { bufferId = id; bufferKind = nextKind; bufferAuthor = by; }
                    buffer.Append(Field(e, "delta") ?? ""); continue;
                }
                Flush();
                var call = (by.Backend, by.Run, Id: Field(e, "callId") ?? "");
                switch (eventKind)
                {
                    case "toolStart":
                        var title = string.Join(" ", new[] { Field(e, "verb"), Field(e, "target") }.Where(s => s is not null));
                        if (call.Id.Length > 0) {
                            if (!tools.TryGetValue(call, out var queue)) tools[call] = queue = new();
                            queue.Enqueue(rows.Count);
                        }
                        rows.Add(new(id, TeamBlockKind.Tool, by, e["input"]?.ToJsonString() ?? "", title)); break;
                    case "toolEnd":
                        int? at = tools.TryGetValue(call, out var pending) && pending.Count > 0 ? pending.Dequeue() : null;
                        var detail = Field(e, "detail") ?? "";
                        bool? ok = e["ok"] is JsonValue value && value.TryGetValue<bool>(out var flag) ? flag : null;
                        if (at is null) rows.Add(new(id, TeamBlockKind.Tool, by, detail, Ok: ok));
                        else rows[at.Value] = rows[at.Value] with { Text = string.Join("\n\n", new[] { rows[at.Value].Text, detail }.Where(s => s.Length > 0)), Ok = ok };
                        break;
                    case "edit": rows.Add(new(id, TeamBlockKind.Edit, by, Field(e, "patch") ?? "", Field(e, "path") ?? "")); break;
                    case "attachment": rows.Add(new(id, TeamBlockKind.File, by, File: e)); break;
                    case "failed": rows.Add(new(id, TeamBlockKind.Error, by, Field(e, "text") ?? "")); break;
                    case "done": tools.Clear(); rows.Add(new(id, TeamBlockKind.Notice, by, Title: Field(e, "status") is "failed" or "error" ? "run_failed" : "run_finished")); break;
                    case "usage": break;
                    default: rows.Add(new(id, TeamBlockKind.Notice, by, Title: "event_unavailable")); break;
                }
                continue;
            }
            Flush(); tools.Clear();
            switch (kind)
            {
                case "question": rows.Add(new(id, TeamBlockKind.Notice, null, string.Join("\n", new[] { Field(row, "question") ?? "", row["options"] is JsonArray options ? string.Join("\n", options.Select(o => o?.GetValue<string>() ?? "")) : "" }.Where(s => s.Length > 0)), "recorded_question")); break;
                case "answer" or "system": rows.Add(new(id, TeamBlockKind.Notice, null, Field(row, "text") ?? "", "recorded_message")); break;
                case "handoff": rows.Add(new(id, TeamBlockKind.Notice, null, Field(row, "to") ?? "", "recorded_handoff")); break;
                case "approval": rows.Add(new(id, TeamBlockKind.Notice, null, Field(row["approval"], "preview") ?? "", "recorded_approval")); break;
                case "answerWithdrawn": rows.Add(new(id, TeamBlockKind.Notice, null, Title: "answer_withdrawn")); break;
                default: rows.Add(new(id, TeamBlockKind.Notice, null, Title: "event_unavailable")); break;
            }
        }
        Flush(); return rows;
    }
    internal static List<string> TextPages(string text, int limit = 8192)
    {
        if (limit < 2) throw new ArgumentOutOfRangeException(nameof(limit));
        var pages = new List<string>(); var start = 0;
        while (start < text.Length)
        {
            var end = Math.Min(text.Length, start + limit);
            if (end < text.Length && char.IsHighSurrogate(text[end - 1]) && char.IsLowSurrogate(text[end])) end--;
            pages.Add(text[start..end]); start = end;
        }
        if (pages.Count == 0) pages.Add(""); return pages;
    }
}
