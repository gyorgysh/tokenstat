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

var overlay = new ChatSteerOverlay();
static JsonArray Chats(string? note = null) => new(new JsonObject
    { ["id"] = "chat", ["pendingSteer"] = note });
var beforePark = overlay.BeginRead();
overlay.Remember("chat", "accepted note");
var currentChats = overlay.Apply(Chats(), beforePark, new());
Check(currentChats[0]!["pendingSteer"]!.GetValue<string>() == "accepted note",
    "A list already in flight erased an accepted note");
var afterPark = overlay.BeginRead();
currentChats = overlay.Apply(Chats(), afterPark, currentChats);
Check(currentChats[0]!["pendingSteer"] is null, "A consumed note was kept by a fresh list");
currentChats = overlay.Apply(Chats("old note"), beforePark, currentChats);
Check(currentChats[0]!["pendingSteer"] is null, "An out-of-order list restored an old note");
var beforeClear = overlay.BeginRead();
overlay.Remember("chat", null);
currentChats = overlay.Apply(Chats("removed note"), beforeClear, currentChats);
Check(currentChats[0]!["pendingSteer"] is null, "A list already in flight restored a removed note");
var afterClear = overlay.BeginRead();
currentChats = overlay.Apply(Chats("note from another device"), afterClear, currentChats);
Check(currentChats[0]!["pendingSteer"]!.GetValue<string>() == "note from another device",
    "A fresh note from another device was hidden after a local removal");
var beforeReplacement = overlay.BeginRead();
overlay.Remember("chat", "replacement note");
currentChats = overlay.Apply(Chats("previous note"), beforeReplacement, currentChats);
Check(currentChats[0]!["pendingSteer"]!.GetValue<string>() == "replacement note",
    "An in-flight list replaced the newest locally accepted note");
var matchingRead = overlay.BeginRead();
var missingRead = overlay.BeginRead();
overlay.Remember("chat", "replacement note");
currentChats = overlay.Apply(Chats("replacement note"), matchingRead, currentChats);
currentChats = overlay.Apply(Chats(), missingRead, currentChats);
Check(currentChats[0]!["pendingSteer"]!.GetValue<string>() == "replacement note",
    "A matching old list released protection while other old lists were still in flight");
var deliveryRevision = overlay.Revision("chat");
overlay.Remember("chat", "replacement note");
Check(overlay.Revision("chat") != deliveryRevision,
    "Replacing a note with identical words did not invalidate an older delivery acknowledgement");
Check(!overlay.RememberIfCurrent("chat", null, deliveryRevision),
    "An older clear/stop acknowledgement retired a newer accepted note");
var latestRevision = overlay.Revision("chat");
currentChats = overlay.Apply(Chats("replacement note"), overlay.BeginRead(), currentChats);
Check(overlay.Revision("chat") == latestRevision && overlay.Revision("chat") != deliveryRevision,
    "A fresh echo forgot mutation identity after releasing local list protection");
var diskRecord = new JsonObject { ["id"] = "chat", ["title"] = "Renamed", ["sendRevision"] = 4 };
var withLatest = ChatSteerOverlay.MergeRecord(diskRecord, Chats("latest note")[0]);
Check(withLatest["pendingSteer"]!.GetValue<string>() == "latest note"
    && withLatest["title"]!.GetValue<string>() == "Renamed" && diskRecord["pendingSteer"] is null,
    "A metadata/send record discarded the current note or changed the host reply");
var clearedRecord = ChatSteerOverlay.MergeRecord(Chats("stale captured note")[0]!, Chats()[0]);
Check(clearedRecord["pendingSteer"] is null, "A late metadata response restored a cleared note");
Console.WriteLine("Windows steer: delayed lists preserve accepted changes and trust fresh host state.");

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

// Chat detail levels. The same cases as scripts/tests/ChatTranscriptFoldTests.swift
// and the Android ChatTranscriptDetailTest, so the three clients fold alike.
static ChatPage.DisplayItem Row(string id, ChatPage.ItemKind kind, string verb = "", bool running = false,
    bool failed = false, string path = "", long added = 0, long removed = 0, double cost = 0, string text = "",
    long started = 0, long ended = 0) =>
    new() { Id = id, Kind = kind, Verb = verb, Target = "t-" + id, Running = running, Failed = failed, Path = path,
        Added = added, Removed = removed, Cost = cost, Text = text, StartedAt = started, EndedAt = ended };
