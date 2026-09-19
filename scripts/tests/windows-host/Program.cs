// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.IO.Pipes;
using System.Diagnostics;
using System.Text;
using System.Text.Json.Nodes;
using Tokenstat.Host;
using Tokenstat.Pages;

// Isolate from any actual helper, including on Windows.
Environment.SetEnvironmentVariable("USERNAME", "t-" + Guid.NewGuid().ToString("N")[..8]);
static void Check(bool pass, string message) { if (!pass) throw new Exception(message); }
foreach (var (folder, session) in new[] {
    ("folder-one", "pty-57"),
    ("remote:peer-a:folder-one", "remote:peer-a:pty-57"),
    ("remote:peer-b:folder:with:colons", "remote:peer-b:pty%3A57") })
{
    var tag = Tokenstat.Navigation.LiveRoute.Join("wsterm:", folder, session);
    Check(Tokenstat.Navigation.LiveRoute.TrySplit(tag, "wsterm:", out var actualFolder, out var actualSession)
        && actualFolder == folder && actualSession == session, "Sidebar selection lost the remote namespace");
}
Console.WriteLine("PASS: local and remote sidebar routes preserve both resource ids");
Check(ScreenViewport.Normalize(0, 50, 200, 200, 200, 100, false) == (0.0, 0.0), "Letterboxed image top-left must map to the remote top-left");
Check(ScreenViewport.Normalize(100, 100, 200, 200, 200, 100, false) == (0.5, 0.5), "Image center must stay centered");
Check(ScreenViewport.Normalize(100, 20, 200, 200, 200, 100, false) is null, "Letterbox clicks must not reach the host");
Check(ScreenViewport.Normalize(100, 20, 200, 200, 200, 100, true) == (0.5, 0.0), "Dragging outside the picture must clamp to its edge");
Check(ScreenViewport.Normalize(50, 0, 200, 200, 100, 200, false) == (0.0, 0.0), "Portrait image pillarbox must be excluded too");
Console.WriteLine("PASS: remote pointer follows the displayed image bounds");
// A TSCR sample from the shared wire, including a three-byte Annex-B NAL.
var encoded = new byte[40];
Encoding.ASCII.GetBytes("TSCR").CopyTo(encoded, 0);
encoded[4] = 1; encoded[5] = 1; encoded[6] = 1;
System.Buffers.Binary.BinaryPrimitives.WriteUInt64BigEndian(encoded.AsSpan(8), 57);
System.Buffers.Binary.BinaryPrimitives.WriteUInt64BigEndian(encoded.AsSpan(16), 1234567);
System.Buffers.Binary.BinaryPrimitives.WriteUInt16BigEndian(encoded.AsSpan(24), 1920);
System.Buffers.Binary.BinaryPrimitives.WriteUInt16BigEndian(encoded.AsSpan(26), 1080);
System.Buffers.Binary.BinaryPrimitives.WriteUInt32BigEndian(encoded.AsSpan(28), 8);
new byte[] { 0, 0, 1, 0x65, 1, 2, 3, 4 }.CopyTo(encoded, 32);
var frame = ScreenFrame.Parse(encoded);
Check(frame is { Keyframe: true, Sequence: 57, TimestampMicroseconds: 1234567, Width: 1920, Height: 1080 }
    && frame.Payload.SequenceEqual(encoded[32..]), "Screen envelope must preserve Annex-B bytes and timestamps");
