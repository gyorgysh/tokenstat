// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Tokenstat.Pages;

static JsonNode Json(string text) => JsonNode.Parse(text)!;
static void Check(bool answer, string message) { if (!answer) throw new Exception(message); }
var history = new ChatHistoryBuffer();
var newest = Json("""{"events":[{"id":"recent"}],"nextOffset":900,"tailCursor":"tail-a","cursor":"older-a","hasEarlier":true,"usage":{"turns":10,"input":1000,"output":200,"cacheRead":10,"cacheWrite":20,"cost":1.5}}""");
history.ApplyPage(newest, true);
var generation = history.Generation;
Check(history.Events.Count == 1 && history.HasEarlier && history.Offset == 900, "opening must use the bounded page");
history.ApplyTail(Json("""{"events":[{"event":{"kind":"usage","input":100,"output":50,"cacheRead":5,"cacheWrite":3,"costUsd":0.25}}],"nextOffset":1000,"tailCursor":"tail-b"}"""), generation);
Check(history.Usage!["input"]!.GetValue<long>() == 1100, "tail usage adds to the whole conversation");
history.ApplyPage(Json("""{"events":[{"id":"oldest"}],"nextOffset":500,"cursor":null,"hasEarlier":false,"usage":{"input":99999}}"""), false);
Check(history.Events.Count == 3 && history.Events[0]!["id"]!.GetValue<string>() == "oldest", "earlier pages prepend without losing live events");
Check(history.Offset == 1000 && history.TailCursor == "tail-b", "earlier pagination must not rewind the live tail");
Check(history.Usage!["input"]!.GetValue<long>() == 1100 && history.Usage["cost"]!.GetValue<double>() == 1.75, "earlier pages must not double-count usage");
Check(newest["usage"]!["input"]!.GetValue<long>() == 1000, "cached responses must stay independent of mutable usage");
history.ApplyPage(Json("""{"reset":true,"events":[{"id":"replacement"}],"nextOffset":80,"tailCursor":"new-tail","hasEarlier":false}"""), false);
Check(history.Events.Count == 1 && history.Offset == 80 && history.Usage is null, "trim reset must replace history and totals");
Check(!history.ApplyTail(Json("""{"events":[{"id":"stale"}],"nextOffset":1100}"""), generation), "late pre-reset replies must be ignored");
Check(!history.ApplyTail(Json("""{"reset":true,"events":[],"nextOffset":0}"""), history.Generation), "reset tail must require a new page");
history.Reset();
Check(history.Events.Count == 0 && history.Cursor is null && history.Offset == 0, "changing conversation must release old history");
Console.WriteLine("Windows chat paging: bounded opening, concurrent older/live reads, totals, archive resets and stale replies pass.");

var now = new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc);
var previews = new Tokenstat.Navigation.ChatPreviewStore(() => now);
for (int i = 0; i < 11; i++) {
    Check(previews.Store("workspace", i.ToString(), newest.DeepClone(), previews.Generation), "small previews fit");
    now = now.AddMilliseconds(1);
}
Check(previews.Take("workspace", "0") is null && previews.Take("other-workspace", "10") is null, "eviction and workspace isolation");
Check(previews.Take("workspace", "10") is not null && previews.Take("workspace", "10") is null, "opening consumes the preview once");
Check(!previews.Store("workspace", "large", new JsonObject { ["text"] = new string('x', 512 * 1024) }, previews.Generation), "bounded cache rejects large transcripts");
now = now.AddSeconds(21);
Check(!previews.Contains("workspace", "9") && previews.Take("workspace", "9") is null, "expired previews are never served");
var oldAccount = previews.Generation;
previews.Clear();
Check(!previews.Store("workspace", "late", newest.DeepClone(), oldAccount), "late reads from the previous account cannot repopulate the cache");
Console.WriteLine("Windows chat previews: size/count bounds, expiry, workspace isolation, consumption and account invalidation pass.");

static void Phrase(string? verb, string? target, string expected, string message)
{
    var got = SeatStep.Phrase(verb, target);
    Check(got == expected, message + ": " + got);
}

