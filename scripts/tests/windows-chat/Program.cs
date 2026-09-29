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
