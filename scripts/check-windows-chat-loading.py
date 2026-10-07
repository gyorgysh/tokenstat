#!/usr/bin/env python3
"""Compile actual Windows catalog methods with a controlled, UI-free host."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'apps/windows/Pages/ChatPage.cs').read_text()
def method(signature):
    start = source.index(signature)
    brace = source.index('{', start)
    end, depth = brace + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]
methods = '\n'.join(method(s) for s in ['    private async Task RefreshCatalogAsync(',
    '    private async Task RefreshBackendCatalogAsync(', '    private async Task RefreshPersonaCatalogAsync('])
code = '''using System.Text.Json.Nodes;
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
''' + methods + '''
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
    }
}
'''
with tempfile.TemporaryDirectory(prefix='tokenstat-windows-chat-') as directory:
    folder = Path(directory)
    (folder / 'Program.cs').write_text(code)
    (folder / 'checks.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net8.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable></PropertyGroup></Project>')
    subprocess.run(['dotnet', 'run', '--project', str(folder / 'checks.csproj'), '-c', 'Release'], check=True)