Phrase("Read", "src/App.swift", "Reading App.swift", "read names the file");
Phrase("Write", "a/b.txt", "Writing b.txt", "write names the file");
Phrase("Edit", "src/dir/", "Editing dir", "a trailing slash is not the name");
Phrase("NotebookEdit", "notes/n.ipynb", "Editing n.ipynb", "a notebook edit names the file");
Phrase("Diff", "a/b", "Comparing b", "a diff names the file");
Phrase("Shell", "cargo\ttest", "Running cargo test", "a tab in a command becomes a space");
Phrase("Bash", "echo hi", "Running echo hi", "bash is a command");
Phrase("Shell", "cargo test\nrm -rf", "Running cargo test", "a command stops at the first line");
Phrase("Shell", "  ls  ", "Running ls", "a command drops surrounding space");
Phrase("Shell", "abcdefghijklmnopqrstuvwxyz0123456789", "Running abcdefghijklmnopqrstuvwxyz01234…", "a long command is clipped");
Phrase("Shell", "abcdefghijklmnopqrstuvwxyz012345", "Running abcdefghijklmnopqrstuvwxyz012345", "thirty two characters stay whole");
Phrase("Shell", "abcdefghijklmnopqrstuvwxyz0123456", "Running abcdefghijklmnopqrstuvwxyz01234…", "thirty three characters clip");
Phrase("Grep", "needle", "Searching needle", "grep names the query");
Phrase("Search", "q", "Searching q", "search names the query");
Phrase("Glob", "   ", "Looking", "an empty search is just looking");
Phrase("Glob", "foo", "Looking through foo", "a name without a slash is still a name");
Phrase("Find", "src/x", "Looking through x", "find names the file");
Phrase("Glob", "dir/My  File.swift", "Looking through My  File.swift", "a file name keeps its spaces");
Phrase("WebFetch", "https://example.com/a?b=1", "Opening example.com", "a page names the site");
Phrase("WebFetch", "http://[::1]:8080/x", "Opening [::1]", "an address drops its port");
Phrase("WebFetch", "http://user:pass@example.com/x", "Opening example.com", "a page drops the login");
Phrase("WebFetch", "https://", "Opening https://", "a bare scheme stays visible");
Phrase("WebFetch", "", "Opening", "an empty page is just opening");
Phrase("WebFetch", null, "Opening", "a missing page is just opening");
Phrase("WebSearch", "anything", "Searching the web", "web search ignores the query");
Phrase("WebFetch", "http://example.com:8080/a", "Opening example.com", "a numeric port is dropped");
Phrase("WebFetch", "http://example.com:/a", "Opening example.com:", "an empty port stays");
Phrase("WebFetch", "http://a@b@example.com/x", "Opening example.com", "the last login mark wins");
Phrase("WebFetch", "http://[::1]", "Opening [::1]", "an address without a port stays");
Phrase("WebFetch", "example.com:\uFF11\uFF12", "Opening example.com:\uFF11\uFF12", "a non ascii port stays");
Phrase("WebFetch", "https://example.com?q=1", "Opening example.com", "a query is not part of the site");
Phrase("WebFetch", "https://example.com#top", "Opening example.com", "a fragment is not part of the site");
Phrase("Task", "explore", "Asking another agent", "a task names no target");
Phrase("Subagent", null, "Asking another agent", "a subagent names no target");
Phrase("TodoWrite", "list", "Updating the list", "a list update names no item");
Phrase("Read", "dir/My  File.swift", "Reading My  File.swift", "a read keeps spaces in the name");
Phrase("Read", "src\\App.swift", "Reading App.swift", "a windows path names the file");
Phrase("Edit", "src\\dir\\", "Editing dir", "a trailing backslash is not the name");
Phrase("Other", "src/App.swift", "Working on App.swift", "an unknown path names the file");
Phrase("read", "src/App.swift", "Working on App.swift", "a lowercase verb is not a read");
Phrase("Other", "hello", "Working on hello", "an unknown line is named");
Phrase(null, null, "Working", "nothing to name is just working");
Phrase(" Read ", "src/App.swift", "Reading App.swift", "a verb keeps its meaning once trimmed");
Phrase("Other", "///", "Working", "slashes alone are just working");
Phrase("Shell", "cargo test\r\nrm -rf", "Running cargo test", "a return ends the command");
Phrase("Shell", "a  \t  b", "Running a b", "runs of space collapse");
Check(SeatStep.SeatLabel(true, "Reading App.swift", true) == "Waiting", "waiting wins");
Check(SeatStep.SeatLabel(false, "Reading App.swift", false) == "Reading App.swift", "a step is shown as written");
Check(SeatStep.SeatLabel(false, "  spaced  ", true) == "  spaced  ", "a step keeps its own spaces");
Check(SeatStep.SeatLabel(false, "   ", true) == "Replying", "blank space is not a step");
Check(SeatStep.SeatLabel(false, null, true) == "Replying", "speech with no step is a reply");
Check(SeatStep.SeatLabel(false, "", false) == "Thinking", "an empty step is thought");
Check(SeatStep.SeatLabel(false, null, false) == "Thinking", "nothing running is thought");
void Word(string? verb, bool running, string expected, string message)
{
    var got = SeatStep.Word(verb, running);
    if (got != expected) throw new Exception(message + ": " + got);
}
Word("Read", true, "Reading", "a read in progress");
Word("Read", false, "Read", "a finished read");
Word("Write", true, "Writing", "a write in progress");
Word("Write", false, "Wrote", "a finished write");
Word("Edit", true, "Editing", "an edit in progress");
Word("NotebookEdit", false, "Edited", "a finished notebook edit");
Word("Diff", true, "Comparing", "a diff in progress");
Word("Diff", false, "Compared", "a finished diff");
Word("Shell", true, "Running", "a command in progress");
Word("Bash", false, "Ran", "a finished command");
Word("Grep", true, "Searching", "a search in progress");
Word("Search", false, "Searched", "a finished search");
Word("Glob", true, "Looking", "a file search in progress");
Word("Find", false, "Looked", "a finished file search");
Word("WebFetch", true, "Opening", "a page in progress");
Word("WebFetch", false, "Opened", "a finished page");
Word("WebSearch", true, "Searching the web", "a web search in progress");
Word("WebSearch", false, "Searched the web", "a finished web search");
Word("Task", true, "Asking another agent", "another agent in progress");
Word("Subagent", false, "Asked another agent", "a finished request to another agent");
Word("TodoWrite", true, "Updating the list", "a list in progress");
Word("TodoWrite", false, "Updated the list", "a finished list");
Word(null, true, "Working", "an unnamed step in progress");
Word("", false, "Worked", "a finished unnamed step");
Word(" ApplyPatch ", true, "ApplyPatch", "an unknown name stays");
Word("bash", false, "bash", "a lowercase name stays");
Check(SeatStep.Speaks("Bash"), "a command already says it is running");
Check(SeatStep.Speaks(" Read "), "a trimmed read already says it is reading");
Check(!SeatStep.Speaks("ApplyPatch"), "an unknown name still needs the chip");
Check(SeatStep.Speaks(null), "an unnamed step already says it is working");
void Approval(string? verb, bool pending, string expected, string message)
{
    var got = SeatStep.ApprovalWord(verb, pending);
    if (got != expected) throw new Exception(message + ": " + got);
}
Approval("Read", true, "Reading", "a pending read");
Approval("Read", false, "Read", "a decided read");
Approval("Bash", true, "Running", "a pending command");
Approval("Bash", false, "Ran", "a decided command");
Approval(null, true, "Approval", "a blank request stays Approval");
Approval("  ", false, "Approval", "spaces are still a blank request");
Approval(" ApplyPatch ", true, "ApplyPatch", "an unknown permission keeps its name");
void Note(string? verb, string? prefix, string? expected, string message)
{
    var got = SeatStep.AllowAlwaysNote(verb, prefix);
    if (got != expected) throw new Exception(message + ": " + (got ?? "<none>"));
}
Note("Bash", "cargo test", "Always allow remembers cargo test for this chat only.", "a command prefix is what is saved");
Note("Read", "  cargo test  ", "Always allow remembers cargo test for this chat only.", "a prefix is trimmed, then kept");
Note("Bash", null, "Always allow answers this request only. Nothing is saved for later.", "a command with no prefix is not saved");
Note("Bash", "  ", "Always allow answers this request only. Nothing is saved for later.", "a blank prefix is no prefix");
Note("run_terminal_command", null, "Always allow answers this request only. Nothing is saved for later.", "a compound command name is still a command");
Note("sh", null, "Always allow answers this request only. Nothing is saved for later.", "a short shell name is a command");
Note("Read", null, "Always allow remembers Read for this chat only.", "a plain tool is remembered by its name");
Note(" ApplyPatch ", null, "Always allow remembers ApplyPatch for this chat only.", "an unknown tool keeps the trimmed name");
Note("execute_turn", null, "Always allow remembers execute_turn for this chat only.", "execute inside a longer word is not a command");
Note(null, null, null, "nothing to remember says nothing");
Check(!SeatStep.IsShell("push"), "push is not a command");
Check(SeatStep.IsShell("Run-Task"), "run as its own word is a command");
Console.WriteLine("Windows seat steps: file, command, site and mood words pass.");
