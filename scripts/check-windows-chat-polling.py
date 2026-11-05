#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Hold replies to the production Windows poll loop across history replacements."""
from pathlib import Path
import argparse
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--baseline', action='store_true')
parser.add_argument('--case', choices=['reset', 'replace', 'cancel', 'cancel-held', 'selection', 'reject', 'current'])
args = parser.parse_args()
path = 'apps/windows/Pages/ChatPage.cs'
source = (subprocess.check_output(['git', 'show', 'HEAD:' + path], cwd=root, text=True)
          if args.baseline else (root / path).read_text())
start = source.index('    private async Task PollLoop(')
end = source.index('{', start) + 1
nesting = 1
while nesting:
    nesting += (source[end] == '{') - (source[end] == '}')
    end += 1
# Only shorten the timer; requests, fences and publication use production code.
method = source[start:end].replace('await Task.Delay(catchUp ? 10 : Busy() ? 400 : 2000, token);', 'await Task.Delay(1, token);')
code = r'''
using System.Text.Json.Nodes;
using Tokenstat.Pages;
static class Format { public static bool Flag(JsonNode node, string key) => node[key]?.GetValue<bool>() == true; }
class Dispatcher {
    public bool HasThreadAccess = true, Accept = true;
    public TaskCompletionSource<Action> Queued = New<Action>();
    public bool TryEnqueue(Action action) { Queued.TrySetResult(action); return Accept; }
    public static TaskCompletionSource<T> New<T>() => new(TaskCreationOptions.RunContinuationsAsynchronously);
}
class Check {
    readonly ChatHistoryBuffer _history = new();
    string? _openId = "chat";
    int _historyGeneration => _history.Generation;
    ulong _offset => _history.Offset;
    string? _tailCursor => _history.TailCursor;
    JsonArray _approvals = new();
    int _approvalVersion, draws, drains, tails;
    readonly Dispatcher DispatcherQueue = new();
    readonly CancellationTokenSource cancellation = new();
    readonly TaskCompletionSource<bool> pageRequested = Dispatcher.New<bool>();
    readonly TaskCompletionSource<JsonNode> pageReply = Dispatcher.New<JsonNode>();
    readonly TaskCompletionSource<bool> nextPoll = Dispatcher.New<bool>();
    bool reset;
    static JsonNode Page(string? id) => JsonNode.Parse(id is null
        ? """{"events":[],"nextOffset":0}"""
        : $$"""{"events":[{"id":"{{id}}"}],"nextOffset":10}""")!;
    bool Busy() => false;
    Task RefreshInspectionAsync() => Task.CompletedTask;
    Task RefreshCatalogAsync(bool refreshMenus) => Task.CompletedTask;
    Task<bool> DrainQueueOnUiAsync(string chat) { drains++; return Task.FromResult(true); }
    void ApplyApprovalSnapshot(JsonArray rows, int version) { if (version == _approvalVersion) _approvals = rows; }
    void ApplyHistoryPage(JsonNode page, bool replace) => _history.ApplyPage(page, replace);
    void RebuildTranscript(bool full) { draws++; }
    void RefreshCost() {}
    void ApplyOpenChat(string chat, bool wasBusy, bool transcriptChanged) { draws++; }
    static JsonArray AsArray(JsonNode node, string? key = null) => (key is null ? node : node[key]) as JsonArray ?? new();
    async Task<JsonNode> CallChatAsync(string method, JsonObject? request = null) {
        if (method == "chat.eventPage") { pageRequested.TrySetResult(true); return await pageReply.Task; }
        if (method == "chat.approvals") return new JsonArray();
        if (++tails > 1) {
            nextPoll.TrySetResult(true);
            await Task.Delay(Timeout.Infinite, cancellation.Token);
        }
        return reset ? JsonNode.Parse("""{"reset":true,"events":[],"nextOffset":0}""")!
            : JsonNode.Parse("""{"events":[{"id":"tail"}],"nextOffset":20}""")!;
    }
METHOD
    static void Assert(bool value, string message) { if (!value) throw new Exception(message); }
    static async Task Wait(Task task) => await task.WaitAsync(TimeSpan.FromSeconds(5));
    static async Task ResetReply(bool replace, bool empty) {
        var m = new Check { reset = true }; m._history.ApplyPage(Page("original"), true);
        var poll = m.PollLoop(m.cancellation.Token);
        await Wait(m.pageRequested.Task);
        if (replace) m._history.ApplyPage(Page("newer window"), true);
        m.pageReply.SetResult(Page(empty ? null : "reset"));
        await Wait(m.nextPoll.Task); m.cancellation.Cancel(); await Wait(poll);
        Assert(!replace || m._history.Events.Count == 1 && m._history.Events[0]?["id"]?.GetValue<string>() == "newer window",
            "A delayed reset page overwrote the newer transcript");
        Assert(replace ? m.draws == 0 : m.draws == 1, "Only a current reset may redraw");
        if (!replace) Assert(empty ? m._history.Events.Count == 0 : m._history.Events[0]?["id"]?.GetValue<string>() == "reset",
            "A legitimate current reset was rejected");
    }
    static async Task DispatchReply(string change) {
        var m = new Check(); m._history.ApplyPage(Page("original"), true);
        m.DispatcherQueue.HasThreadAccess = false;
        m.DispatcherQueue.Accept = change != "reject";
        var poll = m.PollLoop(m.cancellation.Token);
        var action = await m.DispatcherQueue.Queued.Task.WaitAsync(TimeSpan.FromSeconds(5));
        if (change == "replace") m._history.ApplyPage(Page("newer window"), true);
        if (change is "cancel" or "cancel-held") m.cancellation.Cancel();
        if (change == "selection") m._openId = "another chat";
        if (change is not ("reject" or "cancel-held")) action();
        if (change is "replace" or "current") { await Wait(m.nextPoll.Task); m.cancellation.Cancel(); }
        await Wait(poll);
        Assert(m.draws == (change == "current" ? 1 : 0), "A retired dispatcher callback redrew the chat");
        Assert(m.drains == (change == "current" ? 1 : 0), "A retired dispatcher callback drained the queue");
        Assert(m._history.Events.Count == (change == "current" ? 2 : 1), "A retired callback appended its old tail");
    }
    public static async Task Main(string[] args) {
        if (args.Length > 0) {
            if (args[0] == "reset") await ResetReply(true, true); else await DispatchReply(args[0]);
            return;
        }
        await ResetReply(true, true); await ResetReply(true, false);
        await ResetReply(false, true); await ResetReply(false, false);
        foreach (var change in new[] { "replace", "cancel", "cancel-held", "selection", "reject", "current" }) await DispatchReply(change);
        Console.WriteLine("Windows production polling: delayed resets, dispatcher ownership, rejected dispatch and current replies passed");
    }
}
'''.replace('METHOD', method)
with tempfile.TemporaryDirectory(prefix='tokenstat-windows-polling-') as temp:
    folder = Path(temp)
    (folder / 'Program.cs').write_text(code)
    (folder / 'ChatHistoryBuffer.cs').write_text((root / 'apps/windows/Pages/ChatHistoryBuffer.cs').read_text())
    project = folder / 'Polling.csproj'
    project.write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net8.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable></PropertyGroup></Project>')
    subprocess.run(['dotnet', 'run', '--project', str(project), '-c', 'Release', '--', *([args.case] if args.case else [])], check=True)
