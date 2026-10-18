// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Tokenstat.Pages;

static JsonNode Json(string text) => JsonNode.Parse(text)!;
static void Check(bool answer, string message) { if (!answer) throw new Exception(message); }
Check(SessionIdentities.Read(null).Entries.Count == 0 && SessionIdentities.Read(Json("{}" )).Entries.Count == 0,
    "older hosts omit native IDs without falling back to opaque resume credentials");
const string nativeSessionId = "11111111-1111-4111-8111-111111111111";
foreach (var backend in new[] { "claude", "codex", "cursor", "muse", "grok", "agy" }) {
    Check(SessionIdentities.ValidNativeId(backend, nativeSessionId), "known native UUID session IDs are copyable");
    foreach (var secret in new[] { "eyJhbGciOiJIUzI1NiJ9.credential", "/private/resume.json", "session-name", "00000000-0000-0000-0000-000000000000" })
        Check(!SessionIdentities.ValidNativeId(backend, secret), "credentials, resume titles and paths are not copyable session IDs");
}
Check(SessionIdentities.ValidNativeId("opencode2", "ses_012345abcdef0123456789abcd")
    && !SessionIdentities.ValidNativeId("sh", nativeSessionId), "OpenCode IDs use their native shape and unknown backends do not invent IDs");
var identityRows = SessionIdentities.Read(Json("""{"total":4,"entries":[{"backend":"claude","id":"11111111-1111-4111-8111-111111111111","status":"current"},{"backend":"claude","id":"11111111-1111-4111-8111-111111111111","status":"saved"},{"backend":"codex","id":"22222222-2222-4222-8222-222222222222","status":"newer-status","sourceConversationId":"old-chat"},{"backend":"muse","id":"private-blob"}]}"""));
Check(identityRows.Entries.Count == 2 && identityRows.Entries[0].Status == "current" && identityRows.Entries[1].Status == "historical"
    && identityRows.Entries[1].SourceConversationId == "old-chat" && identityRows.Truncated && identityRows.Total == 4,
    "inspection and PTY inventories deduplicate valid IDs, keep source ownership, treat new statuses as references and disclose omitted history");
Check(SessionIdentities.Read(Json("""{"total":"bad","truncated":{},"entries":[null,{},17,{"backend":19,"id":true}]}""")).Entries.Count == 0,
    "malformed optional inventory metadata cannot break older-host chat or terminal details");
var inheritedIds = SessionIdentities.Read(Json("""{"entries":[{"backend":"claude","id":"11111111-1111-4111-8111-111111111111","status":"historical","sourceConversationId":"chat-origin"},{"backend":"claude","id":"11111111-1111-4111-8111-111111111111","status":"saved","sourceConversationId":"chat-intermediate"},{"backend":"claude","id":"11111111-1111-4111-8111-111111111111","status":"current","sourceConversationId":"chat-intermediate"},{"backend":"codex","id":"22222222-2222-4222-8222-222222222222","status":"saved","sourceConversationId":"/private/transcript"}]}"""));
Check(inheritedIds.Entries.Count == 2 && inheritedIds.Entries[0].Status == "current"
    && inheritedIds.SourceConversationIds.SequenceEqual(new[] { "chat-origin", "chat-intermediate" }),
    "current IDs win independent of report order, while inherited source chat IDs stay deduplicated and copyable");
var boundedRows = new JsonArray();
for (var index = 0; index < 70; index++) boundedRows.Add(new JsonObject {
    ["backend"] = "codex", ["id"] = $"{index + 1:x8}-1111-4111-8111-111111111111", ["status"] = index == 69 ? "current" : "historical",
    ["sourceConversationId"] = $"chat-{index}",
});
var boundedIds = SessionIdentities.Read(new JsonObject { ["entries"] = boundedRows });
Check(boundedIds.Entries.Count == 64 && boundedIds.SourceConversationIds.Count == 64 && boundedIds.Entries[0].Status == "current"
    && boundedIds.Total == 70 && boundedIds.Truncated,
    "large inventories remain bounded without hiding the current session behind historical rows");
Check(SessionIdentities.Read(Json("""{"resumeToken":"11111111-1111-4111-8111-111111111111","meter":{"sessionIdentities":{"entries":[{"backend":"codex","id":"11111111-1111-4111-8111-111111111111","status":"current"}]}}}""")).Entries.Count == 0,
    "session projections never search credentials or nested terminal meters for native IDs");
Check(!NewChatSetup.ShouldSend("") && !NewChatSetup.ShouldSend(" \n ") && NewChatSetup.ShouldSend("Review this"),
    "explicit empty Open chat creates the normal composer without dispatching a model prompt; nonempty drafts retain Send");
var selectedNewChatSetup = new NewChatSetup("codex", "model", "high");
Check(selectedNewChatSetup.Mode == "execute" && selectedNewChatSetup.Autonomy == "bypass",
    "an untouched landing composer uses Execute and Don't ask from its initial setup");
Check(selectedNewChatSetup.IsAvailable(Json("""{"id":"codex","models":["model"],"efforts":["high"]}""")), "older descriptors without installed flag still validate explicit new-chat selections");
foreach (var descriptor in new[] { """{"id":"claude","models":["model"],"efforts":["high"]}""", """{"id":"codex","installed":false,"models":["model"],"efforts":["high"]}""", """{"id":"codex","models":["other-model"],"efforts":["high"]}""", """{"id":"codex","models":["model"],"efforts":["low"]}""" })
    Check(!selectedNewChatSetup.IsAvailable(Json(descriptor)), "a changed agent, model, effort or installation cannot silently replace the captured landing setup");
Check(!selectedNewChatSetup.IsAvailable(null) && new NewChatSetup("codex", null, null).IsAvailable(Json("""{"id":"codex"}""")), "absent agents fail while explicitly chosen default settings require no invented model");
Check(!new NewChatSetup("", null, null).IsAvailable(Json("""{"id":""}""")), "an empty agent descriptor cannot become a launch choice");
Check(NewChatSetup.ShouldSend("", 1), "file-only landing prompts use explicit Send");
Check(!new NewChatSetup("codex", null, null, "invented").IsAvailable(Json("""{"id":"codex"}"""))
    && !new NewChatSetup("codex", null, null, "execute", "invented").IsAvailable(Json("""{"id":"codex"}""")), "captured mode and autonomy are validated");
Check(!new NewChatSetup("agy", null, null, Autonomy: "standard").IsAvailable(Json("""{"id":"agy","gateTier":"bypassOnly"}"""))
    && new NewChatSetup("agy", null, null, "plan", "bypass").IsAvailable(Json("""{"id":"agy","gateTier":"bypassOnly"}""")), "a bypass-only agent retains its applicable autonomy choice");
