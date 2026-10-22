// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Tokenstat.Pages;

internal static class TeamTranscriptTests
{
    internal static void Run()
    {
        static void Check(bool answer) { if (!answer) throw new Exception("Shared transcript regression"); }
        static JsonObject Event(string kind, string? text = null) => new() { ["kind"] = kind, ["delta"] = text };
        static JsonObject Agent(ulong seq, JsonObject e, char run = 'a', bool former = false) => new() {
            ["kind"] = "agent", ["seq"] = seq, ["mode"] = "agent", ["backend"] = "claude", ["event"] = e.DeepClone(),
            ["author"] = new JsonObject { ["kind"] = "agent", ["backend"] = "claude", ["runId"] = "run_" + new string(run, 32), ["initiatedBy"] = former
                ? new JsonObject { ["kind"] = "formerMember", ["name"] = "Must not appear" }
                : new JsonObject { ["kind"] = "person", ["id"] = "person-fixture", ["name"] = "Fictional member" } },
        };
        static void Refuses(Action action) { try { action(); throw new Exception("expected transcript refusal"); } catch (InvalidDataException) { } }
        const string chart = "```tokenstat-chart\n{}\n```";
        var rows = TeamTranscript.Project([Agent(0, Event("text", chart[..12])), Agent(1, Event("text", chart[12..])), Agent(2, Event("text", "other run"), 'b')], "claude");
        Check(rows.Count == 2 && rows[0].Text == chart && rows[0].Author?.Name == "Fictional member" && rows[1].Text == "other run");
        var former = TeamTranscript.Project([Agent(0, Event("text", "reply"), former: true)], "claude").Single();
        Check(former.Author is { FormerInitiator: true, Name.Length: 0 });
        var start = new JsonObject { ["kind"] = "toolStart", ["callId"] = "same", ["verb"] = "Read", ["target"] = "file.txt", ["input"] = new JsonObject { ["path"] = "file.txt" } };
        var end = new JsonObject { ["kind"] = "toolEnd", ["callId"] = "same", ["ok"] = true, ["detail"] = "first output" };
        rows = TeamTranscript.Project([Agent(0, start), Agent(1, start), Agent(2, end), Agent(3, end, 'b')], "claude");
        Check(rows.Count == 3 && rows[0].Ok == true && rows[0].Text.Contains("first output") && rows[1].Ok is null && !rows[1].Text.Contains("first output") && rows[2].Title.Length == 0);
        start.Remove("callId"); end.Remove("callId");
        Check(TeamTranscript.Project([Agent(0, start), Agent(1, end)], "claude").Count == 2);
        var duplicate = Agent(0, Event("text", "reply"));
        Refuses(() => TeamTranscript.Project([duplicate, duplicate], "claude"));
        var bad = Agent(0, Event("text", "reply")); bad["mode"] = "comment";
        Refuses(() => TeamTranscript.Project([bad], "claude"));
        var unverified = JsonNode.Parse("""{"kind":"user","seq":0,"text":"literal","author":{"kind":"person","id":"p","name":"unverified"}}""")!.AsObject();
        Refuses(() => TeamTranscript.Project([unverified], "claude"));
        var hidden = TeamTranscript.Project([Agent(0, new JsonObject { ["kind"] = "session", ["id"] = "private-continuation" })], "claude").Single();
        Check(hidden.Kind == TeamBlockKind.Notice && hidden.Text.Length == 0);
        var original = string.Concat(Enumerable.Repeat("ab🙂cdé", 100)); var pages = TeamTranscript.TextPages(original, 3);
        Check(string.Concat(pages) == original && pages.All(p => !char.IsHighSurrogate(p[^1]) && !char.IsLowSurrogate(p[0])));
        Console.WriteLine("Teams transcript: chart coalescing, verified authors, former members, scoped tool ownership and Unicode pages pass.");
    }
}
