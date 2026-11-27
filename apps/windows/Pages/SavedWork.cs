// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using Tokenstat.Design;
using Tokenstat.Host;

namespace Tokenstat.Pages;

internal sealed record SavedWork(long AccountGeneration, string Scope)
{
    private static readonly SemaphoreSlim KeyGate = new(1, 1);
    public bool IsCurrent => AccountGeneration == AppServices.AccountGeneration;

    public static async Task<SavedWork> OpenAsync()
    {
        var generation = AppServices.AccountGeneration;
        var status = await AppServices.Host.CallAsync("account.status");
        if (generation != AppServices.AccountGeneration) throw new OperationCanceledException();
        var account = status["account"] ?? status;
        var signedIn = Format.Flag(account, "signedIn");
        var owner = Format.Text(account, "accountId");
        if (signedIn && owner.Length == 0) throw new InvalidOperationException(L10n.Text("windows.savedwork.no_account"));
        return new SavedWork(generation, signedIn ? "windows:" + Digest(Format.Text(account, "host") + "\0" + owner) : "windows:local");
    }

    public async Task KeepAsync(string workspace, string chat, string title, string transcript, bool partial)
    {
        var id = Digest(workspace + "\0" + chat);
        var key = await KeyAsync();
        await CallAsync("cache.put", new JsonObject
        {
            ["id"] = id, ["itemId"] = id, ["kind"] = "conversation", ["key"] = key,
            ["payload"] = new JsonObject { ["title"] = title, ["text"] = transcript, ["partial"] = partial },
        });
        await CallAsync("cache.pin", new JsonObject { ["id"] = id, ["pinned"] = true });
    }

    public async Task<JsonArray> ListAsync() => (await CallAsync("cache.list", new JsonObject()))["records"] as JsonArray ?? new JsonArray();

    public async Task<JsonNode?> ReadAsync(string id)
    {
        CheckAccount();
        var key = CredentialVault.LoadWorkKey(Scope);
        if (key is null) return null;
        try
        {
            var record = await CallAsync("cache.get", new JsonObject { ["id"] = id, ["key"] = key });
            return Format.Text(record, "scope") == Scope && Format.Text(record, "kind") == "conversation" && Format.Text(record, "id") == id
                ? record["payload"] : null;
        }
        catch (HostException ex) when (ex.Message == "cache miss") { return null; }
    }

    public Task RemoveAsync(string id) => CallAsync("cache.remove", new JsonObject { ["id"] = id });

    private async Task<string> KeyAsync()
    {
        await KeyGate.WaitAsync();
        try
        {
            CheckAccount();
            if (CredentialVault.LoadWorkKey(Scope) is { } existing) return existing;
            if ((await ListAsync()).Count > 0) throw new InvalidOperationException(L10n.Text("windows.savedwork.key_unavailable"));
            CheckAccount();
            var bytes = RandomNumberGenerator.GetBytes(32);
            try
            {
                var key = Convert.ToBase64String(bytes);
                if (!CredentialVault.SaveWorkKey(Scope, key)) throw new InvalidOperationException(L10n.Text("windows.savedwork.key_unavailable"));
                return key;
            }
            finally { CryptographicOperations.ZeroMemory(bytes); }
        }
        finally { KeyGate.Release(); }
    }

    private async Task<JsonNode> CallAsync(string method, JsonObject args)
    {
        CheckAccount();
        args["scope"] = Scope;
        var result = await AppServices.Host.CallAsync(method, args);
        CheckAccount();
        return result;
    }

    private void CheckAccount()
    {
        if (!IsCurrent) throw new OperationCanceledException();
    }

    private static string Digest(string value) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value))).ToLowerInvariant();
}