Check(new NewChatSetup("codex", "model", "high", FastMode: true).IsAvailable(Json("""{"id":"codex","models":["model"],"efforts":["high"],"fastModeModels":[]}"""))
    && !new NewChatSetup("codex", "model", "high", FastMode: true).IsAvailable(Json("""{"id":"codex","models":["model"],"efforts":["high"]}""")), "fast mode must be explicitly offered by the current agent catalog");
var stagedPath = Path.GetTempFileName();
try {
    File.WriteAllBytes(stagedPath, [1, 2, 3]);
    var selected = await NewChatFile.CaptureAsync(stagedPath);
    Check(selected.IsCurrent() && selected.Size == 3 && selected.Path != Path.GetFullPath(stagedPath)
        && selected.Name == Path.GetFileName(stagedPath) && File.ReadAllBytes(selected.Path).SequenceEqual(new byte[] { 1, 2, 3 }),
        "landing attachment selection makes an owned private copy before any conversation exists");
    var landingDrafts = new NewChatDraftStore();
    var firstDraft = new NewChatDraft("unbound prompt", [selected], new NewChatSetup("codex", "model", "high", "plan", "bypass", true));
    Check(new NewChatDraftStore().Select("first-repo", new NewChatDraft("", [], firstDraft.Setup)).Setup == firstDraft.Setup,
        "initial setup-only choices also follow the first repository selection");
    var automatic = new NewChatDraftStore();
    var shown = automatic.Select("auto-repo", firstDraft, adoptUnbound: false);
    Check(shown.Text == firstDraft.Text && shown.Files.SequenceEqual(firstDraft.Files) && automatic.Repository is null && automatic.Revision == 0,
        "an automatic folder preview leaves the unbound draft on screen and unclaimed");
    var adopted = automatic.Select("chosen-repo", shown);
    Check(adopted.Text == firstDraft.Text && adopted.Files.SequenceEqual(firstDraft.Files) && automatic.Repository == "chosen-repo",
        "the first explicit repository choice still adopts the unbound draft after an automatic preview");
    var firstBound = landingDrafts.Select("host-one/repo", firstDraft);
    Check(landingDrafts.AcceptsFiles(null, 0), "an import started before choosing a repository follows that first selection");
    Check(firstBound.Text == firstDraft.Text && firstBound.Files.SequenceEqual(firstDraft.Files) && firstBound.Setup == firstDraft.Setup,
        "the initial repository choice carries unbound words, files, mode, autonomy and fast mode together");
    var firstRevision = landingDrafts.Revision;
    var secondBound = landingDrafts.Select("host-two/repo", firstBound);
    Check(!landingDrafts.AcceptsFiles(null, 0) && !landingDrafts.AcceptsFiles("host-one/repo", firstRevision),
        "later repository changes reject stale picker and in-progress copy owners");
    Check(secondBound.Text.Length == 0 && secondBound.Files.Length == 0 && secondBound.Setup is null && landingDrafts.Revision > firstRevision,
        "the same repository name on another host has a separate landing draft and retires picker ownership");
    var secondDraft = new NewChatDraft("other computer", [], new NewChatSetup("claude", null, "low"));
    var restoredFirst = landingDrafts.Select("host-one/repo", secondDraft);
    Check(restoredFirst.Text == firstDraft.Text && restoredFirst.Files.SequenceEqual(firstDraft.Files) && restoredFirst.Setup == firstDraft.Setup,
        "switching repositories restores the complete earlier draft instead of carrying controls or files across owners");
    var unselected = landingDrafts.Select(null, restoredFirst);
    Check(unselected.Text.Length == 0 && unselected.Files.Length == 0, "removing a selected repository does not move its draft to the unbound page");
    var third = landingDrafts.Select("host-three/repo", new NewChatDraft("unselected text", [], null));
    Check(third.Text.Length == 0, "unbound transfer happens only for the first repository selection");
    Check(landingDrafts.Select("host-two/repo", third).Text == secondDraft.Text, "unselecting or adding another repository retains all earlier owner drafts");
    File.WriteAllBytes(stagedPath, [1, 2, 3, 4]);
    Check(selected.IsCurrent() && File.ReadAllBytes(selected.Path).SequenceEqual(new byte[] { 1, 2, 3 }), "editing the original cannot replace the selected attachment bytes");
    var movedSource = stagedPath + ".moved";
    File.Move(stagedPath, movedSource);
    File.Delete(movedSource);
    Check(selected.IsCurrent() && File.ReadAllBytes(selected.Path).SequenceEqual(new byte[] { 1, 2, 3 }), "moving or deleting the original screenshot leaves the staged attachment usable");
    File.WriteAllBytes(stagedPath, [8, 9]);
    var staleSelection = await NewChatFile.CaptureAsync(stagedPath);
    Check(staleSelection.RetainIfOwned(false) is null && !File.Exists(staleSelection.Path) && File.Exists(stagedPath),
        "a picker or copy result from a retired owner deletes its private snapshot and preserves the source");
    new NewChatFile(stagedPath, "source", 2, File.GetLastWriteTimeUtc(stagedPath)).Discard();
    Check(File.Exists(stagedPath), "cleanup refuses to delete a path outside the owned staging directory");
    landingDrafts.DiscardFiles();
    Check(!File.Exists(selected.Path) && File.Exists(stagedPath), "retiring an account cleans all repository draft copies without deleting source files");
    using var cancelledSelection = new CancellationTokenSource(); cancelledSelection.Cancel();
    try { await NewChatFile.CaptureAsync(stagedPath, cancelledSelection.Token); throw new Exception("cancelled selection copied bytes"); }
    catch (OperationCanceledException) { }
    File.Delete(stagedPath);
} finally { File.Delete(stagedPath); }
const long imageFileMaximum = 256L * 1024 * 1024;
Check(ChatImagePolicy.DownloadLimit(false, true, imageFileMaximum) == 5L * 1024 * 1024,
    "automatic remote image previews use the separate 5 MiB policy");
Check(ChatImagePolicy.DownloadLimit(false, false, imageFileMaximum) == imageFileMaximum
    && ChatImagePolicy.DownloadLimit(true, true, imageFileMaximum) == imageFileMaximum
    && ChatImagePolicy.DownloadLimit(true, false, imageFileMaximum) == imageFileMaximum,
    "local automatic previews and explicit viewer downloads retain the file-backed limit");
Check(ChatImagePolicy.DownloadLimit(false, true, 1024) == 1024, "the remote preview policy cannot raise a smaller file limit");
Console.WriteLine("Windows image preview policy: separate remote automatic limit and local/explicit file-backed limits pass.");
var tripleLayout = ChatImageLayout.Measure([2, 1, 1.5], 1000);
Check(tripleLayout.Tiles.Count == 3 && tripleLayout.Tiles.All(tile => tile.Y == 0)
    && Math.Abs(tripleLayout.Width - 640) < .001 && Math.Abs(tripleLayout.Tiles[0].Width / tripleLayout.Tiles[1].Width - 2) < .001,
    "three images share one width-capped row with source-proportional tile widths");
