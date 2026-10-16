#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Run actual Windows row projection/busy methods without native controls.

Optional benchmarks consume private chat.eventPage JSON and measure managed
projection work only. No application, network, or host is started.
"""
from pathlib import Path
import argparse
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source-root', type=Path, default=root)
parser.add_argument('--benchmark', type=Path, nargs='*')
args = parser.parse_args()
source_root = args.source_root.resolve()
source = (source_root / 'apps/windows/Pages/ChatPage.cs').read_text()

def method(signature):
    start = source.index(signature)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

projection = method('    private List<DisplayItem> Coalesce(').replace(' Coalesce(', ' CoalesceCore(', 1)
busy = method('    private bool Busy(')
if '    private JsonArray? _busyEvents;' in source:
    busy = source[source.index('    private JsonArray? _busyEvents;'):source.index('    private static string Duration(')]
uses_rows = 'Busy(List<DisplayItem>?' in busy
draw_busy = 'var busy = Busy(raw);' if uses_rows else 'var busy = Busy(); busy |= Busy();'

code = r'''
using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Tokenstat.Pages;
static class L10n { public static string Text(string key, params string[] args) => key + string.Join(",", args); }
namespace Tokenstat.Pages {
internal sealed partial class ChatPage {
    JsonArray _events, _approvals = new();
    JsonNode _openChat = new JsonObject { ["backend"] = "claude" };
    bool _running;
    int _coalesces;
    ChatPage(JsonArray events) { _events = events; }
    List<DisplayItem> Coalesce(JsonArray events) { _coalesces++; return CoalesceCore(events); }
''' + projection + '\n' + busy + '\n' + method('    private static string Duration(') + r'''
    int Draw(ChatDetail detail) {
        var raw = Coalesce(_events);
''' + draw_busy + r'''
        return ChatImageGallery.Compose(ChatDetailFold.Fold(raw, detail, _running, _ => false)).Count + (busy ? 1 : 0);
    }
    static string Snapshot(List<DisplayItem> items) => JsonSerializer.Serialize(items, new JsonSerializerOptions { IncludeFields = true });
    static void Check(bool pass, string message) { if (!pass) throw new Exception(message); }
    public static void Checks() {
        foreach (var (value, expected) in new (JsonNode?, string)[] {
            (JsonValue.Create("text 😀"), "text 😀"), (JsonValue.Create(""), ""),
            (JsonValue.Create(42), "42"), (JsonValue.Create(true), "true"),
            (JsonNode.Parse("\"parsed text\""), "parsed text"), (JsonNode.Parse("[1,2]"), "[1,2]"), (null, "fallback") }) {
            var holder = new JsonObject { ["value"] = value };
            Check(Format.Text(holder, "value", "fallback") == expected, "Text fast path changed JSON compatibility");
        }
        Check(Format.Text(new JsonArray(), "missing", "fallback") == "fallback", "Non-object text fallback changed");
        var rows = new JsonArray();
        for (var index = 0; index < 1200; index++) rows.Add(new JsonObject { ["kind"] = "agent", ["atMs"] = index, ["event"] = new JsonObject { ["kind"] = "text", ["delta"] = index % 10 == 0 ? "😀é\n" : "chunk " } });
        rows.Add(JsonNode.Parse("""{"kind":"agent","atMs":2000,"event":{"kind":"toolStart","callId":"one","verb":"Read"}}"""));
        var page = new ChatPage(rows);
        Check(page.Busy(), "An unmatched tool start must remain busy");
        var first = page._coalesces; for (var index = 0; index < 200; index++) Check(page.Busy(), "Repeated checks lost a running tool");
        Check(page._coalesces == first, "Repeated composer busy checks rebuilt the whole transcript");
        rows.Add(JsonNode.Parse("""{"kind":"agent","atMs":2001,"event":{"kind":"toolEnd","callId":"one","ok":true}}"""));
        Check(!page.Busy(), "Appended tool completion did not invalidate busy state");
        page._running = true; Check(page.Busy(), "Host-running state must override idle archived tools");
        page._running = false; Check(!page.Busy(), "Returning to idle lost the completed tool state");
        page._events = (JsonArray)rows.DeepClone();
        var replacement = (JsonObject)page._events[^1]!["event"]!; replacement["kind"] = "thinking";
        Check(page.Busy(), "A same-size replacement page reused another page's busy state");
        first = page._coalesces; page._openChat["backend"] = "codex"; page.Busy();
        Check(page._coalesces > first, "Backend handoff did not invalidate tool scope fallback");
        var raw = page.Coalesce(page._events);
        Check(raw[0].Text == string.Concat(Enumerable.Range(0, 1200).Select(index => index % 10 == 0 ? "😀é\n" : "chunk ")).Trim(), "Projection changed streamed Unicode text or line endings");
        foreach (var detail in Enum.GetValues<ChatDetail>()) {
            var before = Snapshot(page.Coalesce(page._events)); page.Draw(detail);
            Check(Snapshot(page.Coalesce(page._events)) == before, "Folding mutated the source projection");
        }
        Console.WriteLine("PASS: actual projection preserves streamed text, busy ownership, tail/page/backend invalidation and every detail level");
    }
    public static void Benchmark(string[] paths) {
        foreach (var path in paths) {
            var rows = (JsonArray)JsonNode.Parse(File.ReadAllText(path))!["events"]!;
            foreach (var detail in Enum.GetValues<ChatDetail>()) {
                const int iterations = 120;
                for (var index = 0; index < 12; index++) new ChatPage(rows).Draw(detail);
                GC.Collect(); GC.WaitForPendingFinalizers(); GC.Collect();
                var allocated = GC.GetAllocatedBytesForCurrentThread(); var watch = Stopwatch.StartNew(); var drawn = 0;
                for (var index = 0; index < iterations; index++) drawn = new ChatPage(rows).Draw(detail);
                watch.Stop();
                var bytes = (GC.GetAllocatedBytesForCurrentThread() - allocated) / iterations;
                var projection = new ChatPage(rows).Coalesce(rows);
                var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Snapshot(ChatImageGallery.Compose(ChatDetailFold.Fold(projection, detail, false, _ => false))))));
                Console.WriteLine(JsonSerializer.Serialize(new { file = Path.GetFileName(Path.GetDirectoryName(path)), events = rows.Count, state = detail.ToString(), drawn, hash, microseconds = watch.Elapsed.TotalMicroseconds / iterations, bytes }));
            }
            var page = new ChatPage(rows); page.Busy();
            var before = GC.GetAllocatedBytesForCurrentThread(); var timer = Stopwatch.StartNew();
            for (var index = 0; index < 200; index++) page.Busy();
            timer.Stop();
            Console.WriteLine(JsonSerializer.Serialize(new { file = Path.GetFileName(Path.GetDirectoryName(path)), state = "Busy repeated", microseconds = timer.Elapsed.TotalMicroseconds / 200, bytes = (GC.GetAllocatedBytesForCurrentThread() - before) / 200 }));
        }
    }
}
}
class Entry { static void Main(string[] args) { if (args.Length == 0) ChatPage.Checks(); else ChatPage.Benchmark(args); } }
'''

with tempfile.TemporaryDirectory(prefix='tokenstat-windows-projection-') as temp:
    folder = Path(temp)
    (folder / 'Program.cs').write_text(code)
    for name in ['Format', 'ChatPage.Items', 'ChatToolCalls', 'ChatQuestion', 'ChatDetailFold', 'MuseToolPresentation', 'ChatImageGallery']:
        (folder / (name + '.cs')).write_text((source_root / f'apps/windows/Pages/{name}.cs').read_text())
    (folder / 'Projection.csproj').write_text('''<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net8.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable><NoWarn>CS0649</NoWarn></PropertyGroup></Project>''')
    subprocess.run(['dotnet', 'build', str(folder / 'Projection.csproj'), '-c', 'Release', '--nologo', '-v:q'], check=True)
    # Compile the measured methods at their optimized tier before warm-up;
    # baseline and candidate use the same runtime policy in separate processes.
    subprocess.run(['dotnet', str(folder / 'bin/Release/net8.0/Projection.dll'), *[str(path.resolve()) for path in args.benchmark or []]], check=True,
                   env=os.environ | {'DOTNET_TieredCompilation': '0'})