Check(ScreenFrame.Parse(encoded[..^1]) is null, "Truncated video must be rejected");
System.Buffers.Binary.BinaryPrimitives.WriteUInt32BigEndian(encoded.AsSpan(28), uint.MaxValue);
Check(ScreenFrame.Parse(encoded) is null, "Oversized video length must be rejected without overflow");
Console.WriteLine("PASS: screen wire preserves codec input and rejects invalid lengths");
var outboxDirectory = Path.Combine(Path.GetTempPath(), "tokenstat-outbox-test-" + Guid.NewGuid().ToString("N"));
try
{
    var key = ChatOutbox.Key("account", "remote:peer:folder", "chat");
    Check(key != ChatOutbox.Key("other", "remote:peer:folder", "chat"), "Queues must be isolated by account");
    Check(key != ChatOutbox.Key("account", "remote:other:folder", "chat"), "Queues must be isolated by owning machine");
    var first = new QueuedChatMessage("first", "one", [], 4);
    var second = new QueuedChatMessage("second", "two", ["attachment"], 4);
    var outbox = new ChatOutbox(outboxDirectory);
    outbox.Update(key, rows => { rows.Add(first); rows.Add(second); });
    var reopened = new ChatOutbox(outboxDirectory);
    Check(reopened.Read(key).Select(item => item.Id).SequenceEqual(new[] { "first", "second" }), "Queue must survive reopening in order");
    outbox.Update(key, rows => rows[0] = first with { Text = "edited" });
    var staleRefused = false;
    try { outbox.Stage(key, first, 1234); } catch (InvalidOperationException) { staleRefused = true; }
    Check(staleRefused && reopened.Read(key)[0].AttemptedAt is null, "A stale draft snapshot must never be sent");
    outbox.Update(key, rows => rows[0] = first);
    var attempted = outbox.Stage(key, first, 1234);
    var duplicateRefused = false;
    try { reopened.Stage(key, first, 1235); } catch (InvalidOperationException) { duplicateRefused = true; }
    Check(duplicateRefused, "A second window must not send a claimed message");
    Check(reopened.Read(key)[0].AttemptedAt == 1234, "Uncertain delivery must survive restart");
    var remaining = reopened.Accept(key, attempted, 5);
    Check(remaining.Count == 1 && remaining[0].Revision == 5, "Accepted turn must advance only its waiting successors");
    outbox.Update(key, rows => rows.Add(new QueuedChatMessage("different", "new context", [], 9)));
    remaining = outbox.Accept(key, remaining[0], null);
    Check(remaining.Single().Revision == 9, "Receipt recovery must not authorize a different context");
    try { outbox.Update(key, rows => { rows.Clear(); throw new IOException("interrupted"); }); }
    catch (IOException) { }
    Check(reopened.Read(key).Count == 1, "A failed mutation must preserve the previous queue");
    try { outbox.Update(key, rows => { for (var i = 0; i < 21; i++) rows.Add(new QueuedChatMessage(i.ToString(), "x", [], 0)); }); }
    catch (IOException) { }
    Check(reopened.Read(key).Count == 1, "Capacity rejection must not replace pending messages");
    Console.WriteLine("PASS: durable chat queue isolates owners, preserves order and uncertain delivery, and advances accepted context only");
}
finally { Directory.Delete(outboxDirectory, recursive: true); }