var portraitLayout = ChatImageLayout.Measure([.75], 1000);
Check(portraitLayout.Height == 300 && portraitLayout.Width == 225, "single portraits retain their aspect within a 300-pixel height");
var wideLayout = ChatImageLayout.Measure([3], 1000);
Check(Math.Abs(wideLayout.Width - 640) < .001 && wideLayout.Height <= 300,
    "single landscape images use available width while remaining height-bounded");
var clampedLayout = ChatImageLayout.Measure([.1, 10], 640);
Check(Math.Abs(clampedLayout.Tiles[0].Width / clampedLayout.Tiles[1].Width - .65 / 2.2) < .001,
    "extreme aspect ratios are bounded without changing source image stretching");
var pairedLayout = ChatImageLayout.Measure([1.8, 1.2, 1, 1.5, 2], 640);
Check(pairedLayout.Tiles.Count == 4 && pairedLayout.Tiles.GroupBy(tile => tile.Y).Select(row => row.Count()).SequenceEqual(new[] { 2, 2 })
    && pairedLayout.Tiles.All(tile => tile.Height <= 240) && pairedLayout.Height <= 486,
    "four or more images use two bounded paired rows and leave overflow to the count badge");
foreach (var available in new[] { 1d, 150, 320, 640, 1000, double.NaN })
{
    var geometry = ChatImageLayout.Measure([double.NaN, 0, double.PositiveInfinity], available);
    Check(double.IsFinite(geometry.Width) && double.IsFinite(geometry.Height)
        && geometry.Width <= Math.Min(double.IsFinite(available) ? Math.Max(44, available) : 640, 640) + .001
        && geometry.Tiles.All(tile => tile.Width >= 44 - .001 && tile.Height >= 44 && tile.X >= 0 && tile.X + tile.Width <= geometry.Width + .001),
        "fallback metadata produces finite positive geometry even in narrow layouts");
    Check(geometry.Tiles.Max(tile => tile.Width) - geometry.Tiles.Min(tile => tile.Width) < .001,
        "unknown image dimensions use the same 1.2 fallback aspect");
}
var mixedTouchLayout = ChatImageLayout.Measure([.65, 2.2, 2.2], 280);
Check(mixedTouchLayout.Tiles.All(tile => tile.Y == 0 && tile.Width >= 44 && tile.Height >= 44)
    && mixedTouchLayout.Tiles[0].Width == 44 && Math.Abs(mixedTouchLayout.Width - 280) < .001
    && Math.Abs(mixedTouchLayout.Tiles[1].Width - mixedTouchLayout.Tiles[2].Width) < .001,
    "mixed-aspect three-up rows reserve narrow touch targets before proportionally sharing remaining width");
var narrowTouchLayout = ChatImageLayout.Measure([.65, 2.2, 2.2], 140);
Check(narrowTouchLayout.Tiles.Select(tile => tile.Y).Distinct().Count() == 2
    && narrowTouchLayout.Tiles.All(tile => tile.Width >= 44 && tile.Height >= 44),
    "columns decrease only when a row cannot fit 44-pixel targets and their gaps");
var stripLayout = ChatImageLayout.Measure([.65, 2.2, 1, 1.5], 640, compact: true);
Check(stripLayout.Height == 58 && stripLayout.Width == 312 && stripLayout.Tiles.Select(tile => tile.Width).Distinct().Count() == 1,
    "tool thumbnails retain their compact equal-width strip");
Check(ChatImageLayout.Measure([], 640).Tiles.Count == 0 && ChatImageLayout.Aspect(1280, 720) == 1280d / 720
    && ChatImageLayout.Aspect(100, 0) == 1.2, "empty galleries and missing source dimensions have explicit fallbacks");
Console.WriteLine("Windows gallery geometry: aspect-weighted 1–3 rows, paired overflow rows, narrow bounds, metadata fallbacks and compact tool strips pass.");
static ChatPage.DisplayItem GalleryImage(string id, string call = "", string scope = "turn/backend") => new() {
    Id = id, Kind = ChatPage.ItemKind.Attachment, Name = id + ".png", MediaType = "image/png", ToolCallId = call, AttachmentScope = scope,
};
var ordinaryGallery = ChatImageGallery.Compose([GalleryImage("one"), GalleryImage("two"), GalleryImage("three"), GalleryImage("four"), GalleryImage("five")]);
Check(ordinaryGallery.Count == 1 && ordinaryGallery[0].Images?.Count == 5 && ChatImageGallery.VisibleLimit == 4,
    "consecutive images retain all viewer entries with only four visible thumbnails");
var galleryTool = new ChatPage.DisplayItem { Id = "tool-one", Kind = ChatPage.ItemKind.Tool, ToolCallId = "call", AttachmentScope = "turn/backend" };
var linkedGallery = ChatImageGallery.Compose([galleryTool, new() { Kind = ChatPage.ItemKind.Assistant, Id = "reply" }, GalleryImage("result", "call")]);
Check(linkedGallery.Count == 3 && linkedGallery[1].Kind == ChatPage.ItemKind.Gallery && linkedGallery[1].Images![0].Id == "result"
    && linkedGallery[2].Id == "reply", "explicit provenance places a thumbnail beside its step without a standalone duplicate");
var galleryGroup = new ChatPage.DisplayItem { Id = "group", Kind = ChatPage.ItemKind.Group,
    Group = new ChatStepGroup { Open = false, Members = [galleryTool], MemberIds = [galleryTool.Id] } };
var groupedGallery = ChatImageGallery.Compose([galleryGroup, GalleryImage("result", "call")]);
Check(groupedGallery.Count == 2 && groupedGallery[1].ToolCallId == "group", "closed step groups retain linked image thumbnails");
var beforeTool = ChatImageGallery.Compose([GalleryImage("before", "call"), galleryTool]);
Check(beforeTool.Count == 2 && beforeTool[0].Images![0].Id == "before" && string.IsNullOrEmpty(beforeTool[0].ToolCallId),
    "an image with no preceding owner never moves onto a later step");
var laterTool = galleryTool; laterTool.Id = "tool-two";
var repeatedCallGallery = ChatImageGallery.Compose([galleryTool, GalleryImage("first-output", "call"), laterTool, GalleryImage("second-output", "call")]);
Check(repeatedCallGallery.Count == 4 && repeatedCallGallery[1].Images!.Single().Id == "first-output"
    && repeatedCallGallery[3].Images!.Single().Id == "second-output", "reused call IDs belong to their most recent preceding step");
