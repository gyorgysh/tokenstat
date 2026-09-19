// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;

namespace Tokenstat.Pages;

internal static class SshVaultSync
{
    private static readonly SemaphoreSlim Gate = new(1, 1);
    private static readonly string[] Kinds = ["folder", "key", "host", "snippet"];

    public static async Task SyncAsync()
    {
        await Gate.WaitAsync();
        try
        {
            var answer = await AppServices.Host.CallAsync("ssh.vault.record.list");
            var records = answer["records"] as JsonArray ?? throw new InvalidOperationException("The vault returned no records.");
            var known = records.OfType<JsonNode>().Select(r => Format.Text(r, "id")).ToHashSet();
            var local = await ReadLocalAsync();
            // A child folder cannot be saved before its parent. Repeatedly
            // take ready folders; refuse cycles rather than partially guessing.
            var pending = records.OfType<JsonNode>().OrderByDescending(r => Format.Flag(r, "deleted")).ToList();
            while (pending.Count > 0)
            {
                var progressed = false;
                foreach (var record in pending.ToList())
                {
                    var id = Format.Text(record, "id");
                    var split = id.Split(':', 2);
                    if (split.Length != 2 || !Kinds.Contains(split[0])) { pending.Remove(record); continue; }
                    var kind = split[0];
                    local.TryGetValue(id, out var current);
                    if (Format.Flag(record, "deleted"))
                    {
                        if (current is not null)
                        {
                            await AppServices.Host.CallAsync($"ssh.{kind}.delete", new JsonObject { ["id"] = split[1] });
                            if (kind == "key") SshSecrets.Forget(Format.Text(current, "secretRef"));
                            local.Remove(id);
                            // Deleting a folder reparents and stamps its children.
                            // Continue merging with those records, not old copies.
                            if (kind == "folder") local = await ReadLocalAsync();
                        }
                    }
                    else
                    {
                        JsonObject? envelope;
                        try { envelope = JsonNode.Parse(Format.Text(record, "plaintext")) as JsonObject; }
                        catch { pending.Remove(record); continue; }
                        if (envelope?[kind] is not JsonObject remote
                            || Format.Text(envelope, "kind") != kind
                            || Format.Text(remote, "id") != split[1])
                        {
                            pending.Remove(record);
                            continue;
                        }
                        var stamp = Format.Long(remote, "updatedMs");
                        if (current is not null && Format.Long(current, "updatedMs") > stamp)
                            await PushAsync(kind, current);
                        else if (current is null || Format.Long(current, "updatedMs") < stamp
                            || (kind == "key" && !SshSecrets.Has(Format.Text(current, "secretRef"))))
                        {
                            var parent = Format.Text(remote, kind == "folder" ? "parentId" : "folderId");
                            if (parent.Length > 0 && !local.ContainsKey("folder:" + parent)) continue;
                            var save = (JsonObject)remote.DeepClone();
                            string? reference = null;
                            if (kind == "key")
                            {
                                // Stage under a fresh reference. If metadata save
                                // fails (or its answer is lost), the existing key
                                // and any successfully saved new record stay valid.
                                reference = CredentialVault.RefFor(split[1] + "_" + Guid.NewGuid().ToString("N"));
                                if (!SshSecrets.Put(reference, Format.Text(remote, "privateKey")))
                                    throw new InvalidOperationException("Could not store the synced key in Windows Credential Manager.");
                                save.Remove("privateKey");
                                save["secretRef"] = reference;
                            }
                            save["keepUpdatedMs"] = true;
                            local[id] = await AppServices.Host.CallAsync($"ssh.{kind}.save", save);
                            if (reference is not null && current is not null)
                                SshSecrets.Forget(Format.Text(current, "secretRef"));
                        }
                    }
                    pending.Remove(record);
                    progressed = true;
                }
                if (!progressed && pending.Count > 0)
                    throw new InvalidOperationException("Some vault records refer to missing folders. Sync those folders from the original device first.");
            }
            foreach (var pair in local.Where(pair => !known.Contains(pair.Key)))
                await PushAsync(pair.Key.Split(':', 2)[0], pair.Value);
        }
        finally { Gate.Release(); }
    }

    private static async Task<Dictionary<string, JsonNode>> ReadLocalAsync()
    {
        var local = new Dictionary<string, JsonNode>();
        foreach (var kind in Kinds)
        {
            var rows = Format.Items(await AppServices.Host.CallAsync($"ssh.{kind}.list"))
                ?? throw new InvalidOperationException($"Could not read local SSH {kind} records.");
            foreach (var row in rows.OfType<JsonNode>())
                local[kind + ":" + Format.Text(row, "id")] = row;
        }
        return local;
    }

    // Mirror edits before the next pull can bring an old record back. A
    // configured, locked vault must be unlocked before editing synced data.
    public static async Task<JsonNode> WriteAsync(string method, JsonObject parameters)
    {
        await Gate.WaitAsync();
        try
        {
            var account = await AppServices.Host.CallAsync("account.status");
            if (!Format.Flag(account, "signedIn"))
                return await AppServices.Host.CallAsync(method, parameters);
            var status = await AppServices.Host.CallAsync("ssh.vault.status");
            var problem = Format.Text(status, "unreachable");
            if (problem.Length > 0) throw new InvalidOperationException(problem);
            var synced = Format.Flag(status, "created");
            if (synced && (Format.Flag(status, "locked") || Format.Flag(status, "needsRecreate")))
                throw new InvalidOperationException("Unlock the SSH vault before editing synced records.");
            var kind = method.Split('.')[1];
            if (synced && method.EndsWith(".delete", StringComparison.Ordinal))
                await AppServices.Host.CallAsync("ssh.vault.record.delete", new JsonObject
                { ["id"] = kind + ":" + Format.Text(parameters, "id") });
            var moved = new HashSet<string>();
            if (synced && method == "ssh.folder.delete")
            {
                var id = Format.Text(parameters, "id");
                foreach (var pair in await ReadLocalAsync())
                    if ((pair.Key.StartsWith("folder:") && Format.Text(pair.Value, "parentId") == id)
                        || (pair.Key.StartsWith("host:") && Format.Text(pair.Value, "folderId") == id))
                        moved.Add(pair.Key);
            }
            var saved = await AppServices.Host.CallAsync(method, parameters);
            if (synced && method == "ssh.folder.delete")
            {
                // The host also moves children up a level. Publish those
                // stamped moves so another client never restores the old tree.
                foreach (var pair in await ReadLocalAsync())
                    if (moved.Contains(pair.Key))
                        await PushAsync(pair.Key.Split(':', 2)[0], pair.Value);
            }
            if (synced && method.EndsWith(".save", StringComparison.Ordinal))
            {
                try { await PushAsync(kind, saved); }
                catch (Exception ex) { throw new InvalidOperationException("Saved on this PC, but vault sync failed: " + ex.Message); }
            }
            return saved;
        }
        finally { Gate.Release(); }
    }

    private static async Task PushAsync(string kind, JsonNode record)
    {
        var copy = (JsonObject)record.DeepClone();
        if (kind == "key")
        {
            var material = SshSecrets.Get(Format.Text(record, "secretRef"));
            if (material is null || Format.Flag(record, "hardwareBacked")) return;
            copy.Remove("secretRef");
            copy["privateKey"] = material;
        }
        var envelope = new JsonObject { ["kind"] = kind, [kind] = copy };
        await AppServices.Host.CallAsync("ssh.vault.record.put", new JsonObject
        {
            ["id"] = kind + ":" + Format.Text(record, "id"),
            ["plaintext"] = envelope.ToJsonString(),
        });
    }

}