static NamedPipeServerStream Server() => new(HostClient.PipeName, PipeDirection.InOut, 20,
    PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
static async Task Reply(NamedPipeServerStream pipe, string result)
{
    using var writer = new StreamWriter(pipe, new UTF8Encoding(false), leaveOpen: true) { AutoFlush = true };
    await writer.WriteLineAsync("{\"ok\":true,\"result\":" + result + "}");
}
static async Task<string?> Read(NamedPipeServerStream pipe)
{
    using var reader = new StreamReader(pipe, leaveOpen: true);
    return await reader.ReadLineAsync();
}

if (OperatingSystem.IsWindows())
{
    var originalData = Environment.GetEnvironmentVariable("TOKENSTAT_DATA_DIR");
    try
    {
        Environment.SetEnvironmentVariable("TOKENSTAT_DATA_DIR", null);
        var expected = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "tokenstat", "tokenstat", "data", "host-owner.lock");
        Check(HostOwnerLock.LockPath == expected, "Owner lock must use the Rust data directory, including its data suffix");
        Environment.SetEnvironmentVariable("TOKENSTAT_DATA_DIR", "relative-data");
        Check(HostOwnerLock.LockPath == expected, "Relative data overrides must be ignored");
    }
    finally { Environment.SetEnvironmentVariable("TOKENSTAT_DATA_DIR", originalData); }
    var lockPath = Path.Combine(Path.GetTempPath(), "tokenstat-owner-" + Guid.NewGuid() + ".lock");
    HostOwnerLock.AcquireAt(lockPath);
    GC.Collect();
    GC.WaitForPendingFinalizers();
    using (var probe = new FileStream(lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.ReadWrite | FileShare.Delete))
    {
        var held = false;
        try { probe.Lock(0, 1); probe.Unlock(0, 1); }
        catch (IOException) { held = true; }
        Check(held, "Owner lock was lost while the app is open");
        HostOwnerLock.Release();
        probe.Lock(0, 1);
        probe.Unlock(0, 1);
    }
    File.Delete(lockPath);
    Console.WriteLine("PASS: Windows owner lock survives GC and releases on quit");

    if (args is ["--hostd", var hostd])
    {
        var data = Path.Combine(Path.GetTempPath(), "tokenstat-lifetime-" + Guid.NewGuid());
        var identity = Path.Combine(data, "identity");
        Directory.CreateDirectory(identity);
        File.WriteAllText(Path.Combine(identity, "host.json"), "{\"alwaysOn\":false}");
        Process? daemon = null;
        try
        {
            Environment.SetEnvironmentVariable("TOKENSTAT_DATA_DIR", data);
            Check(HostOwnerLock.LockPath == Path.Combine(data, "host-owner.lock"), "Absolute data override was ignored");
            HostOwnerLock.Acquire();
            var start = new ProcessStartInfo(Path.GetFullPath(hostd))
            { UseShellExecute = false, CreateNoWindow = true };
            start.Environment["TOKENSTAT_IDENTITY_DIR"] = identity;
            start.Environment["LOCALAPPDATA"] = data;
            daemon = Process.Start(start)!;
            var probeClient = new HostClient();
            JsonNode? policy = null;
            var deadline = Stopwatch.StartNew();
            while (deadline.Elapsed < TimeSpan.FromSeconds(30))
            {
                Check(!daemon.HasExited, "Daemon exited during startup");
                try { policy = await probeClient.CallAsync("host.policy", patience: TimeSpan.FromSeconds(2)); break; }
                catch (HostException) { await Task.Delay(100); }
            }
            Check(policy is not null, "Daemon never answered host.policy");
            Check(!policy!["alwaysOn"]!.GetValue<bool>(), "Lifetime fixture must disable always-on");
            Check(policy["hostingActive"]!.GetValue<bool>(), "Rust daemon cannot see the C# app owner lock");
            await Task.Delay(TimeSpan.FromSeconds(8)); // Longer than the daemon's owner grace period.
            Check(!daemon.HasExited, "Daemon stopped while the app still held its owner lock");
            HostOwnerLock.Release();
            await daemon.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(15));
            Check(daemon.ExitCode == 0, "Daemon must stop cleanly after the last app closes");
            Console.WriteLine("PASS: real daemon stays alive with the app and stops after ownership is released");
        }
        finally
        {
            HostOwnerLock.Release();
            Environment.SetEnvironmentVariable("TOKENSTAT_DATA_DIR", originalData);
            if (daemon is not null)
            {
                if (!daemon.HasExited) { daemon.Kill(entireProcessTree: true); await daemon.WaitForExitAsync(); }
                daemon.Dispose();
            }
            Directory.Delete(data, recursive: true);
        }
    }
}
else Console.WriteLine("SKIP: native owner-lock test requires Windows");