var beforeGroup = ChatImageGallery.Compose([GalleryImage("before-group", "call"), galleryGroup]);
Check(beforeGroup.Count == 2 && string.IsNullOrEmpty(beforeGroup[0].ToolCallId), "a folded future step cannot claim an earlier image");
var laterGroup = galleryGroup; laterGroup.Id = "later-group"; laterGroup.Group = new ChatStepGroup { Open = false, Members = [laterTool], MemberIds = [laterTool.Id] };
var repeatedGrouped = ChatImageGallery.Compose([galleryGroup, GalleryImage("first-group-output", "call"), laterGroup, GalleryImage("second-group-output", "call")]);
Check(repeatedGrouped.Count == 4 && repeatedGrouped[1].Images!.Single().Id == "first-group-output"
    && repeatedGrouped[3].Images!.Single().Id == "second-group-output", "reused calls in closed groups keep their own output");
foreach (var scope in new[] { "another-turn/backend", "turn/another-backend" })
{
    var orphan = ChatImageGallery.Compose([galleryTool, new() { Kind = ChatPage.ItemKind.Assistant, Id = "reply" }, GalleryImage("result", "call", scope)]);
    Check(orphan[^1].Images![0].Id == "result" && string.IsNullOrEmpty(orphan[^1].ToolCallId), "reused call IDs cannot associate images across turns or backends");
}
var mixedGallery = ChatImageGallery.Compose([GalleryImage("one"), new() { Kind = ChatPage.ItemKind.Attachment, Id = "pdf", MediaType = "application/pdf" }, GalleryImage("two")]);
Check(mixedGallery.Count == 3 && mixedGallery[1].Id == "pdf", "non-image attachments preserve ordering and their download rows");
var separatedGalleries = ChatImageGallery.Compose([
    GalleryImage("first", scope: "turn-one/muse"), GalleryImage("second", scope: "turn-one/muse"),
    GalleryImage("backend-change", scope: "turn-one/codex"), GalleryImage("turn-change", scope: "turn-two/codex"),
    GalleryImage("orphan-one", "call-one", "turn-two/codex"), GalleryImage("orphan-two", "call-two", "turn-two/codex"),
    GalleryImage("orphan-two-more", "call-two", "turn-two/codex"),
]);
Check(separatedGalleries.Count == 5 && separatedGalleries[0].Images!.Count == 2 && separatedGalleries[^1].Images!.Count == 2,
    "ordinary galleries break at backend, user-turn and distinct orphan-call boundaries");
Console.WriteLine("Windows image galleries: bounded thumbnails, complete viewer lists, exact scoped provenance, folded groups and orphan fallback pass.");
var toolOwnership = new ChatToolCalls();
toolOwnership.Remember("turn/muse", "muse", "historical-call", 3);
Check(toolOwnership.TryResolve("turn/codex", "historical-call", out var historicalOwner)
    && historicalOwner.Index == 3 && historicalOwner.Scope == "turn/muse" && historicalOwner.Backend == "muse",
    "an end stamped with the newer selected backend retains the unique original tool owner");
Check(MuseToolPresentation.Refine(historicalOwner.Backend, "Bash Input", "", "{\"command\":\"cargo test\"}") == ("Bash", "cargo test"),
    "historical Muse tool metadata is refined using the original backend");
toolOwnership.Remember("turn/codex", "codex", "historical-call", 7);
Check(!toolOwnership.TryResolve("turn/claude", "historical-call", out _),
    "a mismatched backend cannot choose between two original call namespaces");
Check(toolOwnership.TryResolve("turn/muse", "historical-call", out var museOwner) && museOwner.Index == 3 && museOwner.Backend == "muse"
    && toolOwnership.TryResolve("turn/codex", "historical-call", out var codexOwner) && codexOwner.Index == 7 && codexOwner.Backend == "codex",
    "exact scoped ends retain their own original backend even when call IDs collide");
toolOwnership.Clear();
Check(!toolOwnership.TryResolve("next-turn/codex", "historical-call", out _), "user-turn boundaries retire historical call fallbacks");
var interruptedTools = new List<ChatPage.DisplayItem> {
    new() { Id = "interrupted-tool", Kind = ChatPage.ItemKind.Tool, Running = true },
    new() { Id = "interrupted-edit", Kind = ChatPage.ItemKind.Edit, Running = true, Detail = "Keep recorded output" },
    new() { Id = "completed-tool", Kind = ChatPage.ItemKind.Tool, Running = false, Failed = true },
};
toolOwnership.Remember("old-turn/codex", "codex", "tool", 0);
toolOwnership.Remember("old-turn/codex", "codex", "edit", 1);
toolOwnership.Remember("old-turn/codex", "codex", "done", 2);
toolOwnership.CloseRunning(interruptedTools, failed: false, detail: "Interrupted");
toolOwnership.Clear();
Check(interruptedTools.All(item => !item.Running) && interruptedTools[0].Detail == "Interrupted"
    && interruptedTools[1].Detail == "Keep recorded output" && interruptedTools[2].Failed,
    "ordinary user boundaries close interrupted tools and merged edits before retiring their owners");
var repeatedOwners = new ChatToolCalls();
Check(repeatedOwners.Remember("turn/codex", "codex", "reused", 0) == 1
    && repeatedOwners.Remember("turn/codex", "codex", "reused", 1) == 2, "repeated starts keep a distinct stable occurrence for transcript row IDs");
var concurrent = new List<ChatPage.DisplayItem> {
    new() { Kind = ChatPage.ItemKind.Tool, Running = true }, new() { Kind = ChatPage.ItemKind.Edit, Running = true },
};
Check(repeatedOwners.TryResolve("turn/codex", "reused", out var firstConcurrent, index => concurrent[index].Running) && firstConcurrent.Index == 0,
    "a repeated call end closes the oldest still-running start");
var completedConcurrent = concurrent[0]; completedConcurrent.Running = false; concurrent[0] = completedConcurrent;
Check(repeatedOwners.TryResolve("turn/old-backend-stamp", "reused", out var nextConcurrent, index => concurrent[index].Running)
    && nextConcurrent.Index == 1 && nextConcurrent.Backend == "codex", "the unique historical namespace still resolves the next running repeated start");
repeatedOwners.CloseRunning(concurrent, failed: true, detail: "Cancelled");
Check(concurrent.All(item => !item.Running) && !concurrent[0].Failed && concurrent[1].Failed,
    "closing interrupted repeated starts preserves terminal rows and closes every remaining tool or merged edit");
Check(repeatedOwners.TryResolve("turn/codex", "reused", out var repeatedEnd, index => concurrent[index].Running) && repeatedEnd.Index == 1,
    "duplicate ends with no running starts resolve the newest recorded occurrence");
Console.WriteLine("Windows tool ownership: historical backend stamps, original Muse metadata, scoped collisions and user-turn retirement pass.");
Check(ChatCommandRules.CanSteer("  include tests  ", false, false), "trimmed short drafts can steer");
Check(!ChatCommandRules.CanSteer(" /usr/local/file ", false, false)
    && !ChatCommandRules.CanSteer("/unknown argument", true, true), "slash-leading literals must queue instead of being rejected by native steering");
