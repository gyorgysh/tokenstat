#!/usr/bin/env python3
"""Exercise actual Windows catalog, modal ownership and drop-import methods."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'apps/windows/Pages/ChatPage.cs').read_text()
def method(signature, content=source):
    start = content.index(signature)
    brace = content.index('{', start)
    end, depth = brace + 1, 1
    while depth:
        depth += (content[end] == '{') - (content[end] == '}')
        end += 1
    return content[start:end]
methods = '\n'.join(method(s) for s in ['    private async Task RefreshCatalogAsync(',
    '    private async Task RefreshBackendCatalogAsync(', '    private async Task RefreshPersonaCatalogAsync('])
activity = method('    private async Task ShowActivityAsync(',
    (root / 'apps/windows/Pages/ChatPage.Activity.cs').read_text())
commands = method('    private async Task<bool> ConsumeCommandAsync(',
    (root / 'apps/windows/Pages/ChatPage.Stats.cs').read_text())
drop = method('    private async Task StageDroppedFilesAsync(',
    (root / 'apps/windows/Pages/ChatPage.Drop.cs').read_text())
cancel_drop = method('    private void CancelDropImport(',
    (root / 'apps/windows/Pages/ChatPage.Drop.cs').read_text())
retain = method('    internal NewChatFile? RetainIfOwned(',
    (root / 'apps/windows/Pages/NewChatFile.cs').read_text())
code = '''using System.Text.Json.Nodes;
using Tokenstat.Pages;
class Checks {
    int _openGeneration = 1;
    string _workspaceId = "p";
    JsonArray _chats = new(), _backends = new(), _personas = new();
    Overlay _steerOverlay = new();
    List<string> errors = new();
    Dictionary<string, List<TaskCompletionSource<JsonNode>>> pending = new();
    Task<JsonNode> CallChatAsync(string method, JsonNode? args = null) {
        if (!pending.ContainsKey(method)) pending[method] = new();
        var reply = new TaskCompletionSource<JsonNode>(); pending[method].Add(reply);
        return reply.Task;
    }
    static JsonArray AsArray(JsonNode node, string? key = null) =>
        (key == null ? node : node[key]) as JsonArray ?? new();
    void CheckSelectedSignIn() {}
    void RefreshCatalogPresentation() {}
    void Banner(string text) { errors.Add(text); }
    class Overlay {
        public int BeginRead() => 1;
        public JsonArray Apply(JsonArray loaded, int request, JsonArray held) => loaded;
    }
    string? _openId = "chat";
    string _activityOwner = "owner";
    bool IsLoaded = true, _commandDialogOpening;
    bool _commandInFlight;
    int _commandIndex = 0;
    JsonNode _openChat = new JsonObject { ["backend"] = "codex" };
    Draft _draft = new();
    List<object> _attachments = new();
    CancellationTokenSource? _dropImport;
    bool _queueing;
    TaskCompletionSource _stopReply = new(TaskCreationOptions.RunContinuationsAsynchronously);
    bool Busy() => false;
    Task StopAsync() => _stopReply.Task;
    class Draft { public string Text = ""; public int SelectionStart; }
    record StagedFile(string Id, string Name, NewChatFile LocalFile);
    class NewChatFile {
        public const int MaximumCount = 20;
        public string Name = "dropped.png";
        public bool Discarded;
        public static Queue<TaskCompletionSource<NewChatFile>> Captures = new();
        public static Task<NewChatFile> CaptureAsync(string path, CancellationToken token) {
            var reply = new TaskCompletionSource<NewChatFile>(TaskCreationOptions.RunContinuationsAsynchronously);
            Captures.Enqueue(reply); return reply.Task.WaitAsync(token);
        }
        void Discard() => Discarded = true;
''' + retain + '''
    }
    void RememberDraft() {}
    void RebuildAttachStrip() {}
    void RebuildComposerActions() {}
    static class AppServices { public static int AccountGeneration = 1; }
    static class Format { public static string Text(JsonNode? node, string key) => node?[key]?.ToString() ?? ""; }
    object XamlRoot = new();
    object? _imageDialog;
    ContentDialog? _commandDialog;
    StackPanel? _commandDialogBody;
    string? _commandDialogOwner, _commandActivitySection;
    Dictionary<string, bool> _statsExpanded = new();
    TaskCompletionSource _inspectionReply = new(TaskCreationOptions.RunContinuationsAsynchronously);
    int _inspectionCalls;
    string? InspectionOwner() => _activityOwner;
    async Task RefreshInspectionAsync(bool force) { _inspectionCalls++; await _inspectionReply.Task; }
    void RenderCommandStats() {}
    static string ActivityText(string text) => text;
    static class Theme { public const double SpaceS = 8, SpaceM = 16; }
    static class L10n { public static string Text(string text) => text; }
    class StackPanel { public double Spacing { get; set; } }
    class ScrollViewer { public object? Content { get; set; } public double MaxHeight { get; set; } }
    class ContentDialog {
        public object? XamlRoot { get; set; }
        public object? Content { get; set; }
        public string? Title { get; set; }
        public string? CloseButtonText { get; set; }
        public TaskCompletionSource Completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public Task ShowAsync() => Completion.Task;
    }
''' + methods + '\n' + activity + '\n' + commands + '\n' + drop + '\n' + cancel_drop + '''
    static async Task Main() {
        var c = new Checks();
        var opening = c.RefreshCatalogAsync();
        c.pending["chat.list"][0].SetResult(new JsonArray("history"));
        await opening;
        if (c._chats.Count != 1) throw new Exception("Held menus hid chat history");
        c.pending["chat.backends"][0].SetException(new Exception("offline"));
        c.pending["chat.personas"][0].SetException(new Exception("offline"));
        if (c._chats.Count != 1 || c.errors.Count != 2) throw new Exception("Menu failures hid history");
        var old = c.RefreshCatalogAsync();
        c.pending["chat.list"][1].SetResult(new JsonArray("a")); await old;
        c._openGeneration++;
        var next = c.RefreshCatalogAsync();
        c.pending["chat.list"][2].SetResult(new JsonArray("b")); await next;
        c.pending["chat.backends"][1].SetResult(new JsonArray("old"));
        c.pending["chat.personas"][1].SetResult(new JsonObject { ["personas"] = new JsonArray("old") });
        if (c._backends.Count != 0 || c._personas.Count != 0) throw new Exception("Obsolete menus published");
        c.pending["chat.backends"][2].SetResult(new JsonArray("new"));
        c.pending["chat.personas"][2].SetResult(new JsonObject { ["personas"] = new JsonArray("new") });
        if (c._chats[0]!.GetValue<string>() != "b" || c._personas[0]!.GetValue<string>() != "new") throw new Exception("Current catalog lost");
        Console.WriteLine("Windows actual catalog: held/failed auxiliary reads cannot hide history; retired menus rejected");
        var activity = new Checks();
        var activityOpening = activity.ShowActivityAsync("all");
        await activity.ShowActivityAsync("goal");
        if (!activity._commandDialogOpening || activity._inspectionCalls != 1) throw new Exception("Two Activity taps raced inspection into duplicate dialogs");
        activity._inspectionReply.SetResult();
        for (var i = 0; i < 10000 && activity._commandDialog is null; i++) await Task.Yield();
        if (activity._commandDialog is not { } dialog) throw new Exception("Current activity dialog did not open");
        await activity.ShowActivityAsync("plan");
        if (activity._inspectionCalls != 1) throw new Exception("An open Activity dialog started another inspection");
        dialog.Completion.SetResult(); await activityOpening;
        if (activity._commandDialogOpening || activity._commandDialog is not null || activity._commandDialogBody is not null) throw new Exception("Closed Activity dialog retained its claim");
        var stale = new Checks();
        var retired = stale.ShowActivityAsync("all"); stale._activityOwner = "different-chat";
        stale._inspectionReply.SetResult(); await retired;
        if (stale._commandDialog is not null || stale._commandDialogOpening) throw new Exception("Late Activity opened for another chat");
        var failed = new Checks();
        var failedRead = failed.ShowActivityAsync("all"); failed._inspectionReply.SetException(new IOException("offline"));
        try { await failedRead; throw new Exception("Expected failed inspection"); } catch (IOException) {}
        if (failed._commandDialogOpening) throw new Exception("A failed inspection locked later Activity taps");
        var viewingImage = new Checks { _imageDialog = new object() };
        await viewingImage.ShowActivityAsync("all");
        if (viewingImage._inspectionCalls != 0 || viewingImage._commandDialogOpening) throw new Exception("Activity collided with the image viewer");
        var stopping = new Checks(); stopping._draft.Text = "/stop";
        var stop = stopping.ConsumeCommandAsync();
        var pendingActivity = stopping.ShowActivityAsync("all");
        if (!stopping._commandDialogOpening) throw new Exception("Activity did not acquire its dialog claim during Stop");
        stopping._stopReply.SetResult(); await stop;
        if (!stopping._commandDialogOpening) throw new Exception("Stop completion released Activity's pending dialog claim");
        await stopping.ShowActivityAsync("plan");
        if (stopping._inspectionCalls != 1) throw new Exception("Stop completion allowed overlapping Activity dialogs");
        stopping._inspectionReply.SetResult();
        for (var i = 0; i < 10000 && stopping._commandDialog is null; i++) await Task.Yield();
        if (stopping._commandDialog is not { } stoppedDialog) throw new Exception("Pending Activity did not complete after Stop");
        stoppedDialog.Completion.SetResult(); await pendingActivity;
        Console.WriteLine("Windows actual Activity dialog: concurrent taps, open viewer, stale owners and failed inspections release a single modal claim");
        var importing = new Checks(); var ownsDrop = true;
        var import = importing.StageDroppedFilesAsync(["selected.png"], () => ownsDrop, CancellationToken.None);
        var importedFile = new NewChatFile();
        ownsDrop = false; NewChatFile.Captures.Dequeue().SetResult(importedFile); await import;
        if (importing._attachments.Count != 0 || !importedFile.Discarded) throw new Exception("A late file drop entered a different chat or retained its private copy");
        ownsDrop = true;
        import = importing.StageDroppedFilesAsync(["selected.png"], () => ownsDrop, CancellationToken.None);
        var acceptedFile = new NewChatFile(); NewChatFile.Captures.Dequeue().SetResult(acceptedFile); await import;
        if (importing._attachments.Single() is not StagedFile accepted || accepted.LocalFile != acceptedFile || acceptedFile.Discarded) throw new Exception("A current file drop did not retain its owned snapshot");
        using var cancelled = new CancellationTokenSource();
        import = importing.StageDroppedFilesAsync(["cancelled.png"], () => true, cancelled.Token);
        NewChatFile.Captures.Dequeue(); cancelled.Cancel();
        try { await import; throw new Exception("Expected cancelled file staging"); } catch (OperationCanceledException) {}
        if (importing._attachments.Count != 1) throw new Exception("Cancelled staging changed accepted attachments");
        while (importing._attachments.Count < 20) importing._attachments.Add(new object());
        await importing.StageDroppedFilesAsync(["overflow.png"], () => true, CancellationToken.None);
        if (NewChatFile.Captures.Count != 0 || importing._attachments.Count != 20) throw new Exception("A dropped batch exceeded the attachment limit");
        using var retiredImport = new CancellationTokenSource();
        importing._dropImport = retiredImport; importing._queueing = true; importing._draft.Text = "next chat draft";
        importing.CancelDropImport();
        if (!retiredImport.IsCancellationRequested || importing._dropImport is not null || importing._queueing || importing._draft.Text != "next chat draft")
            throw new Exception("Retiring a drop left the next chat busy or changed its draft");
        Console.WriteLine("Windows actual dropped files: retired owners discard copies, current owners retain them, cancellation and attachment limits preserve drafts");
    }
}
'''
with tempfile.TemporaryDirectory(prefix='tokenstat-windows-chat-') as directory:
    folder = Path(directory)
    (folder / 'Program.cs').write_text(code)
    (folder / 'ChatCommandRules.cs').write_text((root / 'apps/windows/Pages/ChatCommandRules.cs').read_text())
    (folder / 'checks.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net8.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable></PropertyGroup></Project>')
    subprocess.run(['dotnet', 'run', '--project', str(folder / 'checks.csproj'), '-c', 'Release'], check=True)
