// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Tokenstat.Pages;

static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
var store = new NoteDraftStore();
var original = new NoteDraftStore.Text("A title", "original");
store.Open("a", original);
store.Edit("a", original with { Notes = "first edit" });
var gate = new TaskCompletionSource();
var writes = new List<NoteDraftStore.Text>();
var saving = store.SaveAsync("a", async text => { writes.Add(text); if (writes.Count == 1) await gate.Task; });
store.Edit("a", new("  Latest title  ", "typed during save"));
var duplicate = store.SaveAsync("a", _ => throw new Exception("Overlapping write"));
Check(ReferenceEquals(saving, duplicate), "Concurrent saves should await the same drain");
Check(store.Open("a", original).Notes == "typed during save", "Navigation lost a draft during save");
store.Open("b", original);
store.Edit("b", original with { Notes = "independent note" });
await store.SaveAsync("b", _ => Task.CompletedTask);
Check(!store.Get("b")!.Dirty && !saving.IsCompleted, "One note blocked another note's save");
gate.SetResult();
await saving;
Check(writes.Count == 2 && writes[^1] == new NoteDraftStore.Text("Latest title", "typed during save"),
    "The newest edit was not drained after the pending write");
Check(!store.Get("a")!.Dirty && !store.Get("a")!.Saving, "Successful save left a dirty or busy draft");
store.Edit("a", new("", "Keep body when title is blank"));
await store.SaveAsync("a", text => { Check(text.Title == "Latest title", "Blank title discarded saved title"); return Task.CompletedTask; });
store.Edit("a", new("Retry title", "Never lose this"));
await store.SaveAsync("a", _ => Task.FromException(new Exception("offline")));
Check(store.Get("a")!.Dirty && store.Get("a")!.Error == "offline" && !store.Get("a")!.Saving,
    "Failure lost a draft or left it busy");
Check(store.Open("a", original).Notes == "Never lose this", "Reopening a failed draft lost its text");
await store.SaveAsync("a", _ => Task.CompletedTask);
Check(!store.Get("a")!.Dirty && store.Get("a")!.Error is null, "Retry did not save and clear the error");
// Returning to the saved version while a different version is in flight is
// still a new edit: it must write back after that older request completes.
var saved = store.Get("a")!.Saved;
store.Edit("a", saved with { Notes = "temporary" });
gate = new TaskCompletionSource(); writes.Clear();
saving = store.SaveAsync("a", async text => { writes.Add(text); if (writes.Count == 1) await gate.Task; });
store.Edit("a", saved);
Check(ReferenceEquals(saving, store.SaveAsync("a", _ => Task.CompletedTask)), "Reverting while saving skipped the pending request");
gate.SetResult(); await saving;
Check(writes.Count == 2 && writes[^1] == saved && !store.Get("a")!.Dirty, "Reverting during save persisted the wrong version");
Console.WriteLine("Windows notes: ordered saves, concurrent edits, navigation, retry and blank titles passed");

var reloading = new NoteDraftStore();
var firstRead = reloading.BeginRead();
reloading.Open("note", original, firstRead);
var staleRead = reloading.BeginRead();
var latest = original with { Notes = "saved while the list was in flight" };
reloading.Edit("note", latest);
await reloading.SaveAsync("note", _ => Task.CompletedTask);
Check(reloading.Open("note", original, staleRead) == latest,
    "A delayed list replaced a body that was saved after its read began");
var afterSave = reloading.BeginRead();
var external = original with { Notes = "edited on another client" };
Check(reloading.Open("note", external, afterSave) == external,
    "A fresh host read could not replace a clean locally saved body");
Console.WriteLine("Windows notes: delayed reads preserve acknowledged saves and fresh reads reconcile clean notes");

var markdown = NoteMarkdown.Parse("# Heading\n\n- [x] Done\n- [ ] Later\n\n> Quote\n\n**Bold** &amp; *italic* ~~removed~~\n\n```swift\nlet n = 1\n```\n\n<script>alert(1)</script>");
Check(markdown.OfType<Markdig.Syntax.HeadingBlock>().Count() == 1, "Heading was not parsed");
Check(markdown.OfType<Markdig.Syntax.ListBlock>().Count() == 1, "Checklist was not parsed");
Check(markdown.OfType<Markdig.Syntax.QuoteBlock>().Count() == 1, "Quote was not parsed");
Check(markdown.OfType<Markdig.Syntax.FencedCodeBlock>().Single().Lines.ToString().Contains("let n = 1"), "Code block text changed");
Check(!markdown.OfType<Markdig.Syntax.HtmlBlock>().Any(), "Raw HTML was enabled");
foreach (var link in new[] { "https://example.com", "http://example.com", "mailto:test@example.com" })
    Check(NoteMarkdown.Link(link) is not null, "Ordinary link was rejected");
foreach (var link in new[] { "javascript:alert(1)", "file:///private/document", "data:text/html,hello", "../relative", "tokenstat:delete" })
    Check(NoteMarkdown.Link(link) is null, "A note exposed an executable/local navigation action");
Console.WriteLine("Windows note Markdown: headings, checklist, quotes, code and link policy passed");

var checklist = NoteFormatting.Apply("first\nsecond\nthird", 2, 11, "- [ ] ", "", "To do", true);
Check("first\nsecond\nthird".Remove(checklist.Start, checklist.Length).Insert(checklist.Start, checklist.Replacement)
    == "- [ ] first\n- [ ] second\nthird", "Checklist did not format complete selected lines");
var formattedUnicode = NoteFormatting.Apply("A 🐈 sleeps", 2, 2, "**", "**", "text", false);
Check(formattedUnicode.Replacement == "**🐈**" && formattedUnicode.SelectionLength == 2,
    "Formatting lost Unicode or selection");
var finalLine = NoteFormatting.Apply("one\n", 4, 0, "- ", "", "List item", true);
Check(finalLine.Start == 4 && finalLine.Replacement == "- List item", "Empty final line formatting changed preceding text");
Console.WriteLine("PASS: note formatting preserves paragraphs, Unicode and selected text");