static ChatPage.DisplayItem Ask(string id) => Row(id, ChatPage.ItemKind.User, text: "q");
static ChatPage.DisplayItem Say(string id) => Row(id, ChatPage.ItemKind.Assistant, text: "a");
static ChatPage.DisplayItem Think(string id) => Row(id, ChatPage.ItemKind.Thinking, text: "## Plan\nread it");
static ChatPage.DisplayItem Tool(string id, string verb, bool running = false, bool failed = false, long started = 0, long ended = 0) =>
    Row(id, ChatPage.ItemKind.Tool, verb, running, failed, started: started, ended: ended);
static ChatPage.DisplayItem EditRow(string id, string path, long added = 0, long removed = 0, bool failed = false) =>
    Row(id, ChatPage.ItemKind.Edit, failed: failed, path: path, added: added, removed: removed);
static List<ChatPage.DisplayItem> FoldRows(List<ChatPage.DisplayItem> rows, ChatDetail detail, bool running = false,
    Func<string, bool>? isOpen = null) => ChatDetailFold.Fold(rows, detail, running, isOpen ?? (_ => false));
static string Ids(List<ChatPage.DisplayItem> rows) => string.Join(",", rows.Select(row => row.Id));
static ChatStepGroup? GroupOf(List<ChatPage.DisplayItem> rows, string id) => rows.FirstOrDefault(row => row.Id == id).Group;

var detailRows = new List<ChatPage.DisplayItem> { Ask("u1"), Think("k1"), Tool("t1", "Read"), Tool("t2", "Read"), Say("a1") };
Check(ReferenceEquals(FoldRows(detailRows, ChatDetail.Detailed), detailRows), "Detailed changes nothing");

var turns = new List<ChatPage.DisplayItem>
{
    Ask("u1"), Think("k1"), Say("a0"), Tool("t1", "Bash"), EditRow("e1", "a.cs"), Say("a1"),
    Row("x1", ChatPage.ItemKind.Usage, cost: 0.25), Ask("u2"), Tool("t2", "Read"), Say("a2"),
};
var compact = FoldRows(turns, ChatDetail.Compact);
Check(Ids(compact) == "u1,g:k1,a0,g:t1,a1,u2,g:t2,a2", "Compact keeps replies between work groups: " + Ids(compact));
Check(GroupOf(compact, "g:k1")!.Style == ChatStepGroupStyle.Thought, "reasoning alone is a thought line");
var work = GroupOf(compact, "g:t1")!;
Check(work.Style == ChatStepGroupStyle.Work && string.Join(",", work.MemberIds) == "t1,e1", "only tool activity folds with the work");
Check(work.Steps == 2 && work.Cost == 0.25 && GroupOf(compact, "g:t2")!.Cost is null, "steps and spend ride on the work line");
foreach (var running in new[] { false, true })
{
    var replies = FoldRows([Ask("u1"), Say("a0"), Tool("t1", "Read"), Say("a1"), Tool("t2", "Bash", running: true), Say("a2")], ChatDetail.Compact, running: running);
    Check(Ids(replies) == "u1,a0,g:t1,a1,g:t2,a2", "all replies remain in order");
    Check(new[] { "a0", "a1", "a2" }.All(id => ChatDetailFold.Owner(id, replies) is null), "replies are never folded members");
}

