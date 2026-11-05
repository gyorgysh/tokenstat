#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise approval callbacks and held replies using the production Windows methods."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
source = (root / 'apps/windows/Pages/ChatPage.cs').read_text()
def method(signature):
    start = source.index(signature); end = source.index('{', start) + 1; depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}'); end += 1
    return source[start:end]
methods = method('    private async Task ResolveAsync(')
methods += method('    private Func<string, Task> ApprovalReply(') if '    private Func<string, Task> ApprovalReply(' in source else '\nprivate Func<string, Task> ApprovalReply(string id) => choice => ResolveAsync(id, choice);'
if '    private bool ApplyApprovalSnapshot(' in source:
    methods += method('    private bool ApplyApprovalSnapshot(')
else:
    methods += '\nprivate bool ApplyApprovalSnapshot(JsonArray rows, long version) { _approvals = rows; return true; }'
code = r'''
using System.Text.Json.Nodes;
static class AppServices { public static long AccountGeneration = 1; }
static class Format { public static string Text(JsonNode? row, string key) => row?[key]?.ToString() ?? ""; }
class Check {
    string? _openId = "a";
    int _openGeneration = 1;
    long _approvalVersion;
    readonly HashSet<string> _resolvingApprovals = new();
    bool _opening = false, SharedSource = false, IsLoaded = true;
    JsonArray _approvals = Rows("one", "two");
    List<string> Errors = new();
    int Paints;
    record Request(string Method, JsonNode Args, TaskCompletionSource<JsonNode> Reply);
    List<Request> Requests = new();
    static JsonArray Rows(params string[] ids) => new(ids.Select(id => (JsonNode)new JsonObject { ["id"] = id, ["conversationId"] = "a" }).ToArray());
    bool OpenChatIs(string id) => IsLoaded && _openId == id;
    void RebuildTranscript() { Paints++; }
    void Banner(string text) { Errors.Add(text); }
    static JsonArray AsArray(JsonNode value) => value as JsonArray ?? new();
    Task<JsonNode> CallChatAsync(string method, JsonNode args) {
        var reply = new TaskCompletionSource<JsonNode>();
        Requests.Add(new(method, args.DeepClone(), reply)); return reply.Task;
    }
    async Task Pending(int count) {
        for (var i = 0; i < 1000; i++) { if (Requests.Count >= count) return; await Task.Delay(1); }
        throw new Exception("Request did not start: " + count);
    }
    void Answer(int index, JsonNode? value = null, bool fail = false) {
        if (fail) Requests[index].Reply.SetException(new IOException("fixture failure"));
        else Requests[index].Reply.SetResult(value ?? new JsonObject());
    }
    void Move(string id = "b") { _openGeneration++; _openId = id; _approvals = Rows("other"); }
    static void Require(bool result, string reason) { if (!result) throw new Exception(reason); }
''' + methods + r'''
    static async Task Main() {
        foreach (var stage in new[] { 0, 1 }) foreach (var change in new[] { "navigate", "reopen", "account", "unload" }) foreach (var failure in new[] { false, true }) {
            var c = new Check(); var resolve = c.ApprovalReply("one")("allow"); await c.Pending(1);
            if (stage == 1) { c.Answer(0); await c.Pending(2); }
            if (change == "navigate") c.Move();
            if (change == "reopen") c.Move("a");
            if (change == "account") { AppServices.AccountGeneration++; c._approvals = Rows("other"); }
            if (change == "unload") { c.IsLoaded = false; c._approvals = Rows("other"); }
            var paints = c.Paints;
            c.Answer(stage, Rows("stale"), failure);
            var finished = await Task.WhenAny(resolve, Task.Delay(100));
            Require(finished == resolve, "A retired approval started another request"); await resolve;
            Require(c.Requests.Count == stage + 1 && c.Errors.Count == 0 && c.Paints == paints && Format.Text(c._approvals[0], "id") == "other", "Retired approval reply changed the current view");
        }
        foreach (var stale in new[] { "generation", "account", "shared", "opening", "missing", "answered", "foreign" }) {
            var c = new Check(); var reply = c.ApprovalReply("one");
            if (stale == "generation") c._openGeneration++;
            if (stale == "account") AppServices.AccountGeneration++;
            if (stale == "shared") c.SharedSource = true;
            if (stale == "opening") c._opening = true;
            if (stale == "missing") c._approvals = Rows();
            if (stale == "answered") c._approvals[0]!["decision"] = "allow";
            if (stale == "foreign") c._approvals[0]!["conversationId"] = "other";
            await reply("allow"); Require(c.Requests.Count == 0, "Stale/read-only callback sent an approval: " + stale);
        }
        {
            var c = new Check(); c._approvals[0]!.AsObject().Remove("conversationId");
            var reply = c.ApprovalReply("one"); var first = reply("allow"); await c.Pending(1);
            Require(Format.Text(c.Requests[0].Args, "id") == "one" && Format.Text(c.Requests[0].Args, "choice") == "allow", "Approval request format changed");
            await reply("deny"); Require(c.Requests.Count == 1, "Duplicate click sent another decision");
            c.Answer(0); await c.Pending(2);
            Require(c._approvals.All(row => Format.Text(row, "id") != "one") && c.Paints == 1, "Answered prompt remained interactive while refresh waited");
            c.Answer(1, Rows("two")); await first;
            await reply("allow"); Require(c.Requests.Count == 2, "An answered control sent another decision");
        }
        {
            var c = new Check(); var oldPollVersion = c._approvalVersion;
            var a = c.ApprovalReply("one")("allow"); var b = c.ApprovalReply("two")("deny"); await c.Pending(2);
            c.Answer(0); await c.Pending(3); c.Answer(1); await c.Pending(4);
            c.Answer(3, Rows("new")); await b; c.Answer(2, Rows("two")); await a;
            Require(Format.Text(c._approvals[0], "id") == "new", "Older resolution refresh replaced newer approvals");
            c.ApplyApprovalSnapshot(Rows("one", "two"), oldPollVersion);
            Require(Format.Text(c._approvals[0], "id") == "new", "An old poll restored answered approvals");
        }
        foreach (var failure in new[] { false, true }) {
            var c = new Check(); var resolving = c.ApprovalReply("one")("allow"); await c.Pending(1);
            c.Answer(0); await c.Pending(2);
            var newerPoll = ++c._approvalVersion;
            c.ApplyApprovalSnapshot(Rows("new-prompt"), newerPoll);
            c.Answer(1, Rows("two"), failure); await resolving;
            Require(Format.Text(c._approvals[0], "id") == "new-prompt" && c.Errors.Count == 0, "An older refresh replaced newer state or displayed a stale failure");
        }
        {
            var c = new Check(); var reply = c.ApprovalReply("one"); var failed = reply("allow"); await c.Pending(1); c.Answer(0, fail:true); await failed;
            Require(c.Errors.Count == 1 && c._approvals.Count == 2, "Current failure was hidden or removed a pending approval");
            var retry = reply("deny"); await c.Pending(2); c.Answer(1); await c.Pending(3); c.Answer(2, Rows("two")); await retry;
            Require(c._approvals.Count == 1, "A failed decision could not be retried");
        }
        Console.WriteLine("Windows approvals: navigation/account/unload fences, stale controls, duplicate clicks, immediate acknowledgement, overlapping refreshes, old polls and retry passed");
    }
}
'''
with tempfile.TemporaryDirectory(prefix='tokenstat-approval-check-') as directory:
    work = Path(directory); (work / 'Program.cs').write_text(code)
    (work / 'checks.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net8.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable></PropertyGroup></Project>')
    subprocess.run(['dotnet', 'run', '--project', str(work / 'checks.csproj'), '-c', 'Release'], check=True)
