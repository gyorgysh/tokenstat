// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Reflection;
using System.Text.Json.Nodes;
using Tokenstat.Install;

var checks = 0;
void Check(bool condition, string message)
{
    if (!condition) throw new Exception(message);
    checks++;
}
void Reject(string json)
{
    try { AppInstaller.ReadVerifiedPublisher(json); }
    catch (Exception ex) when (ex is AppInstaller.Failure or System.Text.Json.JsonException)
    {
        checks++;
        return;
    }
    throw new Exception("Untrusted signature accepted: " + json);
}
Check(AppInstaller.ReadVerifiedPublisher("{\"status\":\"NotSigned\"}") is null, "Unsigned local builds remain supported.");
Check(AppInstaller.ReadVerifiedPublisher("{\"status\":\"Valid\",\"subject\":\"CN=Example\"}") == "CN=Example", "Valid signer accepted.");
foreach (var status in new[] { "HashMismatch", "NotTrusted", "UnknownError", "NotSupportedFileFormat", "Incompatible", "" })
    Reject("{\"status\":\"" + status + "\",\"subject\":\"CN=Example\"}");
Reject("{\"status\":\"Valid\",\"subject\":\" \"}");
Reject("{}");
Reject("bad json");

var scratch = Path.Combine(Path.GetTempPath(), "tokenstat-install-tests-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(scratch);
try
{
    var staging = Path.Combine(scratch, "stage");
    Directory.CreateDirectory(staging);
    var nested = Path.Combine(staging, "release", "win-x64");
    Directory.CreateDirectory(Path.Combine(nested, "Assets"));
    File.WriteAllText(Path.Combine(nested, "Tokenstat.exe"), "app");
    File.WriteAllText(Path.Combine(nested, "tokenstat-hostd.exe"), "host");
    File.WriteAllText(Path.Combine(nested, "Assets", "icon.png"), "asset");
    typeof(AppInstaller).GetMethod("FlattenExtractedTree", BindingFlags.NonPublic | BindingFlags.Static)!.Invoke(null, new object[] { staging });
    Check(File.ReadAllText(Path.Combine(staging, "Assets", "icon.png")) == "asset", "Nested archive preserves assets.");
    Check(!Directory.Exists(Path.Combine(staging, "release")), "Nested archive is flattened.");
    bool Ready() => (bool)typeof(AppInstaller).GetMethod("IsStagingReady", BindingFlags.NonPublic | BindingFlags.Static)!.Invoke(null, new object[] { staging })!;
    Check(!Ready(), "Extracting executable files alone is not verification.");
    File.WriteAllText(Path.Combine(staging, "PENDING-UPDATE.txt"), "verified");
    Check(Ready(), "Complete verified staging is ready.");
    File.Delete(Path.Combine(staging, "tokenstat-hostd.exe"));
    Check(!Ready(), "Incomplete staging cannot be applied.");
    var source = Path.Combine(scratch, "source");
    var dest = Path.Combine(scratch, "installed");
    Directory.CreateDirectory(source);
    Directory.CreateDirectory(dest);
    File.WriteAllText(Path.Combine(source, "Tokenstat.exe"), "new");
    File.WriteAllText(Path.Combine(dest, "Tokenstat.exe"), "old");
    File.WriteAllText(Path.Combine(dest, "obsolete.dll"), "old");
    var stopped = false;
    try { SelfInstall.InstallTree(source, dest, () => stopped = true); }
    catch (IOException) { }
    Check(!stopped && File.ReadAllText(Path.Combine(dest, "Tokenstat.exe")) == "old", "Incomplete install never stops or overwrites working app.");
    File.WriteAllText(Path.Combine(source, "tokenstat-hostd.exe"), "host");
    try
    {
        SelfInstall.InstallTree(source, dest, () =>
        {
            foreach (var dir in Directory.EnumerateDirectories(scratch, "installed.install-*"))
                Directory.Delete(dir, recursive: true);
        });
    }
    catch (IOException) { }
    Check(File.ReadAllText(Path.Combine(dest, "Tokenstat.exe")) == "old", "Failed directory swap restores old app.");
    SelfInstall.InstallTree(source, dest, () => stopped = true);
    Check(stopped && File.ReadAllText(Path.Combine(dest, "Tokenstat.exe")) == "new", "Successful staged swap installs new app.");
    Check(!File.Exists(Path.Combine(dest, "obsolete.dll")), "Old release files do not leak into new install.");
    Check(!Directory.EnumerateDirectories(scratch).Any(path => Path.GetFileName(path).StartsWith("installed.", StringComparison.Ordinal)), "Staging and backup directories cleaned up.");

}
finally { Directory.Delete(scratch, recursive: true); }
var pending = new TaskCompletionSource<JsonNode>(TaskCreationOptions.RunContinuationsAsynchronously);
var calls = 0;
Tokenstat.Host.HostClient.Reply = () => { Interlocked.Increment(ref calls); return pending.Task; };
var update = new AppUpdateModel();
var first = update.CheckAndInstallAsync();
await Task.WhenAll(Enumerable.Range(0, 20).Select(_ => Task.Run(update.CheckAndInstallAsync)));
Check(calls == 1, "Concurrent update checks share the existing operation.");
pending.SetResult(new JsonObject { ["newer"] = false });
await first;
Check(update.Current == AppUpdateModel.Stage.Idle, "Update returns to idle.");
Tokenstat.Host.HostClient.Reply = () => Task.FromResult<JsonNode>(new JsonObject { ["newer"] = false });
await update.CheckAndInstallAsync();
Check(update.Current == AppUpdateModel.Stage.Idle, "Update gate releases after completion.");
Console.WriteLine($"Windows installer: {checks} checks passed.");

namespace Tokenstat.Design
{
    internal static class AppInfo
    {
        public const string Version = "1.0.0";
        public const string Company = "Example";
    }
}
namespace Tokenstat.Navigation
{
    internal enum WorkspaceSection { Chat }
}
namespace Tokenstat.Host
{
    internal sealed class HostClient
    {
        public const string PipeName = "test";
        public static Func<Task<JsonNode>> Reply = () => Task.FromResult<JsonNode>(new JsonObject());
        public Task<JsonNode> CallAsync(string method, JsonNode? args = null, TimeSpan? patience = null) => Reply();
        public JsonNode Call(string method, object? args, TimeSpan patience) => new JsonObject();
    }
}