var mustSee = new List<ChatPage.DisplayItem>
{
    Ask("u1"), Tool("t1", "Bash"), Row("p1", ChatPage.ItemKind.Approval), Tool("t2", "Bash"),
    Tool("t3", "Bash", failed: true), EditRow("e1", "a", failed: true), Row("f1", ChatPage.ItemKind.Attachment),
    Row("x1", ChatPage.ItemKind.Failed),
};
foreach (var level in Enum.GetValues<ChatDetail>())
{
    var shown = FoldRows(mustSee, level);
    foreach (var must in new[] { "u1", "p1", "t3", "e1", "f1", "x1" })
    {
        Check(shown.Any(row => row.Id == must) && ChatDetailFold.Owner(must, shown) is null, $"{level} never folds {must}");
    }
}
Check(Ids(FoldRows(mustSee, ChatDetail.Compact)) == "u1,g:t1,p1,g:t2,t3,e1,f1,x1", "an approval splits the work where it happened");
Check(Ids(FoldRows([Ask("u1"), Say("a1"), Row("x1", ChatPage.ItemKind.Usage, cost: 0.5)], ChatDetail.Compact)) == "u1,a1,x1",
    "nothing to fold keeps the usage row");
Check(Ids(FoldRows([Ask("u1"), Tool("t1", "Read"), Say("a1"), Row("x1", ChatPage.ItemKind.Usage, cost: 0)], ChatDetail.Compact)) == "u1,g:t1,a1,x1",
    "nothing spent keeps the token counts");

var live = FoldRows([Ask("u1"), Think("k1"), Tool("t1", "Read", running: true)], ChatDetail.Compact, running: true);
var liveGroup = GroupOf(live, "g:k1")!;
Check(liveGroup.Running && liveGroup.LiveVerb == "Read" && liveGroup.LiveTarget == "t-t1", "a live work line names its step");
var settled = FoldRows([Ask("u1"), Think("k1"), Tool("t1", "Read"), Say("a1")], ChatDetail.Compact, running: true);
Check(!GroupOf(settled, "g:k1")!.Running, "work before the answer is not running once its steps end");

var standard = FoldRows(
    [Ask("u1"), Think("k1"), Tool("t1", "Read"), Tool("t2", "Grep"), Tool("t3", "WebFetch"), Tool("t4", "Bash"), EditRow("e1", "a"), Say("a1")],
    ChatDetail.Standard);
Check(Ids(standard) == "u1,g:k1,g:t1,t4,e1,a1", "Standard folds thought and reads: " + Ids(standard));
var explored = GroupOf(standard, "g:t1")!;
Check(explored.Style == ChatStepGroupStyle.Explored && explored.Reads == 1 && explored.Searches == 1 && explored.Pages == 1,
    "explored counts by kind");
Check(GroupOf(standard, "g:k1")!.Preview == "Plan", "a thought previews its first line");
Check(Ids(FoldRows([Ask("u1"), Tool("t1", "Read"), Tool("t2", "Bash"), Tool("t3", "Read"), Tool("t4", "Glob"),
    Tool("t5", "Read", failed: true), Tool("t6", "Read")], ChatDetail.Standard)) == "u1,t1,t2,g:t3,t5,t6",
    "lone reads stay rows, other rows break runs");
Check(Ids(FoldRows([Ask("u1"), Think("k1")], ChatDetail.Standard, running: true)) == "u1,k1", "reasoning still arriving stays open");

var opened = FoldRows([Ask("u1"), Think("k1"), Tool("t1", "Bash"), Say("a1")], ChatDetail.Compact, isOpen: id => id == "g:k1");
Check(Ids(opened) == "u1,g:k1,k1,t1,a1" && GroupOf(opened, "g:k1")!.Open, "an open group lists its steps after it");
Check(opened[2].GroupId == "g:k1" && opened[3].GroupId == "g:k1" && opened[0].GroupId == "" && opened[4].GroupId == "",
    "steps name their group, top-level rows none");
Check(ChatDetailFold.Owner("t1", opened) is null && ChatDetailFold.Owner("t1", FoldRows([Ask("u1"), Think("k1"), Tool("t1", "Bash"), Say("a1")], ChatDetail.Compact)) == "g:k1",
    "a closed group owns its steps, an open one does not");

var growing = new List<ChatPage.DisplayItem> { Ask("u1"), Think("k1"), Tool("t1", "Bash", running: true) };
var before = Ids(FoldRows(growing, ChatDetail.Compact, running: true));
growing.Add(Tool("t2", "Bash", running: true));
Check(before == Ids(FoldRows(growing, ChatDetail.Compact, running: true)) && before == "u1,g:k1", "a growing turn keeps its line");

