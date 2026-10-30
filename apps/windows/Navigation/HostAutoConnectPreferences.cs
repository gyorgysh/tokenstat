// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Tokenstat.Navigation;

/// <summary>Account-owned host reconnect choices, including one-time legacy migration.</summary>
internal sealed class HostAutoConnectPreferences(string path, string legacyPath)
{
    public bool IsEnabled(string? scope, string peer)
    {
        if (string.IsNullOrEmpty(scope) || string.IsNullOrEmpty(peer)) return false;
        var root = Read();
        var account = (root["scopes"] as JsonObject)?[scope] as JsonObject;
        return account?[peer] is not JsonValue value
            || value.GetValueKind() is not (JsonValueKind.True or JsonValueKind.False)
            || value.GetValue<bool>();
    }

    public void Set(string? scope, string peer, bool enabled)
    {
        if (string.IsNullOrEmpty(scope) || string.IsNullOrEmpty(peer)) return;
        var root = Read();
        var scopes = root["scopes"] as JsonObject;
        if (scopes is null) root["scopes"] = scopes = new JsonObject();
        var account = scopes[scope] as JsonObject;
        if (account is null) scopes[scope] = account = new JsonObject();
        account[peer] = enabled;
        Write(root);
    }

    /// <summary>Claim each old choice once, and only for a peer listed on this account.</summary>
    public void Migrate(string? scope, IEnumerable<string> accountPeers)
    {
        if (string.IsNullOrEmpty(scope)) return;
        var legacy = Read(legacyPath);
        if (legacy.Count == 0) return;
        var root = Read();
        var scopes = root["scopes"] as JsonObject;
        if (scopes is null) root["scopes"] = scopes = new JsonObject();
        var account = scopes[scope] as JsonObject;
        if (account is null) scopes[scope] = account = new JsonObject();
        var claimed = root["claimedLegacyPeers"] as JsonObject;
        if (claimed is null) root["claimedLegacyPeers"] = claimed = new JsonObject();
        var changed = false;
        foreach (var peer in accountPeers.Distinct(StringComparer.Ordinal))
        {
            if (peer.Length == 0 || claimed.ContainsKey(peer) || legacy[peer] is not JsonValue value
                || value.GetValueKind() is not (JsonValueKind.True or JsonValueKind.False)) continue;
            if (!account.ContainsKey(peer)) account[peer] = value.GetValue<bool>();
            claimed[peer] = true;
            changed = true;
        }
        if (changed) Write(root);
    }

    private JsonObject Read() => Read(path);

    private static JsonObject Read(string file)
    {
        try { return JsonNode.Parse(File.ReadAllText(file)) as JsonObject ?? new JsonObject(); }
        catch (IOException) { return new JsonObject(); }
        catch (UnauthorizedAccessException) { return new JsonObject(); }
        catch (JsonException) { return new JsonObject(); }
    }

    private void Write(JsonObject root)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                File.WriteAllText(temporary, root.ToJsonString());
                File.Move(temporary, path, true);
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}