Check(ChatCommandRules.CanSteer(new string('x', 1500), false, false)
    && !ChatCommandRules.CanSteer(new string('x', 1501), false, false), "native steering accepts exactly 1500 Unicode scalars");
Check(ChatCommandRules.CanSteer(string.Concat(Enumerable.Repeat("😀", 1500)), false, false)
    && !ChatCommandRules.CanSteer(string.Concat(Enumerable.Repeat("😀", 1501)), false, false)
    && !ChatCommandRules.CanSteer(string.Concat(Enumerable.Repeat("e\u0301", 751)), false, false), "steering limits count scalars rather than UTF-16 units or graphemes");
Check(!ChatCommandRules.CanSteer("  ", false, true) && ChatCommandRules.CanSteer("  ", true, true)
    && !ChatCommandRules.CanSteer("include tests", true, false)
    && !ChatCommandRules.CanSteer(new string('x', 1501), true, true), "attachments require capability and preserve the text limit");
Console.WriteLine("Windows native steering: literal paths, scalar limits and attachment eligibility pass.");
foreach (var backend in new[] { "claude", "codex", "cursor", "muse", "opencode", "opencode2", "grok", "agy", "sh" }) {
    foreach (var name in ChatCommandRules.Names.Where(n => n is not ("/compact" or "/stop")))
        Check(ChatCommandRules.Evaluate(name, backend, true, false).Kind == ChatCommandRules.Kind.Inspect, "read commands must work without an idle backend");
    Check(ChatCommandRules.Evaluate("/compact", backend, false, false).Kind == (backend is "claude" or "codex" ? ChatCommandRules.Kind.Compact : ChatCommandRules.Kind.Unsupported), "native compaction capabilities");
}
Check(ChatCommandRules.Evaluate("/sta", "sh", true, false).Completion == "/status", "prefix completion must not send a prompt");
Check(ChatCommandRules.Evaluate("/compact", "codex", true, false).Kind == ChatCommandRules.Kind.Running, "compact cannot become a note");
Check(ChatCommandRules.Evaluate("/status\nhello", "claude", false, false).Kind == ChatCommandRules.Kind.Arguments, "multiline command arguments must remain drafts");
Check(ChatCommandRules.Evaluate("/status", "claude", false, true).Kind == ChatCommandRules.Kind.Attachments, "files must survive local commands");
Check(ChatCommandRules.Evaluate("/usr/local/file", "sh", false, false).Kind == ChatCommandRules.Kind.Message, "literal paths are messages");
Console.WriteLine("Windows chat commands: completion, backend capabilities, busy refusal and attachment preservation pass.");
Check(ChatActivityData.Read(Json("{}"), Json("{\"running\":true}")) is null, "old hosts do not imply empty or zero activity");
var unreportedActivity = ChatActivityData.Read(Json("""{"currentRun":true,"activity":{"goalReported":false,"planReported":false,"agentsReported":false,"live":true,"goal":{"objective":"hidden","tokensUsed":0},"agents":[{"id":"hidden","status":"running"}]}}"""), Json("""{"running":true}"""))!;
Check(!unreportedActivity.HasContent && unreportedActivity.Goal is null && unreportedActivity.RunningAgents is null, "unreported categories cannot manufacture goal or agent counts");
var activityInspection = Json("""{"currentRun":true,"activity":{"goalReported":true,"planReported":true,"agentsReported":true,"live":true,"goal":{"objective":"Ship","status":"usageLimited","tokensUsed":0,"tokenBudget":-1,"timeUsedSeconds":"bad"},"plan":[{"text":"Build","status":"completed"},{"text":"Review","status":"other"}],"agents":[{"id":"one","status":"running"},{"id":"two","status":"completed"},{"name":"Missing ID"}]}}""");
var activityData = ChatActivityData.Read(activityInspection, Json("""{"running":true}"""))!;
Check(activityData.Goal!.Status == "usageLimited" && activityData.Goal.TokensUsed == 0 && activityData.Goal.TokenBudget is null && activityData.Goal.TimeUsedSeconds is null, "reported zero remains valid while missing or malformed budget metrics remain unknown");
Check(activityData.CompletedSteps == 1 && activityData.Plan[1].Status == "unknown" && activityData.Agents.Length == 2 && activityData.RunningAgents == 1, "only valid recorded states contribute to activity progress");
Check(activityData.Agents[0].DisplayStatus(false) == "unknown" && activityData.Agents[1].DisplayStatus(false) == "completed", "stale active agent statuses become unknown while recorded terminal statuses remain visible");
Check(ChatActivityData.Read(activityInspection, Json("""{"running":false}"""))!.RunningAgents is null, "finished chats cannot retain a live running-agent count");
activityInspection["currentRun"] = false;
Check(ChatActivityData.Read(activityInspection, Json("""{"running":true}"""))!.RunningAgents is null, "a current chat cannot reactivate a retained previous-run agent");
activityInspection["currentRun"] = true; activityInspection["activity"]!["live"] = false;
Check(ChatActivityData.Read(activityInspection, Json("""{"running":true}"""))!.RunningAgents is null, "historical activity remains historical inside a running conversation");
var unknownAgentLifecycle = Json("""{"currentRun":true,"activity":{"agentsReported":true,"live":true,"agents":[{"id":"one","status":"unknown"}]}}""");
Check(ChatActivityData.Read(unknownAgentLifecycle, Json("""{"running":true}"""))!.RunningAgents is null, "known agent identities with unknown lifecycle do not imply zero running");
unknownAgentLifecycle["activity"]!["agents"]![0]!["status"] = "completed";
Check(ChatActivityData.Read(unknownAgentLifecycle, Json("""{"running":true}"""))!.RunningAgents == 0, "explicit terminal lifecycle can report a known zero running count");
foreach (var command in new[] { "/goal", "/plan", "/subagents" })
{
    Check(ChatCommandRules.Evaluate(command, "sh", true, false).Kind == ChatCommandRules.Kind.Inspect, "activity commands are local read-only views on every backend");
    Check(ChatCommandRules.Evaluate(command + " make one", "codex", false, false).Kind == ChatCommandRules.Kind.Arguments, "activity command arguments cannot create native goals or execute commands");
}
Console.WriteLine("Windows chat activity: reported-only metrics, old hosts, stale runs, unknown states and local read-only commands pass.");
var planOnly = ChatActivityData.Read(Json("""{"observedAtMs":1720000000000,"activity":{"planReported":true,"plan":[{"text":"Build","status":"completed"},{"text":"Review the patch","status":"inProgress"}]}}"""), null)!;
Check(planOnly.Headline == "Review the patch" && planOnly.ObservedAtMs == 1720000000000, "plan-only activity keeps its current step and report freshness");
Check(ChatActivityData.Read(Json("""{"observedAtMs":-1,"activity":{}}"""), null)!.ObservedAtMs is null
    && ChatActivityData.Read(Json("""{"observedAtMs":9223372036854775807,"activity":{}}"""), null)!.ObservedAtMs is null,
    "invalid report timestamps cannot crash local date formatting");
