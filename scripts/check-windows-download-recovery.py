#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise the Windows file download method with an isolated fake transport."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'apps/windows/Pages/ChatPage.Files.cs').read_text()
start = source.index('    private async Task DownloadFileAsync(')
end, depth = source.index('{', start) + 1, 1
while depth:
    depth += (source[end] == '{') - (source[end] == '}')
    end += 1
method = source[start:end].replace('private async Task', 'public async Task', 1)
method = method.replace('Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "tokenstat", "file-downloads"', 'TestFiles.Root, "file-downloads"')
start = source.index('    private static Task<long> ReadFileHashAsync(')
end, depth = source.index('{', start) + 1, 1
while depth:
    depth += (source[end] == '{') - (source[end] == '}')
    end += 1
method += source[start:end]
code = r'''
using System.Security.Cryptography;
using System.Text.Json.Nodes;
using System.Text;
class DisplayItem { public string Id = "attachment-file"; public string Name = "preview.png"; public long Size = 30; }
static class TestFiles { public static string Root = ""; public static string Saved => Path.Combine(Root, "saved.png"); }
class FileSavePicker {
    public string SuggestedFileName = "";
    public Dictionary<string, List<string>> FileTypeChoices = new();
    public Task<Destination?> PickSaveFileAsync() => Task.FromResult<Destination?>(new());
}
class Destination { public Task<Stream> OpenStreamForWriteAsync() => Task.FromResult<Stream>(File.Open(TestFiles.Saved, FileMode.OpenOrCreate)); }
static class App { public static object? CurrentWindow => null; }
static class InitializeWithWindow { public static void Initialize(object picker, object handle) {} }
static class WindowNative { public static object GetWindowHandle(object window) => window; }
static class AppServices { public static int AccountGeneration = 1; public static FakeHost Host = new(); }
class FakeHost {
    public Task<JsonNode> CallAsync(string method, JsonObject args) => Task.FromResult<JsonNode>(new JsonObject { ["host"] = "host", ["accountId"] = "account", ["handle"] = "handle" });
}
static class L10n { public static string Text(string key) => key; }
static class Format {
    public static string Text(JsonNode? node, string key) => node?[key]?.ToString() ?? "";
    public static long Long(JsonNode? node, string key) => long.TryParse(Text(node, key), out var result) ? result : 0;
    public static bool Flag(JsonNode? node, string key) => Text(node, key).Equals("true", StringComparison.OrdinalIgnoreCase);
}
static class RemoteFeatureGate { public static int? ProtocolOf(JsonNode node) => (int)Format.Long(node, "protocolVersion"); }
class HostException(string code) : Exception(code) { public string Code = code; }
class Download {
    const int FileChunkBytes = 512 * 1024, AttachmentCap = 12 * 1024 * 1024;
    const long FileMaximumBytes = 256L * 1024 * 1024;
    string? _openId = "chat";
    string _workspaceId = "workspace";
    int _openGeneration = 1;
    CancellationTokenSource? _fileTransfer;
    public bool Relay = true, Answer = false, Fallback = false;
    public int Prompts, Chunks, Refusals;
    public List<string> Banners = new();
    public byte[] Bytes = Encoding.UTF8.GetBytes("verified resumed attachment bytes");
    public string Checksum => Convert.ToHexString(SHA256.HashData(Bytes)).ToLowerInvariant();
    public string Partial {
        get {
            var key = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes("host|account|handle|workspace|chat|file|" + Checksum)));
            return Path.Combine(TestFiles.Root, "file-downloads", key + ".part");
        }
    }
    public void Seed(byte[] bytes) { Directory.CreateDirectory(Path.GetDirectoryName(Partial)!); File.WriteAllBytes(Partial, bytes); }
    bool OpenChatIs(string chat) => _openId == chat;
    void RebuildComposerActions() {}
    void FileProgress(string value) {}
    void ClearFileProgress() {}
    void Banner(string value) => Banners.Add(value);
    Task<bool> ConfirmFileRelayAsync(string name, long size, long? remaining = null) { Prompts++; return Task.FromResult(Answer); }
    Task<JsonNode> CallChatAsync(string method, JsonObject args) {
        JsonNode response;
        switch (method) {
            case "protocol": response = new JsonObject { ["protocolVersion"] = 34 }; break;
            case "chat.fileCapabilities": response = new JsonObject { ["relay"] = Relay, ["maxFileBytes"] = FileMaximumBytes, ["relayRemainingBytes"] = 9999 }; break;
            case "chat.fileDownloadInfo": response = new JsonObject { ["sha256"] = Checksum, ["attachment"] = new JsonObject { ["size"] = Bytes.Length } }; break;
            case "chat.fileDownloadChunk":
                if ((Relay || Fallback) && !Format.Flag(args, "allowRelay")) { Refusals++; throw new HostException("relay_consent_required"); }
                Chunks++;
                var offset = (int)Format.Long(args, "offset");
                response = new JsonObject { ["offset"] = offset, ["nextOffset"] = Bytes.Length, ["data"] = Convert.ToBase64String(Bytes[offset..]) }; break;
            default: throw new Exception("Unexpected call " + method);
        }
        return Task.FromResult(response);
    }
''' + method + r'''
}
class Checks {
    static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
    static async Task Scenario(string name, Func<Task> test) {
        TestFiles.Root = Path.Combine(Path.GetTempPath(), "tokenstat-download-check-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(TestFiles.Root);
        try { await test(); Console.WriteLine(name + " passed"); } finally { Directory.Delete(TestFiles.Root, true); }
    }
    static async Task Main() {
        await Scenario("completed cached download", async () => {
            var download = new Download(); download.Seed(download.Bytes);
            await download.DownloadFileAsync(new());
            Check(download.Prompts == 0 && download.Chunks == 0, "Complete file requested relay consent or bytes");
            Check(File.ReadAllBytes(TestFiles.Saved).SequenceEqual(download.Bytes), "Completed cache did not save verified bytes");
        });
        await Scenario("partial relay download", async () => {
            var download = new Download { Answer = true }; download.Seed(download.Bytes[..5]);
            await download.DownloadFileAsync(new());
            Check(download.Prompts == 1 && download.Chunks == 1, "Partial relay did not ask exactly once");
            Check(File.ReadAllBytes(TestFiles.Saved).SequenceEqual(download.Bytes), "Partial resume changed bytes");
        });
        await Scenario("declined relay", async () => {
            var download = new Download(); download.Seed(download.Bytes[..5]);
            await download.DownloadFileAsync(new());
            Check(download.Prompts == 1 && download.Chunks == 0 && !File.Exists(TestFiles.Saved), "Declined relay downloaded or saved bytes");
        });
        await Scenario("corrupt completed cache", async () => {
            var download = new Download(); download.Seed(new byte[download.Bytes.Length]);
            await download.DownloadFileAsync(new());
            Check(download.Prompts == 0 && download.Chunks == 0 && !File.Exists(TestFiles.Saved) && !File.Exists(download.Partial), "Corrupt cache was reused or requested relay consent");
        });
        await Scenario("oversized partial", async () => {
            var download = new Download { Relay = false }; download.Seed(new byte[download.Bytes.Length + 1]);
            await download.DownloadFileAsync(new());
            Check(download.Chunks == 1 && File.ReadAllBytes(TestFiles.Saved).SequenceEqual(download.Bytes), "Oversized partial was not discarded before restarting");
        });
        await Scenario("direct-to-relay fallback", async () => {
            var download = new Download { Relay = false, Fallback = true, Answer = true };
            await download.DownloadFileAsync(new());
            Check(download.Refusals == 1 && download.Prompts == 1 && download.Chunks == 1, "Fallback did not preserve the consent gate");
            Check(File.ReadAllBytes(TestFiles.Saved).SequenceEqual(download.Bytes), "Fallback changed bytes");
        });
    }
}
'''
with tempfile.TemporaryDirectory(prefix='tokenstat-windows-download-') as directory:
    work = Path(directory)
    (work / 'Program.cs').write_text(code)
    (work / 'checks.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net8.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable></PropertyGroup></Project>')
    subprocess.run(['dotnet', 'run', '--project', str(work / 'checks.csproj'), '-c', 'Release'], check=True)
