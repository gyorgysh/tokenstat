#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise the production quota refresh method with held replies and owner changes."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parent.parent
source = (root / 'apps/windows/Pages/ChatPage.Usage.cs').read_text()
method = source[source.index('    private async Task RefreshChatLimitsAsync'):source.index('    private void AddChatUsage')]
code = r'''
using System.Text.Json.Nodes;
using Tokenstat.Pages;
static class Format { public static string Text(JsonNode? node, string key) => node?[key]?.GetValue<string>() ?? ""; }
class MainWindow { public bool IsForeground = true; }
static class App { public static object CurrentWindow = new MainWindow(); }
class Host {
    public int Calls;
    public readonly Queue<TaskCompletionSource<JsonNode>> Pending = new();
    public Task<JsonNode> CallAsync(string method, JsonObject args) {
        if (method != "usage.limits") throw new Exception("Usage dispatched a model prompt");
        Calls++;
        var reply = new TaskCompletionSource<JsonNode>(TaskCreationOptions.RunContinuationsAsynchronously);
        Pending.Enqueue(reply); return reply.Task;
    }
}
static class AppServices { public static Host Host = new(); }
class Check {
    bool _commandUsageOnly = true, _usageReadFailed, IsLoaded = true;
    object? _commandDialogBody = new(), _usageFlight;
    string? _commandDialogOwner = "account/chat/claude", owner = "account/chat/claude";
    long _inspectionVisibilityGeneration, _usageReadVisibility = -1;
    DateTimeOffset _usageAttempt;
    JsonObject? _usageLimits;
    JsonNode _openChat = JsonNode.Parse("""{"backend":"claude"}""")!;
    int renders;
    string? InspectionOwner() => owner;
    void RenderCommandStats() { renders++; }
METHOD
    static void Assert(bool value, string message) { if (!value) throw new Exception(message); }
    static JsonNode Reading() => JsonNode.Parse("""[{"source":"claude_code","windows":[{"label":"5-hour","percent":0}]}]""")!;
    static Check Fresh() { AppServices.Host = new(); App.CurrentWindow = new MainWindow(); return new(); }
    static async Task Complete(Check m, Task task, bool fail = false) {
        var pending = AppServices.Host.Pending.Dequeue();
        if (fail) pending.SetException(new Exception("unknown_method")); else pending.SetResult(Reading());
        await task.WaitAsync(TimeSpan.FromSeconds(2));
    }
    static async Task Main() {
        var m = Fresh(); var first = m.RefreshChatLimitsAsync();
        await m.RefreshChatLimitsAsync(force: true);
        Assert(AppServices.Host.Calls == 1 && m._usageLimits is null, "Pending quota requests coalesce");
        await Complete(m, first);
        Assert(m._usageLimits?["windows"]?[0]?["percent"]?.GetValue<int>() == 0 && !m._usageReadFailed, "A measured zero survives");
        await m.RefreshChatLimitsAsync();
        Assert(AppServices.Host.Calls == 1, "Routine reads are throttled");
        var retry = m.RefreshChatLimitsAsync(force: true); await Complete(m, retry, fail: true);
        Assert(m._usageLimits is not null && m._usageReadFailed && m._usageFlight is null, "A failed refresh keeps a stale reading and releases the flight");
        var recovery = m.RefreshChatLimitsAsync(force: true); await Complete(m, recovery);
        Assert(!m._usageReadFailed, "A successful explicit retry clears the stale flag");
        foreach (var change in new[] { "account", "backend", "dialog", "close", "unload", "background", "visibility" }) {
            m = Fresh(); var pending = m.RefreshChatLimitsAsync();
            switch (change) {
                case "account": m.owner = "other/chat/claude"; break;
                case "backend": m.owner = "account/chat/codex"; break;
                case "dialog": m._commandDialogBody = new(); break;
                case "close": m._commandUsageOnly = false; break;
                case "unload": m.IsLoaded = false; break;
                case "background": ((MainWindow)App.CurrentWindow).IsForeground = false; break;
                case "visibility": m._inspectionVisibilityGeneration++; break;
            }
            var before = m.renders;
            await Complete(m, pending);
            Assert(m._usageLimits is null && m.renders == before, "A retired reply changed the view: " + change);
        }
        m = Fresh(); ((MainWindow)App.CurrentWindow).IsForeground = false;
        await m.RefreshChatLimitsAsync(force: true);
        Assert(AppServices.Host.Calls == 0, "Background views do not read quota");
        m = Fresh(); var unsupported = m.RefreshChatLimitsAsync(); await Complete(m, unsupported, fail: true);
        await m.RefreshChatLimitsAsync();
        Assert(m._usageLimits is null && m._usageReadFailed && AppServices.Host.Calls == 1, "Unsupported hosts remain unavailable without a tight retry loop");
        Console.WriteLine("Windows usage refresh: coalescing, throttling, stale recovery, owner changes, retired replies and old-host failures pass.");
    }
}
'''.replace('METHOD', method)
command_source = (root / 'apps/windows/Pages/ChatPage.Stats.cs').read_text()
command = command_source[command_source.index('    private async Task<bool> ConsumeCommandAsync'):command_source.index('    private string? InspectionOwner')]
command_code = r'''
class Draft { public string Text = "/usage"; public int SelectionStart; }
class StackPanel { public double Spacing; }
class ScrollViewer { public object? Content; public double MaxHeight; }
class ContentDialog {
    public object? XamlRoot, Title, Content; public string? CloseButtonText;
    public readonly TaskCompletionSource<bool> Closed = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public static readonly List<ContentDialog> Shown = new();
    public Task ShowAsync() { Shown.Add(this); return Closed.Task; }
}
class DispatcherTimer {
    public TimeSpan Interval; public event EventHandler? Tick;
    public static int Active;
    public void Start() { Active++; }
    public void Stop() { if (Interval > TimeSpan.Zero && Active > 0) Active--; }
    public void Fire() => Tick?.Invoke(this, EventArgs.Empty);
}
static class Theme { public const double SpaceM = 10; }
static class L10n { public static string Text(string key) => key; }
class CommandCheck {
    Draft _draft = new();
    JsonNode _openChat = JsonNode.Parse("""{"backend":"claude"}""")!;
    List<int> _attachments = new();
    int _commandIndex = 0, _openGeneration = 0;
    bool _commandInFlight, _commandDialogOpening, IsLoaded = true, _commandUsageOnly;
    string _openId = "chat";
    object? _imageDialog = null, XamlRoot = null;
    ContentDialog? _commandDialog;
    StackPanel? _commandDialogBody;
    string? _commandDialogOwner;
    bool busy = true;
    int quotaReads, draws;
    TaskCompletionSource<bool> inspection = new(TaskCreationOptions.RunContinuationsAsynchronously);
    bool Busy() => busy;
    void Banner(string value) { throw new Exception(value); }
    Task StopAsync() => throw new Exception("Unexpected stop");
    Task ShowActivityAsync(string section) => throw new Exception("Unexpected activity");
    Task RefreshInspectionAsync(bool force) => inspection.Task;
    Task RefreshChatLimitsAsync() { quotaReads++; return Task.CompletedTask; }
    void ResetUsageRead() { }
    string InspectionOwner() => _openId;
    void RenderCommandStats() { draws++; }
COMMAND
    static void Assert(bool value, string message) { if (!value) throw new Exception(message); }
    public static async Task Run() {
        ContentDialog.Shown.Clear();
        var usage = new CommandCheck(); var command = usage.ConsumeCommandAsync();
        Assert(ContentDialog.Shown.Count == 1 && usage._commandUsageOnly && usage.quotaReads == 1 && !usage.inspection.Task.IsCompleted,
            "/usage must open locally while busy, without waiting for inspection");
        Assert((string?)ContentDialog.Shown[0].Title == "common.chat.usage.title" && DispatcherTimer.Active == 1, "Focused title and quota timer belong to usage");
        await usage.ConsumeCommandAsync();
        Assert(ContentDialog.Shown.Count == 1, "A second command cannot open an overlapping dialog");
        ContentDialog.Shown[0].Closed.SetResult(true); await command.WaitAsync(TimeSpan.FromSeconds(2));
        Assert(usage._draft.Text == "" && usage._commandDialogBody is null && !usage._commandUsageOnly && DispatcherTimer.Active == 0,
            "Closing usage clears command state and retires quota polling");
        usage.inspection.SetResult(true);
        ContentDialog.Shown.Clear();
        var status = new CommandCheck(); status._draft.Text = "/status"; var normal = status.ConsumeCommandAsync();
        Assert(ContentDialog.Shown.Count == 0 && status.quotaReads == 0, "Other commands keep their existing inspection flow");
        status.inspection.SetResult(true);
        async Task WaitForDialog() { while (ContentDialog.Shown.Count == 0) await Task.Yield(); }
        await WaitForDialog().WaitAsync(TimeSpan.FromSeconds(2));
        Assert(!status._commandUsageOnly && (string?)ContentDialog.Shown[0].Title == "common.chat.stats.overview", "Usage mode must not leak into status");
        status._draft.Text = "new draft";
        ContentDialog.Shown[0].Closed.SetResult(true); await normal.WaitAsync(TimeSpan.FromSeconds(2));
        Assert(status._draft.Text == "new draft", "An edited draft survives closing the panel");
        Console.WriteLine("Windows usage command: immediate local opening, busy chats, modal ownership, timer cleanup and other inspection commands pass.");
    }
}
'''.replace('COMMAND', command)
code = code.replace('static class AppServices {', 'static class AppServices { public static int AccountGeneration = 0;')
code = code.replace('        var m = Fresh(); var first', '        await CommandCheck.Run();\n        var m = Fresh(); var first')
code += command_code
folder = root / 'target/chat-performance/windows-usage-fixture'
folder.mkdir(parents=True, exist_ok=True)
(folder / 'Program.cs').write_text(code)
includes = ''.join(f'<Compile Include="{root / "apps/windows/Pages" / name}" />' for name in ['ChatQuotaData.cs', 'ChatHistoryBuffer.cs', 'ChatCommandRules.cs'])
project = folder / 'Usage.csproj'
project.write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net8.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable></PropertyGroup><ItemGroup>' + includes + '</ItemGroup></Project>')
subprocess.run(['dotnet', 'run', '--project', str(project), '-c', 'Release'], check=True)