var counted = GroupOf(FoldRows([Ask("u1"), Tool("t1", "Bash", started: 1_000, ended: 4_000), EditRow("e1", "a.cs", 3, 1),
    EditRow("e2", "a.cs", 2), EditRow("e3", "b.cs", 1, 4), Tool("t2", "Bash", started: 5_000, ended: 9_000), Say("a1")], ChatDetail.Compact), "g:t1")!;
Check(counted.Steps == 5 && counted.Files == 2 && counted.Added == 6 && counted.Removed == 5
    && counted.StartedAt == 1_000 && counted.EndedAt == 9_000, "counts match their members");
Check(ChatDetailFold.Preview("\n\n## **Plan** it\nmore") == "Plan** it" && ChatDetailFold.Preview("\n  \n") is null,
    "previews drop markdown marks");
Console.WriteLine("Windows chat detail: compact, standard and detailed folding, pinned rows, open groups and counts pass.");

var loadedWork = new List<ChatPage.DisplayItem> { Ask("long-turn") };
loadedWork.AddRange(Enumerable.Range(0, 300).Select(index => Tool($"step-{index}", "Read")));
loadedWork.Add(Say("long-reply"));
foreach (var level in new[] { ChatDetail.Compact, ChatDetail.Standard })
{
    var drawn = FoldRows(loadedWork, level);
    Check(ChatPage.SliceStart(drawn.Count, 0) == 0 && ChatPage.SliceEnd(drawn.Count, 0) == drawn.Count,
        "a loaded page folded into a few rows must allow fetching the older archive page");
    var expanded = FoldRows(loadedWork, level, isOpen: _ => true);
    Check(ChatPage.SliceStart(expanded.Count, 0) > 0, "expanded steps first reveal the hidden loaded rows");
    var oldest = ChatPage.SliceClamp(int.MaxValue, expanded.Count);
    Check(ChatPage.SliceStart(expanded.Count, oldest) == 0, "the oldest expanded window reaches the archive boundary");
}
Console.WriteLine("Windows folded history: collapsed and expanded windows reach earlier-page boundaries.");

// Agent questions. The same stripping cases as ChatQuestionTests.swift.
var questionFence = "```" + ChatQuestionText.Fence;
var questionBlock = questionFence + "\n{\"question\":\"Which database?\"}\n```";
Check(ChatQuestionText.Strip("Plain reply.") == "Plain reply.", "text without a block is untouched");
Check(ChatQuestionText.Strip("Before:\n" + questionBlock + "\nGoing with A.") == "Before:\nGoing with A.", "a finished block leaves the prose around it");
Check(ChatQuestionText.Strip("Before:\n" + questionFence + "\n{\"question\":\"Wh") == "Before:", "a streaming block is cut from its opening line");
Check(ChatQuestionText.Strip(questionBlock) == "", "a reply that is only a question has no prose");
Check(ChatQuestionText.Strip(questionBlock.Replace("\n", "\r\n")) == "", "CRLF fences match the host scanner");
foreach (var padding in new[] { new string('x', 64 * 1024), new string('é', 32 * 1024) })
{
    var oversized = questionFence + "\n{\"question\":\"Q\",\"extra\":\"" + padding + "\"}\n```";
    Check(ChatQuestionText.Strip(oversized) == oversized, "host-rejected blocks stay readable, bounded by UTF-8 bytes");
}
var questionPrefix = "{\"question\":\"Q\",\"extra\":\"";
var questionSuffix = "\"}";
foreach (var extra in new[] { 0, 1 })
{
    var body = questionPrefix + new string('x', 64 * 1024 - 1 - questionPrefix.Length - questionSuffix.Length + extra) + questionSuffix;
    var edge = questionFence + "\n" + body + "\n```";
    Check(ChatQuestionText.Strip(edge) == (extra == 0 ? "" : edge), "the body limit includes its closing newline");
}
Check(ChatQuestionText.Strip("Run:\n```sh\nls\n```") == "Run:\n```sh\nls\n```", "ordinary code blocks stay");
foreach (var body in new[] { "{}", "broken JSON", "{\"question\":42}", "{\"question\":\" \"}" })
{
    var invalid = questionFence + "\n" + body + "\n```";
    Check(ChatQuestionText.Strip(invalid) == invalid, "a malformed question stays readable");
}
var unfinishedQuestion = questionFence + "\n{\"question\":\"Wh";
Check(ChatQuestionText.Strip(unfinishedQuestion, streaming: false) == unfinishedQuestion, "an interrupted reply stays readable");
var askedQuestion = new ChatQuestionItem("q1", "Q", ["A"], false, "A", false);
Check(askedQuestion.Answer is null && (askedQuestion with { Answer = "B" }).Answer == "B", "an answer lands on its question");
var questionRow = FoldRows([Ask("u1"), new ChatPage.DisplayItem { Id = "question-q1", Kind = ChatPage.ItemKind.Question, Question = askedQuestion }], ChatDetail.Compact);
Check(questionRow.Any(row => row.Id == "question-q1"), "a question is never folded");
Console.WriteLine("Windows chat questions: stripping, answers and folding pass.");