Check(ChatActivityData.Progress(20, 10) == 1 && ChatActivityData.Progress(0, 10) == 0
    && ChatActivityData.Progress(null, 10) is null && ChatActivityData.Progress(1, 0) is null
    && ChatActivityData.Progress(double.NaN, 10) is null, "budget progress is bounded and remains absent for unreported usage or invalid limits");
Check(ChatCommandRules.SendMethod(" /compact ") == "chat.compact" && ChatCommandRules.SendMethod("please /compact") == "chat.send", "older hosts must reject an unknown method instead of receiving a compaction prompt");
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
var stretches = FoldRows(turns, ChatDetail.Minimal);
Check(Ids(stretches) == "u1,g:k1,a0,g:t1,a1,changes:e1,u2,g:t2,a2", "Minimal keeps replies between work groups: " + Ids(stretches));
Check(GroupOf(stretches, "g:k1")!.Style == ChatStepGroupStyle.Thought, "reasoning alone is a thought line");
var work = GroupOf(stretches, "g:t1")!;
Check(work.Style == ChatStepGroupStyle.Work && string.Join(",", work.MemberIds) == "t1,e1", "only tool activity folds with the work");
Check(work.Steps == 2 && work.Cost == 0.25 && GroupOf(stretches, "g:t2")!.Cost is null, "steps and spend ride on the work line");
foreach (var running in new[] { false, true })
{
    var replies = FoldRows([Ask("u1"), Say("a0"), Tool("t1", "Read"), Say("a1"), Tool("t2", "Bash", running: true), Say("a2")], ChatDetail.Minimal, running: running);
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
Check(Ids(FoldRows(mustSee, ChatDetail.Minimal)) == "u1,g:t1,p1,g:t2,t3,e1,f1,x1", "an approval splits the work where it happened");
Check(Ids(FoldRows([Ask("u1"), Say("a1"), Row("x1", ChatPage.ItemKind.Usage, cost: 0.5)], ChatDetail.Minimal)) == "u1,a1,x1",
    "nothing to fold keeps the usage row");
Check(Ids(FoldRows([Ask("u1"), Tool("t1", "Read"), Say("a1"), Row("x1", ChatPage.ItemKind.Usage, cost: 0)], ChatDetail.Minimal)) == "u1,g:t1,a1,x1",
    "nothing spent keeps the token counts");

var live = FoldRows([Ask("u1"), Think("k1"), Tool("t1", "Read", running: true)], ChatDetail.Minimal, running: true);
var liveGroup = GroupOf(live, "g:k1")!;
Check(liveGroup.Running && liveGroup.LiveVerb == "Read" && liveGroup.LiveTarget == "t-t1", "a live work line names its step");
var settled = FoldRows([Ask("u1"), Think("k1"), Tool("t1", "Read"), Say("a1")], ChatDetail.Minimal, running: true);
Check(!GroupOf(settled, "g:k1")!.Running, "work before the answer is not running once its steps end");

var standard = FoldRows(
    [Ask("u1"), Think("k1"), Tool("t1", "Read"), Tool("t2", "Grep"), Tool("t3", "WebFetch"), Tool("t4", "Bash"), EditRow("e1", "a"), Say("a1")],
    ChatDetail.Standard);
Check(Ids(standard) == "u1,g:k1,g:t1,t4,e1,a1,changes:e1", "Standard folds thought and reads: " + Ids(standard));
var explored = GroupOf(standard, "g:t1")!;
Check(explored.Style == ChatStepGroupStyle.Explored && explored.Reads == 1 && explored.Searches == 1 && explored.Pages == 1,
    "explored counts by kind");
Check(GroupOf(standard, "g:k1")!.Preview == "Plan", "a thought previews its first line");
Check(Ids(FoldRows([Ask("u1"), Tool("t1", "Read"), Tool("t2", "Bash"), Tool("t3", "Read"), Tool("t4", "Glob"),
    Tool("t5", "Read", failed: true), Tool("t6", "Read")], ChatDetail.Standard)) == "u1,t1,t2,g:t3,t5,t6",
    "lone reads stay rows, other rows break runs");
Check(Ids(FoldRows([Ask("u1"), Think("k1")], ChatDetail.Standard, running: true)) == "u1,k1", "reasoning still arriving stays open");

var opened = FoldRows([Ask("u1"), Think("k1"), Tool("t1", "Bash"), Say("a1")], ChatDetail.Minimal, isOpen: id => id == "g:k1");
Check(Ids(opened) == "u1,g:k1,k1,t1,a1" && GroupOf(opened, "g:k1")!.Open, "an open group lists its steps after it");
Check(opened[2].GroupId == "g:k1" && opened[3].GroupId == "g:k1" && opened[0].GroupId == "" && opened[4].GroupId == "",
    "steps name their group, top-level rows none");
Check(ChatDetailFold.Owner("t1", opened) is null && ChatDetailFold.Owner("t1", FoldRows([Ask("u1"), Think("k1"), Tool("t1", "Bash"), Say("a1")], ChatDetail.Minimal)) == "g:k1",
    "a closed group owns its steps, an open one does not");

var growing = new List<ChatPage.DisplayItem> { Ask("u1"), Think("k1"), Tool("t1", "Bash", running: true) };
var before = Ids(FoldRows(growing, ChatDetail.Minimal, running: true));
growing.Add(Tool("t2", "Bash", running: true));
Check(before == Ids(FoldRows(growing, ChatDetail.Minimal, running: true)) && before == "u1,g:k1", "a growing turn keeps its line");

var counted = GroupOf(FoldRows([Ask("u1"), Tool("t1", "Bash", started: 1_000, ended: 4_000), EditRow("e1", "a.cs", 3, 1),
    EditRow("e2", "a.cs", 2), EditRow("e3", "b.cs", 1, 4), Tool("t2", "Bash", started: 5_000, ended: 9_000), Say("a1")], ChatDetail.Minimal), "g:t1")!;
Check(counted.Steps == 5 && counted.Files == 2 && counted.Added == 6 && counted.Removed == 5
    && counted.StartedAt == 1_000 && counted.EndedAt == 9_000, "counts match their members");
Check(ChatDetailFold.Preview("\n\n## **Plan** it\nmore") == "Plan** it" && ChatDetailFold.Preview("\n  \n") is null,
    "previews drop markdown marks");
var perStep = FoldRows([Ask("u1"), Think("k1"), Tool("t1", "Read"), Tool("t2", "Grep"), Tool("t3", "Bash"),
    EditRow("e1", "src/a.cs", 6, 2), Tool("t4", "Read"), Say("a1"), Tool("t5", "Bash", failed: true)], ChatDetail.Compact);
Check(Ids(perStep) == "u1,g:k1,g:t1,g:t3,g:e1,g:t4,a1,t5,changes:e1", "Compact is a line per step: " + Ids(perStep));
Check(new[] { "g:k1", "g:t1", "g:t3", "g:e1", "g:t4" }.All(id => GroupOf(perStep, id)!.Plain), "every Compact line is plain");
Check(GroupOf(perStep, "g:t3")! is { Style: ChatStepGroupStyle.Step, Verb: "Bash" }, "a command is its own line");
Check(GroupOf(perStep, "g:e1")! is { Style: ChatStepGroupStyle.Step, Verb: "Edit", Subject: "src/a.cs", Added: 6, Removed: 2 },
    "an edit names its file and lines");
Check(GroupOf(perStep, "g:t4")!.Style == ChatStepGroupStyle.Explored, "a lone read folds too");
Check(ChatDetailFold.ShortSubject("Edit", "src/a.cs") == "a.cs" && ChatDetailFold.ShortSubject("Bash", "cargo test\nmore") == "cargo test",
    "a path becomes its name and a command its first line");
var openStep = FoldRows([Ask("u1"), EditRow("e1", "a.cs", 1), Say("a1")], ChatDetail.Compact, isOpen: id => id == "g:e1");
Check(openStep.Single(row => row.GroupId == "g:e1").Plain == PlainStep.Detail, "a lone step shows what it produced, without a card");
var openRun = FoldRows([Ask("u1"), Tool("t1", "Read"), Tool("t2", "Grep"), Say("a1")], ChatDetail.Compact, isOpen: id => id == "g:t1");
Check(openRun.Where(row => row.GroupId == "g:t1").All(row => row.Plain == PlainStep.Line), "a run keeps a line per step");
Check(FoldRows([Ask("u1"), Tool("t1", "Read"), Say("a1")], ChatDetail.Minimal, isOpen: _ => true).All(row => row.Plain == PlainStep.None),
    "other levels keep their rows as they were");
Check(ChatDetailPreference.Renamed("minimal") == ChatDetail.Compact && ChatDetailPreference.Renamed("compact\n") == ChatDetail.Minimal
    && ChatDetailPreference.Renamed("detailed") == ChatDetail.Detailed && ChatDetailPreference.Renamed("x") is null,
    "a stored choice keeps what it did across the rename");

var changed = new List<ChatPage.DisplayItem>
{
    Ask("u1"), EditRow("e1", "/w/a.cs", 3, 1), EditRow("e2", "/w/a.cs", 2), EditRow("e3", "/w/b.cs", 1, 4),
    EditRow("ef", "/w/c.cs", failed: true), Say("a1"), Ask("u2"), EditRow("e4", "/w/c.cs", 1), Say("a2"),
};
var liveChanges = FoldRows(changed, ChatDetail.Minimal, running: true);
Check(string.Join(",", liveChanges.Where(row => row.Kind == ChatPage.ItemKind.Changes).Select(row => row.Id)) == "changes:e1",
    "the live turn has no card yet");
var firstTurn = liveChanges.First(row => row.Id == "changes:e1").Changes!;
var recorded1 = EditRow("recorded1", "same.cs", 1, 1); recorded1.Patch = "-old\n+one";
var recorded2 = EditRow("recorded2", "same.cs", 1, 1); recorded2.Patch = "-one\n+two";
var laterEdit = EditRow("later", "same.cs", 1, 1); laterEdit.Patch = "-two\n+later";
var recordedTurns = FoldRows([Ask("first"), recorded1, recorded2, Say("done"), Ask("second"), laterEdit, Say("done2")], ChatDetail.Minimal)
    .Where(row => row.Kind == ChatPage.ItemKind.Changes).Select(row => row.Changes!).ToArray();
Check(recordedTurns.Length == 2 && recordedTurns[0][0].Patches.SequenceEqual(new[] { "-old\n+one", "-one\n+two" })
    && recordedTurns[1][0].Patches.SequenceEqual(new[] { "-two\n+later" }), "recorded turn patches were replaced or reordered by later edits");
Check(firstTurn[0].Patches.SequenceEqual(new[] { "", "" }), "missing patches must remain explicitly unavailable");
Check(string.Join(",", firstTurn.Select(file => file.Path)) == "/w/a.cs,/w/b.cs" && firstTurn[0].Added == 5 && firstTurn[0].Removed == 1,
    "one row per file, summed, failures left out");
Check(FoldRows(changed, ChatDetail.Minimal).Last().Changes is { Count: 1 }, "a finished turn gets its card");
var steerNote = Ask("steered"); steerNote.IsSteer = true;
var steeredChanges = FoldRows([Ask("turn"), EditRow("before", "/w/a.cs", 2), steerNote, EditRow("after", "/w/a.cs", 3), Say("answer")], ChatDetail.Minimal);
Check(steeredChanges.Count(row => row.Kind == ChatPage.ItemKind.Changes) == 1
    && steeredChanges.Last().Changes![0].Added == 5, "steering preserves the current turn and its aggregate changes");
Console.WriteLine("Windows chat detail: minimal, compact, standard and detailed folding, turn changes, pinned rows, open groups and counts pass.");

var loadedWork = new List<ChatPage.DisplayItem> { Ask("long-turn") };
loadedWork.AddRange(Enumerable.Range(0, 300).Select(index => Tool($"step-{index}", "Read")));
loadedWork.Add(Say("long-reply"));
foreach (var level in new[] { ChatDetail.Minimal, ChatDetail.Standard })
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
var questionRow = FoldRows([Ask("u1"), new ChatPage.DisplayItem { Id = "question-q1", Kind = ChatPage.ItemKind.Question, Question = askedQuestion }], ChatDetail.Minimal);
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

var longDiff = new string('x', 4_900_000) + "👩🏽‍💻e\u0301界";
var pieces = DiffTextChunks.Split(longDiff).ToArray();
Check(pieces.All(piece => piece.Length <= DiffTextChunks.MaxUnits), "a minified diff must bound every layout item");
Check(string.Concat(pieces) == longDiff, "chunking must preserve the full UTF-16 source");
Check(DiffTextChunks.Count(longDiff) == pieces.Length, "navigation counts must match chunks");
var pairAtBoundary = new string('x', 255) + "😀tail";
var pairPieces = DiffTextChunks.Split(pairAtBoundary).ToArray();
Check(pairPieces[0].Length == 255 && pairPieces[1].StartsWith("😀"), "a page may not split a surrogate pair");
Check(DiffTextChunks.Split("").Count() == 1 && DiffTextChunks.Count("") == 1, "empty source lines keep one row");
var abandonedQuestion = "```tokenstat-question\n" + new string('x', 64 * 1024 + 1);
Check(ChatQuestionText.Strip(abandonedQuestion) == abandonedQuestion, "an oversized open fence stays readable");
Check(ChatQuestionText.Strip(abandonedQuestion + "\n```tokenstat-question\n{\"question\":\"Later\"}\n```") == abandonedQuestion,
    "an abandoned block cannot hide a later question");
Console.WriteLine("Windows diff text: multi-megabyte layout bounds, lossless source and Unicode boundaries pass.");

var fastModels = Json("""["opus","claude-opus-5-5","claude-opus-5","claude-opus-4-8"]""") as JsonArray;
Check(!ChatFastMode.Available("opus", null), "older hosts must not offer a speed control");
Check(ChatFastMode.Available(null, new JsonArray()), "Codex Default leaves availability to the provider");
var grokSpeedModels = Json("""["grok-4.7", ""]""") as JsonArray;
Check(ChatFastMode.Available(null, grokSpeedModels, "grok"), "Grok Default supports fast mode only when its model has a listed pair");
Check(ChatFastMode.Available("grok-4.7", grokSpeedModels, "grok"), "the listed Grok base model supports fast mode");
foreach (var model in new[] { "grok-4.6", "-20261006", "grok-4.7-20261006", "grok-4.7[1m]" })
    Check(!ChatFastMode.Available(model, grokSpeedModels, "grok"), "Grok requires an exact listed pair without Claude suffix normalization");
Check(!ChatFastMode.Available(null, new JsonArray(), "grok"), "Grok must not assume provider-controlled Default support");
Check(!ChatFastMode.Available(null, new JsonArray("grok-4.7"), "grok"), "Grok Default is not assumed to match an explicit model");
Check(ChatFastMode.Available("grok-4.7-20261006", new JsonArray("grok-4.7-20261006"), "grok"), "an explicitly advertised dated Grok model remains supported");
foreach (var model in new[] { "opus", "opus[1m]", "claude-opus-5-5", "claude-opus-5-5[1m]", "claude-opus-4-8-20260525", "claude-opus-4-8-20260525[1m]" })
    Check(ChatFastMode.Available(model, fastModels), "supported Opus aliases and snapshots must retain fast mode");
foreach (var model in new string?[] { null, "sonnet", "haiku", "claude-opus-4-7", "claude-opus-5-9", "claude-opus-5-9[1m]", "claude-opus-4-7-20260416[1m]", "opus[bogus]" })
    Check(!ChatFastMode.Available(model, fastModels), "unsupported models must not enable paid fast mode");
Console.WriteLine("Windows chat fast mode: old-host compatibility, Default, aliases, snapshots and unsupported models pass.");

var museCases = new (string Verb, string Detail, string ExpectedVerb, string ExpectedTarget)[]
{
    ("Bash", "{\"command\":\"cargo test\",\"description\":\"Run tests\",\"output\":\"ok\"}", "Bash", "cargo test"),
    ("Bash Input", "Run tests\n$ cargo test\nok", "Bash", "cargo test"),
    ("Read", "Read text file `/tmp/a file.txt`.\n1|contents", "Read", "/tmp/a file.txt"),
    ("Write", "wrote 23 bytes to /tmp/a file.txt", "Write", "/tmp/a file.txt"),
    ("Read Skill", "<read-skill-result name=\"bundled:git\" status=\"ok\">\nbody", "Read", "bundled:git"),
    ("Read", "<read-skill-result name=\"bundled:git\" status=\"ok\">\nbody", "Read", "bundled:git"),
    ("WebSearch", "{\"query\":\"Muse release notes\",\"results\":[]}", "WebSearch", "Muse release notes"),
    ("Write Todos", "{\"ok\":true,\"revision\":2,\"items\":4}", "TodoWrite", "4 todos (revision 2)"),
    ("TodoWrite", "4 todos (revision 2)", "TodoWrite", "4 todos (revision 2)"),
};
foreach (var sample in museCases)
{
    var result = MuseToolPresentation.Refine("muse", sample.Verb, "", sample.Detail);
    Check(result == (sample.ExpectedVerb, sample.ExpectedTarget), "Muse compact subject comes from logged metadata: " + sample.Verb);
    Check(MuseToolPresentation.Refine("muse", sample.Verb, "explicit", sample.Detail).Target == "explicit", "Muse preserves explicit targets");
    Check(MuseToolPresentation.Refine("codex", sample.Verb, "", sample.Detail) == (sample.Verb, ""), "Muse metadata never relabels another provider");
    var museRow = Tool("muse-tool", result.Verb);
    museRow.Target = result.Target;
    var folded = FoldRows([museRow], ChatDetail.Compact);
    Check(GroupOf(folded, "g:muse-tool")?.Subject == result.Target, "Muse recovered subject reaches the compact row");
}
foreach (var sample in new[] { ("Grep", "/tmp/a.txt:1:match"), ("WebFetch", "[link](https://example.test)"), ("Bash", "output\nmore\n$ not a command header"), ("Read", "{broken") })
    Check(MuseToolPresentation.Refine("muse", sample.Item1, "", sample.Item2).Target == "", "output cannot invent a Muse tool subject");
Check(MuseToolPresentation.Refine("muse", "Bash", "", new string('x', 5 * 1024 * 1024)).Target == "", "Muse parsing is bounded");
Console.WriteLine("Windows Muse tools: recorded commands, file paths, skill names, queries and todo counts reach compact rows.");

var fallbackRoute = (JsonObject)Json("""{"backend":"claude","model":"fallback"}""");
var savedPreferred = (JsonObject)Json("""{"backend":"codex","model":"preferred","effort":"high"}""");
var routingChoices = ChatRoutingChoices.Preferred([fallbackRoute], savedPreferred);
Check(routingChoices.Count == 3 && ReferenceEquals(routingChoices[1], savedPreferred),
    "Opening routing settings must preserve a preferred destination outside the fallback list");
var matchingPreferred = (JsonObject)fallbackRoute.DeepClone();
routingChoices = ChatRoutingChoices.Preferred([fallbackRoute], matchingPreferred);
Check(routingChoices.Count == 2 && ReferenceEquals(routingChoices[1], fallbackRoute),
    "A matching preferred choice must follow model and effort edits to its fallback");
fallbackRoute["model"] = "changed";
Check(routingChoices[1]!["model"]!.GetValue<string>() == "changed" && matchingPreferred["model"]!.GetValue<string>() == "fallback",
    "Draft edits must follow the selected route without mutating the saved policy");
Check(ChatRoutingChoices.Preferred([], savedPreferred).Count == 2,
    "A preferred destination remains selectable without fallbacks");
Check(ChatRoutingChoices.Moment(long.MaxValue) == DateTimeOffset.MaxValue.AddTicks(-9999)
    && ChatRoutingChoices.Moment(long.MinValue) == DateTimeOffset.MinValue
    && ChatRoutingChoices.Moment(0) == DateTimeOffset.UnixEpoch,
    "Malformed provider reset timestamps must not crash the chat inspector");
Console.WriteLine("Windows routing: independent preferred destinations, linked draft edits and bounded timestamps pass.");
