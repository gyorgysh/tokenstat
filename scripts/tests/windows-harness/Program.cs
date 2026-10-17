// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Tokenstat.Pages;

static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
static JsonNode Config(string model = "original", string effort = "low") => new JsonObject
{
    ["available"] = true, ["fields"] = new JsonArray(
        new JsonObject { ["key"] = "model", ["value"] = model },
        new JsonObject { ["key"] = "effort", ["value"] = effort })
};
static async Task Refused(Func<Task> action, string message)
{
    try { await action(); }
    catch (InvalidOperationException error) { Check(error.Message.Contains(message), error.Message); return; }
    throw new Exception("Expected refusal: " + message);
}
var draft = new HarnessConfigState();
draft.Load(Config());
Check(!draft.Dirty, "Reading settings must not create writes");
draft.Values["model"] = "unsaved";
draft.Values["secret"] = "never sent";
Check(draft.Changes.Count == 1 && draft.Changes["model"]!.GetValue<string>() == "unsaved", "Save must send only changed allowlisted fields");
draft.Load(Config("installer default", "high"), true);
Check(draft.Values["model"] == "unsaved" && draft.Values["effort"] == "high", "Reinstall must preserve edits and refresh unedited settings");
draft.Values["model"] = "";
draft.Load(Config("another default", "max"), true);
Check(draft.Values["model"] == "" && draft.Dirty, "Clearing a setting must survive a reload");
try { draft.Load(JsonNode.Parse("""{"available":false,"fields":[]}""")!, true); throw new Exception("Missing fields must not discard edits"); }
catch (InvalidOperationException) { }
Check(draft.Values["model"] == "" && draft.Dirty, "An unavailable config lost pending edits");
draft.Load(Config("saved", "max"));
Check(!draft.Dirty && draft.Values["model"] == "saved", "Save must adopt the returned baseline");

foreach (var version in new[] { "36", "0", "bad" })
    Check(!LauncherInstaller.SupportsReinstall(new JsonObject { ["protocolVersion"] = version }), "An older or invalid protocol enabled Reinstall");
Check(!LauncherInstaller.SupportsReinstall(null) && !LauncherInstaller.SupportsReinstall(new JsonArray()), "An unverified host enabled Reinstall");
Check(LauncherInstaller.SupportsReinstall(new JsonObject { ["protocolVersion"] = "37" })
    && LauncherInstaller.SupportsReinstall(new JsonObject { ["protocolVersion"] = 38 }), "Newer hosts must remain compatible");
Check(LauncherInstaller.Patience == TimeSpan.FromMinutes(21), "Installer patience must exceed the host's twenty-minute execution limit");

var calls = new List<(string Method, JsonNode? Params, TimeSpan? Patience)>();
var versionNow = 37;
var completion = new TaskCompletionSource<JsonNode>(TaskCreationOptions.RunContinuationsAsynchronously);
var confirmed = 0;
var started = 0;
Task<bool> Confirm() { confirmed++; return Task.FromResult(true); }
Task<JsonNode> Call(string method, JsonNode? parameters, TimeSpan? patience)
{
    calls.Add((method, parameters?.DeepClone(), patience));
    return method == "protocol" ? Task.FromResult<JsonNode>(new JsonObject { ["protocolVersion"] = versionNow }) : completion.Task;
}
var repair = LauncherInstaller.RunAsync("host-a", "opencode", true, Call, Confirm, () => started++);
Check(calls.Select(call => call.Method).SequenceEqual(new[] { "protocol", "launcher.reinstall" }), "Reinstall must use its explicit host method");
Check(confirmed == 1 && started == 1 && LauncherInstaller.IsRunning("host-a", "opencode"), "Confirmation and progress must precede the request");
Check(calls.Last().Params!.ToJsonString() == "{\"id\":\"opencode\"}" && calls.Last().Patience == LauncherInstaller.Patience,
    "Only the hardcoded profile ID and full patience may be sent");
await Refused(() => LauncherInstaller.RunAsync("host-a", "opencode", true, Call, Confirm), "already running");
Check(calls.Count == 2 && LauncherInstaller.IsRunning("host-a", "opencode"), "Duplicate requests must not send or clear progress");
var other = LauncherInstaller.RunAsync("host-b", "opencode", false, Call, Confirm);
Check(calls.Last().Method == "launcher.install" && confirmed == 1, "Ordinary install must retain its separate method and protections");
completion.SetResult(new JsonObject { ["ok"] = false, ["output"] = "fixture installer failed", ["exitCode"] = 7 });
await Refused(async () => await repair, "fixture installer failed");
await Refused(async () => await other, "fixture installer failed");
Check(!LauncherInstaller.IsRunning("host-a", "opencode") && !LauncherInstaller.IsRunning("host-b", "opencode"), "Failure must release both independent hosts");

calls.Clear();
var cancelled = await LauncherInstaller.RunAsync("host-a", "opencode", true, Call, () => Task.FromResult(false));
Check(!cancelled && calls.Count == 1 && calls[0].Method == "protocol", "Cancelling must never invoke an installer");
versionNow = 36;
calls.Clear();
await Refused(() => LauncherInstaller.RunAsync("host-a", "opencode", true, Call, Confirm), "Update the computer");
Check(calls.Count == 1 && confirmed == 1, "An old host must be refused before confirmation or mutation");

var attempts = 0;
await Refused(() => LauncherInstaller.RunAsync("local", "opencode", false, (_, _, _) =>
{
    attempts++; throw new InvalidOperationException("connection lost");
}, Confirm), "connection lost");
Check(attempts == 1 && !LauncherInstaller.IsRunning("local", "opencode"), "A lost response must not replay or leave progress stuck");
Check(await LauncherInstaller.RunAsync("local", "opencode", false, (_, _, _) => Task.FromResult<JsonNode>(new JsonObject { ["ok"] = true }), Confirm),
    "A later explicit retry must be able to finish");
await Refused(() => LauncherInstaller.RunAsync("local", "opencode", false, (_, _, _) => Task.FromResult<JsonNode>(new JsonObject { ["ok"] = false, ["exitCode"] = 7 }), Confirm), "7");
Console.WriteLine("Windows harness draft, installer confirmation, routing, deadlines, failure and compatibility tests passed.");