var client = new HostClient();
using (var slowServer = Server())
{
    var slow = client.CallAsync("scan", patience: TimeSpan.FromSeconds(5));
    await slowServer.WaitForConnectionAsync();
    await Read(slowServer);
    using var fastServer = Server();
    var fast = client.CallAsync("account.status");
    await fastServer.WaitForConnectionAsync().WaitAsync(TimeSpan.FromSeconds(2));
    await Read(fastServer);
    await Reply(fastServer, "{\"signedIn\":true}");
    Check((await fast.WaitAsync(TimeSpan.FromSeconds(2)))["signedIn"]!.GetValue<bool>(), "Fast request blocked by scan");
    await Reply(slowServer, "{}");
    await slow;
}
using (var server = Server())
{
    var pending = client.CallAsync("slow", patience: TimeSpan.FromMilliseconds(100));
    await server.WaitForConnectionAsync();
    await Read(server);
    try { await pending; throw new Exception("Missing timeout"); }
    catch (HostException ex) { Check(ex.Code == "timeout", "Wrong timeout error"); }
}
using (var server = Server())
{
    var recovered = 0;
    var noReplay = new HostClient(() => recovered++);
    var pending = noReplay.CallAsync("workspace.add");
    await server.WaitForConnectionAsync();
    await Read(server);
    server.Dispose();
    try { await pending; throw new Exception("Missing disconnect error"); }
    catch (HostException ex) { Check(ex.Code is "eof" or "io", "Wrong disconnect error"); }
    Check(recovered == 0, "Interrupted mutation was replayed");
}
NamedPipeServerStream? restarted = null;
var recovery = new HostClient(() => restarted = Server());
var recoverCall = recovery.CallAsync("account.status");
while (restarted is null) await Task.Delay(20);
await restarted.WaitForConnectionAsync();
await Read(restarted);
await Reply(restarted, "{}");
await recoverCall;
restarted.Dispose();
Console.WriteLine("PASS: concurrent requests, timeout, no mutation replay, recovery before sending");

var local = new Dictionary<string, JsonObject>();
var remote = new JsonArray();
var pushed = new List<string>();
static JsonObject Record(string kind, string id, long stamp, string? parent = null) => new()
{ ["id"] = id, ["updatedMs"] = stamp, [kind == "folder" ? "parentId" : "folderId"] = parent };
static JsonObject Envelope(string kind, JsonObject row) => new()
{ ["id"] = kind + ":" + row["id"]!.GetValue<string>(), ["plaintext"] = new JsonObject { ["kind"] = kind, [kind] = row }.ToJsonString() };
remote.Add(Envelope("folder", Record("folder", "child", 1, "parent")));
remote.Add(Envelope("host", Record("host", "host1", 1, "child")));
remote.Add(Envelope("folder", Record("folder", "parent", 1)));
remote.Add(Envelope("host", Record("host", "newer", 1, "old-missing-parent")));
remote.Add(new JsonObject { ["id"] = "key:gone", ["deleted"] = true });
remote.Add(new JsonObject { ["id"] = "host:future", ["plaintext"] = "unknown-new-format" });
remote.Add(Envelope("key", new JsonObject { ["id"] = "synced", ["updatedMs"] = 1, ["privateKey"] = "test-private-key", ["publicKey"] = "test-public-key" }));
local["host:newer"] = Record("host", "newer", 20);
local["host:future"] = Record("host", "future", 1);
remote.Add(new JsonObject { ["id"] = "folder:doomed", ["deleted"] = true });
remote.Add(Envelope("host", Record("host", "orphan", 1, "doomed")));
local["folder:doomed"] = Record("folder", "doomed", 1);
local["host:orphan"] = Record("host", "orphan", 1, "doomed");
var mismatched = Envelope("host", Record("host", "wrong-id", 1));
mismatched["id"] = "host:expected-id";
remote.Add(mismatched);
local["key:gone"] = new JsonObject { ["id"] = "gone", ["secretRef"] = "wincred:gone" };
Tokenstat.AppServices.Host.Handler = (method, parameters) =>
{
    if (method == "ssh.vault.record.list") return new JsonObject { ["records"] = remote.DeepClone() };
    if (method == "ssh.vault.record.put") { pushed.Add(Format.Text(parameters, "id")); return new JsonObject(); }
    var kind = method.Split('.')[1];
    if (method.EndsWith(".list")) return new JsonArray(local.Where(p => p.Key.StartsWith(kind + ":")).Select(p => p.Value.DeepClone()).ToArray());
    var key = kind + ":" + Format.Text(parameters, "id");
    if (method.EndsWith(".delete"))
    {
        local.Remove(key);
        if (key == "folder:doomed")
        {
            local["host:orphan"]["folderId"] = null;
            local["host:orphan"]["updatedMs"] = 40;
        }
        return new JsonObject();
    }
    Check(parameters?["privateKey"] is null, "Private material leaked into record metadata");
    Check(Format.Flag(parameters, "keepUpdatedMs"), "Lost remote timestamp");
    var parent = Format.Text(parameters, kind == "folder" ? "parentId" : "folderId");
    Check(parent.Length == 0 || local.ContainsKey("folder:" + parent), "Child applied before parent");
    local[key] = (JsonObject)parameters!.DeepClone();
    return local[key].DeepClone();
};
await SshVaultSync.SyncAsync();
Check(local.ContainsKey("host:host1"), "Remote host missing");
Check(!local.ContainsKey("key:gone") && SshSecrets.Forgot.Contains("wincred:gone"), "Tombstone left a secret behind");
Check(pushed.ToHashSet().SetEquals(new[] { "host:newer", "host:orphan" }), "Overwrote unreadable record or lost newer local record: " + string.Join(",", pushed));
Check(SshSecrets.Get(Format.Text(local["key:synced"], "secretRef")) == "test-private-key", "Synced key not stored in credential vault");
Check(!local.ContainsKey("host:wrong-id"), "Applied mismatched vault identity");
Check(local["host:orphan"]["folderId"] is null, "Restored a deleted folder reference");
Console.WriteLine("PASS: vault folder ordering, timestamps, tombstones, unknown records, private-key separation");
var originalHandler = Tokenstat.AppServices.Host.Handler;
remote.Clear();
remote.Add(Envelope("key", new JsonObject { ["id"] = "synced", ["updatedMs"] = 50, ["privateKey"] = "replacement-key" }));
var originalSecret = Format.Text(local["key:synced"], "secretRef");
Tokenstat.AppServices.Host.Handler = (method, parameters) => method == "ssh.key.save"
    ? throw new InvalidOperationException("simulated metadata save failure") : originalHandler(method, parameters);
