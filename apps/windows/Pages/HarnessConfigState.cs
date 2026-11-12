// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Globalization;
using System.Text.Json.Nodes;

namespace Tokenstat.Pages;

/// <summary>Only Save writes settings. Reloads retain the person's pending edits.</summary>
internal sealed class HarnessConfigState
{
    public JsonNode? Config { get; private set; }
    public Dictionary<string, string> Values { get; } = new(StringComparer.Ordinal);
    public IEnumerable<JsonObject> Fields => (Config?["fields"] as JsonArray ?? new JsonArray()).OfType<JsonObject>();
    public JsonObject Changes
    {
        get
        {
            var changes = new JsonObject();
            foreach (var setting in Fields)
            {
                var key = Format.Text(setting, "key");
                if (Values.TryGetValue(key, out var value) && value != Format.Text(setting, "value")) changes[key] = value;
            }
            return changes;
        }
    }
    public bool Dirty => Changes.Count > 0;

    public void Load(JsonNode config, bool preservingEdits = false)
    {
        var edits = preservingEdits ? Changes : new JsonObject();
        var keys = (config["fields"] as JsonArray ?? new JsonArray()).OfType<JsonObject>()
            .Select(field => Format.Text(field, "key")).ToHashSet(StringComparer.Ordinal);
        // A failed config read often returns an empty field list. Keep the old
        // form and draft rather than discarding edits after an installer ran.
        if (edits.Any(edit => !keys.Contains(edit.Key)))
            throw new InvalidOperationException(L10n.Text("windows.harnessconfig.reload_preserved"));
        Config = config.DeepClone();
        Values.Clear();
        foreach (var field in Fields)
        {
            var key = Format.Text(field, "key");
            Values[key] = edits[key]?.GetValue<string>() ?? Format.Text(field, "value");
        }
    }
}

/// <summary>
/// Agent versions and updates (protocol 55). Versions are read on the owning
/// machine. The latest version is asked of the vendor only on a check, which
/// runs when somebody presses Check for updates.
/// </summary>
internal static class AgentUpdates
{
    public const int MinimumProtocol = 55;

    public static bool Supported(JsonNode? protocol) => protocol is JsonObject answer
        && long.TryParse(answer["protocolVersion"]?.ToString(), NumberStyles.None, CultureInfo.InvariantCulture, out var version)
        && version >= MinimumProtocol;

    public static async Task<JsonObject?> RowAsync(string id, bool check,
        Func<string, JsonNode?, TimeSpan?, Task<JsonNode>> call)
    {
        var rows = await call("launcher.updates", new JsonObject { ["check"] = check }, TimeSpan.FromMinutes(2));
        return (rows as JsonArray ?? new JsonArray()).OfType<JsonObject>()
            .FirstOrDefault(row => Format.Text(row, "id") == id);
    }

    /// <summary>"Version 2.1.318 · 2.1.322 available", or empty.</summary>
    public static string Describe(JsonObject? row, bool checkedNow)
    {
        if (row is null) return "";
        var parts = new List<string>();
        var version = Format.Text(row, "version");
        if (version.Length > 0) parts.Add(L10n.Text("common.agent_updates.version", version));
        var latest = Format.Text(row, "latest");
        if (Format.Flag(row, "updateAvailable") && latest.Length > 0) parts.Add(L10n.Text("common.agent_updates.available", latest));
        else if (checkedNow && row["updateAvailable"] is not null) parts.Add(L10n.Text("common.agent_updates.up_to_date"));
        if (checkedNow && !Format.Flag(row, "canCheck")) parts.Add(L10n.Text("common.agent_updates.unknown_latest"));
        var error = Format.Text(row, "error");
        if (error.Length > 0) parts.Add(L10n.Text("common.agent_updates.check_failed", error));
        return string.Join(" · ", parts);
    }

    /// <summary>Offered once a check found a newer version, or nothing to compare.</summary>
    public static bool Offers(JsonObject? row, bool checkedNow) => row is not null && Format.Flag(row, "canUpdate")
        && (Format.Flag(row, "updateAvailable") || (checkedNow && !Format.Flag(row, "canCheck")));
}

/// <summary>One installer request per tool and owning machine, never retried here.</summary>
internal static class LauncherInstaller
{
    public const int MinimumReinstallProtocol = 37;
    public static readonly TimeSpan Patience = TimeSpan.FromMinutes(21);
    private static readonly HashSet<(string Machine, string Profile)> Running = new();
    private static readonly object Gate = new();

    public static bool SupportsReinstall(JsonNode? protocol) => protocol is JsonObject answer
        && long.TryParse(answer["protocolVersion"]?.ToString(), NumberStyles.None, CultureInfo.InvariantCulture, out var version)
        && version >= MinimumReinstallProtocol;

    public static bool IsRunning(string machine, string id)
    {
        lock (Gate) return Running.Contains((machine, id));
    }

    public static async Task<bool> RunAsync(string machine, string id, bool reinstall,
        Func<string, JsonNode?, TimeSpan?, Task<JsonNode>> call, Func<Task<bool>> confirm, Action? started = null)
    {
        lock (Gate)
        {
            if (!Running.Add((machine, id))) throw new InvalidOperationException(L10n.Text("windows.harnessconfig.already_running"));
        }
        try
        {
            if (reinstall)
            {
                if (!SupportsReinstall(await call("protocol", null, null)))
                    throw new InvalidOperationException(L10n.Text("windows.harnessconfig.update_host"));
                if (!await confirm()) return false;
            }
            started?.Invoke();
            var result = await call(reinstall ? "launcher.reinstall" : "launcher.install", new JsonObject { ["id"] = id }, Patience);
            if (!Format.Flag(result, "ok"))
            {
                var output = Format.Text(result, "output").Trim();
                throw new InvalidOperationException(output.Length > 0 ? output
                    : result["exitCode"] is null ? L10n.Text("windows.workspacepage.installation_failed.bfb3106f")
                    : L10n.Text("windows.harnessconfig.installer_failed", Format.Text(result, "exitCode")));
            }
            return true;
        }
        finally { lock (Gate) Running.Remove((machine, id)); }
    }
}
