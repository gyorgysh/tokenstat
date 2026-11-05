#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Run the production Windows uploader with isolated files and held transport replies."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'apps/windows/Pages/ChatPage.Files.cs').read_text()
def method(signature):
    start = source.index(signature)
    end, depth = source.index('{', start) + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]
upload = method('    private async Task<JsonNode> UploadFileAsync(').replace('private async Task', 'public async Task', 1)
upload = upload.replace('Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "tokenstat", "file-transfers"', 'TestFiles.Root, "file-transfers"')
prune = method('    private static void PruneUploadReceipts(')
code = r'''
using System.Security.Cryptography;
using System.Text.Json.Nodes;
using System.Text;
namespace Windows.Storage {
    class StorageFile(string path) {
        public string Name => Path.GetFileName(path);
        public Task<Stream> OpenStreamForReadAsync() => Task.FromResult<Stream>(File.OpenRead(path));
    }
}
static class TestFiles { public static string Root = ""; }
static class AppServices { public static int AccountGeneration = 1; public static FakeHost Host = new(); }
class FakeHost {
    public Task<JsonNode> CallAsync(string method, JsonObject args) => Task.FromResult<JsonNode>(new JsonObject { ["host"] = "host", ["accountId"] = "account", ["handle"] = "handle" });
}
static class L10n { public static string Text(string key) => key; }
static class Format {
    public static string Text(JsonNode? node, string key) => node?[key]?.ToString() ?? "";
    public static long Long(JsonNode? node, string key) => long.TryParse(Text(node, key), out var n) ? n : 0;
    public static bool Flag(JsonNode? node, string key) => Text(node, key).Equals("true", StringComparison.OrdinalIgnoreCase);
}
static class RemoteFeatureGate { public static int? ProtocolOf(JsonNode node) => (int)Format.Long(node, "protocolVersion"); }
class HostException(string code) : Exception(code) { public string Code = code; }
class Upload {
    const int FileChunkBytes = 512 * 1024, AttachmentCap = 12 * 1024 * 1024;
    const long FileMaximumBytes = 256L * 1024 * 1024;
    static readonly System.Collections.Concurrent.ConcurrentDictionary<string, byte> FileClaims = new();
    string _workspaceId = "workspace";
    CancellationTokenSource? _fileTransfer;
    public bool Current = true, Relay, Answer, Fallback, Completed, FailFinish = true;
    public string? CancelAt;
    public bool RetireAtRefusal, CancelAtRefusal, CancelOnConfirm;
    public long Offset = 1000, Limit = FileMaximumBytes;
    public int Protocol = 34, Prompts, Starts, Finishes, Capabilities, Chunks, Cancels;
    JsonNode Attachment = new JsonObject();
    public string Journal => Directory.GetFiles(Path.Combine(TestFiles.Root, "file-transfers"), "*.json").Single();
    void RebuildComposerActions() {}
    void FileProgress(string value) { if (CancelAt == "progress") _fileTransfer!.Cancel(); }
    void ClearFileProgress() {}
    Task<bool> ConfirmFileRelayAsync(string name, long size, long? remaining = null) { Prompts++; if (CancelOnConfirm) _fileTransfer?.Cancel(); return Task.FromResult(Answer); }
    Task<JsonNode> CallChatAsync(string method, JsonObject args) {
        if (CancelAt == method) _fileTransfer?.Cancel();
        JsonNode response;
        switch (method) {
            case "protocol": response = new JsonObject { ["protocolVersion"] = Protocol }; break;
            case "chat.fileCapabilities": Capabilities++; response = new JsonObject { ["relay"] = Relay, ["maxFileBytes"] = Limit }; break;
            case "chat.fileUploadStart":
                Starts++; Attachment = new JsonObject { ["id"] = "file-" + Starts, ["name"] = Format.Text(args, "name"), ["size"] = 1000 };
                response = new JsonObject { ["transferId"] = "upload", ["offset"] = Offset }; break;
            case "chat.fileUploadStatus":
                response = new JsonObject { ["transferId"] = "upload", ["offset"] = Offset, ["finished"] = Completed, ["attachment"] = Completed ? Attachment.DeepClone() : null }; break;
            case "chat.fileUploadChunk":
            case "chat.attach":
                if ((Relay || Fallback) && !Format.Flag(args, "allowRelay")) {
                    if (RetireAtRefusal) Current = false;
                    if (CancelAtRefusal) _fileTransfer?.Cancel();
                    throw new HostException("relay_consent_required");
                }
                var bytes = Convert.FromBase64String(Format.Text(args, "data"));
                if (bytes.Length == 0 || bytes.Any(b => b != 42)) throw new Exception("Changed file bytes");
                Chunks++; Offset += bytes.Length;
                response = method == "chat.attach" ? new JsonObject { ["id"] = "legacy", ["name"] = Format.Text(args, "name") } : new JsonObject { ["offset"] = Offset }; break;
            case "chat.fileUploadFinish":
                Finishes++; if (FailFinish) throw new HostException("offline");
                Completed = true; response = Attachment.DeepClone(); break;
            case "chat.fileUploadCancel": Cancels++; response = new JsonObject(); break;
            default: throw new Exception("Unexpected request " + method);
        }
        return Task.FromResult(response);
    }
''' + upload + prune + r'''
    public static void Prune(string directory, string active) {
        FileClaims.TryAdd(active, 0);
        try { PruneUploadReceipts(directory); } finally { FileClaims.TryRemove(active, out _); }
    }
}
class Checks {
    static void Check(bool condition, string reason) { if (!condition) throw new Exception(reason); }
    static async Task Scenario(string name, Func<Windows.Storage.StorageFile, Task> test) {
        TestFiles.Root = Path.Combine(Path.GetTempPath(), "tokenstat-upload-check-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(TestFiles.Root);
        var path = Path.Combine(TestFiles.Root, "file.zip"); File.WriteAllBytes(path, Enumerable.Repeat((byte)42, 1000).ToArray());
        try { await test(new(path)); Console.WriteLine(name + " passed"); } finally { Directory.Delete(TestFiles.Root, true); }
    }
    static Task<JsonNode> Send(Upload u, Windows.Storage.StorageFile f) => u.UploadFileAsync("chat", f, () => u.Current);
    static async Task<Upload> Seed(Windows.Storage.StorageFile f) {
        var u = new Upload();
        try { await Send(u, f); throw new Exception("Expected a saved receipt"); } catch (HostException e) when (e.Code == "offline") {}
        u.FailFinish = false; u.Relay = true; u.Limit = 500; return u;
    }
    static async Task Main() {
        foreach (var completed in new[] { true, false }) await Scenario("completed bytes, finished=" + completed, async f => {
            var u = await Seed(f); u.Completed = completed;
            await Send(u, f); await Send(u, f);
            Check(u.Prompts == 0 && u.Starts == 1 && u.Capabilities == 1 && u.Chunks == 0, "Completed retry must skip consent, route limits, discovery and retransmission");
        });
        await Scenario("declined partial receipt", async f => {
            var u = await Seed(f); u.Offset = 500; u.Limit = 2000;
            var journal = u.Journal; var saved = File.ReadAllText(journal);
            try { await Send(u, f); throw new Exception("Declined transfer continued"); } catch (OperationCanceledException) {}
            Check(File.ReadAllText(journal) == saved && u.Starts == 1 && u.Cancels == 0 && u.Chunks == 0, "Declining must preserve partial receipt");
            u.Answer = true; await Send(u, f);
            Check(u.Starts == 1 && u.Chunks == 1, "Partial retry did not resume");
        });
        foreach (var step in new[] { "chat.fileUploadStatus", "chat.fileCapabilities" }) await Scenario("cancel " + step, async f => {
            var u = await Seed(f); u.Offset = 500; u.Limit = 2000; u.CancelAt = step; u.Answer = true;
            var journal = u.Journal;
            try { await Send(u, f); throw new Exception("Cancelled transfer continued"); } catch (OperationCanceledException) {}
            Check(u.Prompts == 0 && u.Starts == 1 && u.Cancels == 0 && File.Exists(journal), "Cancelled preflight must preserve receipt and avoid consent");
        });
        await Scenario("direct-to-relay fallback", async f => {
            var u = new Upload { Offset = 0, FailFinish = false, Fallback = true, Answer = true };
            await Send(u, f); await Send(u, f);
            Check(u.Prompts == 1 && u.Starts == 1 && u.Chunks == 1, "Fallback or completed retry repeated transfer/consent");
        });
        foreach (var protocol in new[] { 33, 34 }) await Scenario("navigation during relay fallback, protocol=" + protocol, async f => {
            var u = new Upload { Protocol = protocol, Offset = 0, FailFinish = false, Fallback = true, Answer = true, RetireAtRefusal = true };
            try { await Send(u, f); throw new Exception("Retired upload continued"); } catch (OperationCanceledException) {}
            Check(u.Prompts == 0 && u.Chunks == 0, "A retired upload displayed relay consent");
        });
        await Scenario("cancel during relay fallback", async f => {
            var u = new Upload { Offset = 0, FailFinish = false, Fallback = true, Answer = true, CancelAtRefusal = true };
            try { await Send(u, f); throw new Exception("Cancelled fallback continued"); } catch (OperationCanceledException) {}
            Check(u.Prompts == 0 && u.Chunks == 0 && u.Cancels == 1, "A cancelled fallback displayed consent or lost cleanup");
        });
        await Scenario("cancel while confirming fallback", async f => {
            var u = new Upload { Offset = 0, FailFinish = false, Fallback = true, Answer = true, CancelOnConfirm = true };
            try { await Send(u, f); throw new Exception("Cancelled confirmation continued"); } catch (OperationCanceledException) {}
            Check(u.Prompts == 1 && u.Chunks == 0 && u.Cancels == 1, "Cancelled confirmation sent file bytes");
        });
        await Scenario("active cancellation", async f => {
            var u = new Upload { Offset = 0, FailFinish = false, CancelAt = "progress" };
            try { await Send(u, f); throw new Exception("Cancelled upload continued"); } catch (OperationCanceledException) {}
            Check(u.Cancels == 1 && u.Finishes == 0 && Directory.GetFiles(Path.Combine(TestFiles.Root, "file-transfers"), "*.json").Length == 0, "Active cancellation must retire upload and receipt");
        });
        await Scenario("bounded receipt storage", f => {
            var dir = Path.Combine(TestFiles.Root, "file-transfers"); Directory.CreateDirectory(dir);
            string PathFor(int n, string suffix = ".json") => Path.Combine(dir, n.ToString("X64") + suffix);
            for (var i = 0; i < 140; i++) File.WriteAllText(PathFor(i), "{}");
            var expired = PathFor(1000); File.WriteAllText(expired, "{}"); File.SetLastWriteTimeUtc(expired, DateTime.UtcNow.AddDays(-2));
            var huge = PathFor(1001); File.WriteAllBytes(huge, new byte[8192]);
            var temporary = PathFor(1002, ".json.tmp"); File.WriteAllText(temporary, "{}"); File.SetLastWriteTimeUtc(temporary, DateTime.UtcNow.AddDays(-2));
            var active = PathFor(1003); File.WriteAllBytes(active, new byte[8192]); File.SetLastWriteTimeUtc(active, DateTime.UtcNow.AddDays(-2));
            var foreign = Path.Combine(dir, "other.json"); File.WriteAllText(foreign, "keep");
            var outside = Path.Combine(TestFiles.Root, "outside"); File.WriteAllText(outside, "unchanged");
            var link = PathFor(1004); var hasLink = false;
            try { File.CreateSymbolicLink(link, outside); hasLink = true; }
            catch (UnauthorizedAccessException) { Console.WriteLine("Symlink check unavailable without permission on this machine"); }
            Upload.Prune(dir, 1003.ToString("X64"));
            Check(!File.Exists(expired) && !File.Exists(huge) && !File.Exists(temporary), "Expired/oversized receipts or abandoned atomic files remain");
            Check(File.Exists(active) && File.ReadAllText(foreign) == "keep" && File.ReadAllText(outside) == "unchanged" && (!hasLink || new FileInfo(link).LinkTarget != null), "Pruning touched active or unrelated files");
            var kept = Directory.GetFiles(dir).Count(p => Path.GetFileName(p).Length == 69 && p != active && p != link);
            Check(kept == 128, "Inactive receipt count is not bounded");
            return Task.CompletedTask;
        });
        await Scenario("old host upload", async f => {
            var u = new Upload { Protocol = 33, Relay = true, Answer = true };
            await Send(u, f);
            Check(u.Prompts == 1 && u.Chunks == 1 && u.Capabilities == 0, "Legacy bytes and relay consent changed");
        });
    }
}
'''
with tempfile.TemporaryDirectory(prefix='tokenstat-windows-upload-') as directory:
    work = Path(directory)
    (work / 'Program.cs').write_text(code)
    (work / 'checks.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net8.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable></PropertyGroup></Project>')
    subprocess.run(['dotnet', 'run', '--project', str(work / 'checks.csproj'), '-c', 'Release'], check=True)