try { await SshVaultSync.SyncAsync(); throw new Exception("Missing metadata save error"); }
catch (InvalidOperationException) { }
Check(SshSecrets.Get(originalSecret) == "test-private-key", "Failed metadata save destroyed the original private key");
Console.WriteLine("PASS: rejected key update preserves the working credential");
var writes = 0;
Tokenstat.AppServices.Host.Handler = (method, parameters) => method switch
{
    "account.status" => new JsonObject { ["signedIn"] = true },
    "ssh.vault.status" => new JsonObject { ["created"] = true, ["locked"] = true },
    _ => new JsonObject { ["writes"] = ++writes },
};
try { await SshVaultSync.WriteAsync("ssh.host.save", new JsonObject()); throw new Exception("Edited locked vault"); }
catch (InvalidOperationException) { }
Check(writes == 0, "Mutated data while vault locked");
Tokenstat.AppServices.Host.Handler = (method, parameters) => method == "account.status"
    ? new JsonObject { ["signedIn"] = false } : new JsonObject { ["writes"] = ++writes };
await SshVaultSync.WriteAsync("ssh.host.save", new JsonObject());
Check(writes == 1, "Signed-out local SSH editing broken");
Console.WriteLine("PASS: locked-vault protection and signed-out local editing");

namespace Tokenstat
{
    internal static class AppServices { public static FakeHost Host { get; } = new(); }
    internal sealed class FakeHost
    {
        public Func<string, JsonNode?, JsonNode> Handler = (_, _) => new JsonObject();
        public Task<JsonNode> CallAsync(string method, JsonNode? parameters = null) => Task.FromResult(JsonNode.Parse(Handler(method, parameters).ToJsonString())!);
    }
}
namespace Tokenstat.Pages
{
    internal static class SshSecrets
    {
        public static readonly List<string> Forgot = new();
        private static readonly Dictionary<string, string> Secrets = new();
        public static bool Put(string id, string pem) { Secrets[id] = pem; return pem.Length > 0; }
        public static string? Get(string id) => Secrets.GetValueOrDefault(id);
        public static bool Has(string id) => Secrets.ContainsKey(id);
        public static void Forget(string id) { Forgot.Add(id); Secrets.Remove(id); }
    }
    internal static class CredentialVault { public static string RefFor(string id) => "wincred:" + id; }
}