var signInChecks = new ChatSignInChecks();
var openGeneration = 1;
var catalogBackend = Json("""{"id":"claude","launcherId":"claude_code","readiness":"unknown"}""");
var originalBackend = catalogBackend;
var firstStatus = new TaskCompletionSource<JsonNode>();
var calls = 0;
Task<JsonNode> CheckSignIn(string launcher)
{
    Check(launcher == "claude_code", "the backend's launcher owns the probe");
    calls++;
    return firstStatus.Task;
}
JsonNode? CurrentBackend(string id) => id == "claude" ? catalogBackend : null;
var firstProbe = signInChecks.CheckAsync(originalBackend, 1, CheckSignIn, () => openGeneration, CurrentBackend);
Check(!await signInChecks.CheckAsync(originalBackend, 1, CheckSignIn, () => openGeneration, CurrentBackend)
    && calls == 1, "duplicate reads share an in-flight check");
catalogBackend = originalBackend.DeepClone();
firstStatus.SetResult(Json("""{"readiness":"needsSignIn","checked":true}"""));
Check(await firstProbe && catalogBackend["signInVerified"]!.GetValue<bool>()
    && catalogBackend["readiness"]!.GetValue<string>() == "needsSignIn", "a refresh cannot discard the CLI's answer");
Check(originalBackend["readiness"]!.GetValue<string>() == "unknown", "a detached catalog row is not updated");

var staleStatus = new TaskCompletionSource<JsonNode>();
var staleProbe = signInChecks.CheckAsync(catalogBackend, 1, _ => staleStatus.Task, () => openGeneration, CurrentBackend);
openGeneration = 2;
catalogBackend = originalBackend.DeepClone();
var nextProbe = signInChecks.CheckAsync(catalogBackend, 2,
    _ => Task.FromResult(Json("""{"readiness":"signedIn","checked":true}""")), () => openGeneration, CurrentBackend);
Check(await nextProbe, "an older conversation's probe cannot suppress the newly opened chat's check");
staleStatus.SetResult(Json("""{"readiness":"needsSignIn","checked":true}"""));
Check(!await staleProbe && catalogBackend["readiness"]!.GetValue<string>() == "signedIn",
    "a previous conversation's late answer cannot overwrite the current chat");
try
{
    await signInChecks.CheckAsync(catalogBackend, 2, _ => Task.FromException<JsonNode>(new Exception("offline")),
        () => openGeneration, CurrentBackend);
    throw new Exception("the failed check should propagate");
}
catch (Exception ex) when (ex.Message == "offline") { }
Check(await signInChecks.CheckAsync(catalogBackend, 2,
    _ => Task.FromResult(Json("""{"readiness":"unknown","checked":false}""")), () => openGeneration, CurrentBackend),
    "a failed probe releases its reservation for another attempt");
Console.WriteLine("Windows sign-in: refreshed catalogs, navigation, shared probes and failed-check retries pass.");
