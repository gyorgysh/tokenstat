// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Tokenstat;
using Tokenstat.Pages;

internal static class TerminalSessionTests
{
    internal static async Task RunAsync()
    {
        static void Check(bool value, string message) { if (!value) throw new Exception(message); }
        // A spawned session also lives in the ById cache. Replacing it must
        // stop the old sidebar ID from resolving to the new shell.
        var workspace = "respawn-cache-" + Guid.NewGuid();
        var spawned = TerminalSession.For(workspace, null);
        await spawned.AttachAsync(30, 100);
        var oldId = spawned.Id;
        await spawned.RespawnAsync(30, 100);
        Check(spawned.Id.Length > 0 && spawned.Id != oldId, "Respawn did not replace the host PTY");
        Check(ReferenceEquals(TerminalSession.For(workspace, spawned.Id), spawned), "The new PTY lost its existing session owner");
        var old = TerminalSession.For(workspace, oldId);
        Check(!ReferenceEquals(old, spawned) && old.Id == oldId, "The obsolete ById cache opened the respawned shell");
        await old.CloseAsync();
        await spawned.CloseAsync();

        // Named restored sessions have a workspace/id slot as well. Clearing
        // only ById leaves that second cache pointing at the respawned PTY.
        workspace = "restored-cache-" + Guid.NewGuid();
        oldId = "restored-" + Guid.NewGuid();
        var restored = TerminalSession.For(workspace, oldId);
        await restored.AttachAsync(30, 100);
        await restored.RespawnAsync(30, 100);
        old = TerminalSession.For(workspace, oldId);
        Check(!ReferenceEquals(old, restored) && old.Id == oldId, "The obsolete workspace slot opened the respawned shell");
        Check(ReferenceEquals(TerminalSession.For(workspace, restored.Id), restored), "The restored session lost its new ID registration");
        await old.CloseAsync();
        await restored.CloseAsync();
        Console.WriteLine("Terminal session: respawn retires both old cache keys and preserves its new owner");
    }
}

// The production session runs against a protocol fixture rather than a
// platform PTY. Its real cache, respawn, offset and poll code are compiled.
namespace Tokenstat
{
    internal static class AppServices
    {
        internal static readonly TerminalProtocolFixture Host = new();
    }
    internal sealed class TerminalProtocolFixture
    {
        internal Task<JsonNode> CallAsync(string method, JsonNode? parameters = null)
        {
            JsonNode result = method switch
            {
                "launcher.catalog" => new JsonArray(new JsonObject { ["id"] = "shell", ["command"] = "fixture-shell", ["args"] = new JsonArray() }),
                "pty.spawn" => new JsonObject { ["id"] = "fixture-" + Guid.NewGuid(), ["command"] = "fixture-shell", ["rows"] = 30, ["cols"] = 100 },
                "pty.info" => new JsonObject { ["alive"] = true, ["command"] = "fixture-shell", ["rows"] = 30, ["cols"] = 100 },
                "pty.resize" => new JsonObject { ["rows"] = parameters?["rows"]?.DeepClone(), ["cols"] = parameters?["cols"]?.DeepClone() },
                "pty.read" => new JsonObject { ["data"] = "", ["nextOffset"] = parameters?["offset"]?.DeepClone() ?? JsonValue.Create(0) },
                "pty.detach" or "pty.close" or "pty.write" or "pty.kill" => new JsonObject(),
                _ => throw new Exception("Unexpected terminal fixture method: " + method),
            };
            return Task.FromResult(result);
        }
    }
}
namespace Tokenstat.Design
{
    internal static class Theme { internal static bool IsDark => true; }
}
namespace Tokenstat.Navigation
{
    internal static class RemoteWorkspaces
    {
        internal static bool TrySplit(string id, out string peer, out string inner) { peer = ""; inner = id; return false; }
        internal static Task<JsonNode> CallOnPeerAsync(string peer, string method) => AppServices.Host.CallAsync(method);
        internal static Task<JsonNode> CallWorkspaceAsync(string id, string method, JsonNode? parameters) => AppServices.Host.CallAsync(method, parameters);
    }
}
