// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Tokenstat.Design;
using Tokenstat.Navigation;

namespace Tokenstat.Pages;

internal sealed record BrowserProjectMemory(string Owner, string AccountScope, long Generation)
{
    public static OperationEpoch AccountEpoch { get; } = new();
    public bool IsCurrent => Generation == AccountEpoch.Revision;
    static BrowserProjectMemory() => AppServices.AccountChanged += () =>
    {
        AccountEpoch.Advance();
        _ = BrowserBridges.InvalidateAsync();
    };
    private static readonly Lazy<BrowserHistory> Saved = new(() => new BrowserHistory(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "tokenstat", "browser-projects.json")));
    public IReadOnlyList<string> Targets => Saved.Value.Read(Owner);
    public void Remember(string original) { if (IsCurrent) Saved.Value.Remember(Owner, original); }
    public static string? Scope(JsonNode status)
    {
        var account = status["account"] ?? status;
        var identity = Format.Flag(account, "signedIn")
            ? Format.Text(account, "accountId", Format.Text(account, "handle")) : "local";
        var origin = Format.Text(account, "host");
        return identity.Length == 0 || origin.Length == 0 ? null : BrowserHistory.AccountScope(origin, identity);
    }
    public static async Task<BrowserProjectMemory?> ForAsync(string workspaceId)
    {
        var generation = AccountEpoch.Revision;
        try
        {
            var status = await AppServices.Host.CallAsync("account.status");
            var scope = Scope(status);
            if (scope is null) return null;
            string host, project;
            if (RemoteWorkspaces.TrySplit(workspaceId, out var peer, out var inner)) { host = peer; project = inner; }
            else
            {
                var identity = await AppServices.Host.CallAsync("machine.identity");
                host = Format.Text(identity, "key"); project = workspaceId;
            }
            return generation != AccountEpoch.Revision || host.Length == 0 || project.Length == 0 ? null : new(BrowserHistory.Key(scope, host, project), scope, generation);
        }
        catch { return null; } // A failed identity read must not borrow another project's targets.
    }
}
