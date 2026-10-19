#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Hold the real Windows history readers across review and account changes."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def method(path, marker):
    source = (ROOT / path).read_text()
    start = source.index(marker)
    end, depth = source.index('{', start) + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private static async Task', 'public static async Task')


code = r'''
using System.Text.Json.Nodes;
using Tokenstat.Pages;
namespace Tokenstat.Pages {
class UIElement { public WorkspaceTabsPage? Workbench; }
class FrameworkElement : UIElement { public bool IsLoaded = true; }
class WorkspaceTabsPage : FrameworkElement {
    private readonly OperationEpoch _reviewEpoch = new();
    public object? ActivePage = new();
    public static WorkspaceTabsPage? Find(UIElement owner) => owner.Workbench;
    public void Retire() => _reviewEpoch.Advance();
''' + method('apps/windows/Pages/WorkspaceTabsPage.Companion.cs', '    internal OperationEpoch.Operation BeginReviewRequest(') + r'''
}
static class AppServices { public static long AccountGeneration; public static Host Host = new(); }
class Host {
    public readonly List<TaskCompletionSource<JsonNode>> Requests = new();
    public Task<JsonNode> CallAsync(string method, JsonObject parameters) {
        var reply = new TaskCompletionSource<JsonNode>(); Requests.Add(reply); return reply.Task;
    }
}
static class RemoteWorkspaces {
    public static Task<JsonNode> CallWorkspaceAsync(string workspace, string method, JsonObject parameters)
        => AppServices.Host.CallAsync(method, parameters);
}
class ContentDialog { public object? Title; public object? Content; public object? CloseButtonText; }
static class Chrome {
    public static int Errors;
    public static object Banner(object text, object color, object symbol) => text;
    public static Task ShowDialog(UIElement owner, ContentDialog dialog) { Errors++; return Task.CompletedTask; }
}
static class WorkspaceGit { public static string ShortId(string id) => id; }
static class FriendlyError { public static string Display(string error) => error; }
static class Theme { public static object Danger = new(); }
static class Symbol { public static object Important = new(); }
static class L10n { public static string Text(string key) => key; }
static class WorkspaceDiff {
    public static readonly List<string> Shown = new();
    public static Task ShowCommitAsync(UIElement owner, JsonNode detail) {
        Shown.Add(detail["id"]!.GetValue<string>()); return Task.CompletedTask;
    }
''' + method('apps/windows/Pages/WorkspaceDiff.cs', '    internal static OperationEpoch.Operation BeginReviewRequest(') + r'''
}
static class LocalHistory {
''' + method('apps/windows/Pages/WorkspaceHistory.cs', '    private static async Task ShowDetailAsync(') + r'''
}
static class RemoteHistory {
''' + method('apps/windows/Pages/WorkspaceRemoteHistory.cs', '    private static async Task ShowDetailAsync(') + r'''
}
class Program {
    static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
    static async Task Main() {
        foreach (var read in new Func<UIElement, string, string, Task>[] { LocalHistory.ShowDetailAsync, RemoteHistory.ShowDetailAsync }) {
            AppServices.Host = new(); WorkspaceDiff.Shown.Clear(); Chrome.Errors = 0;
            var workbench = new WorkspaceTabsPage();
            var owner = new FrameworkElement { Workbench = workbench };
            async Task Complete(Action retire, bool failure = false) {
                var at = AppServices.Host.Requests.Count;
                var pending = read(owner, "workspace", "retired");
                retire();
                if (failure) AppServices.Host.Requests[at].SetException(new Exception("late failure"));
                else AppServices.Host.Requests[at].SetResult(new JsonObject { ["id"] = "retired" });
                await pending;
                Check(!WorkspaceDiff.Shown.Contains("retired") && Chrome.Errors == 0, "A retired reply reopened a review or error");
            }
            var first = read(owner, "workspace", "first");
            var second = read(owner, "workspace", "second");
            AppServices.Host.Requests[1].SetResult(new JsonObject { ["id"] = "second" }); await second;
            AppServices.Host.Requests[0].SetResult(new JsonObject { ["id"] = "first" }); await first;
            Check(WorkspaceDiff.Shown.SequenceEqual(new[] { "second" }), "An older commit replaced a newer review");
            await Complete(() => AppServices.AccountGeneration++);
            await Complete(() => AppServices.AccountGeneration++, failure: true);
            await Complete(workbench.Retire);
            await Complete(() => workbench.ActivePage = new());
            await Complete(() => owner.IsLoaded = false);
            owner.IsLoaded = true;
            await Complete(() => workbench.IsLoaded = false, failure: true);
            workbench.IsLoaded = true;
            var other = new WorkspaceTabsPage();
            var otherOwner = new FrameworkElement { Workbench = other };
            var at = AppServices.Host.Requests.Count;
            var a = read(owner, "workspace", "a"); var b = read(otherOwner, "workspace", "b");
            AppServices.Host.Requests[at].SetResult(new JsonObject { ["id"] = "a" });
            AppServices.Host.Requests[at + 1].SetResult(new JsonObject { ["id"] = "b" });
            await Task.WhenAll(a, b);
            Check(WorkspaceDiff.Shown.TakeLast(2).SequenceEqual(new[] { "a", "b" }), "Independent workbenches cancelled each other");
        }
        Console.WriteLine("PASS: actual local and remote commit readers reject stale selections, retired panes, account changes and late errors");
    }
}
}
'''

with tempfile.TemporaryDirectory(prefix='tokenstat-windows-review-') as temporary:
    folder = Path(temporary)
    (folder / 'Program.cs').write_text(code)
    (folder / 'OperationEpoch.cs').write_text((ROOT / 'apps/windows/Pages/OperationEpoch.cs').read_text())
    (folder / 'Check.csproj').write_text('''<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup>
<OutputType>Exe</OutputType><TargetFramework>net8.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings>
<Nullable>enable</Nullable><NoWarn>CS0649</NoWarn></PropertyGroup></Project>''')
    subprocess.run(['dotnet', 'run', '--project', str(folder / 'Check.csproj'), '-c', 'Release'], check=True)
