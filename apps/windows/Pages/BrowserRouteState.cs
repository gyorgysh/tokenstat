// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
namespace Tokenstat.Pages;

/// <summary>Canonical history survives listener rotation. Only the active listener is usable.</summary>
internal sealed class BrowserRouteState
{
    internal enum RequestAction { Pass, Rewrite, Reopen, Block }
    internal sealed record Lease(string Host, int Port, long Generation, string Local);
    private readonly Dictionary<(string Host, int Port), Lease> _history = new();
    private static (string Host, int Port) Endpoint(Uri uri) => (uri.Host.ToLowerInvariant(), uri.Port);
    public Lease? Active { get; private set; }
    public void Activate(Lease lease)
    {
        Active = lease;
        _history[Endpoint(new Uri(lease.Local))] = lease;
    }
    public Lease? Retire() { var lease = Active; Active = null; return lease; }
    public void Reset() { Active = null; _history.Clear(); }
    public void ForgetBefore(long generation)
    {
        foreach (var key in _history.Where(entry => entry.Value.Generation < generation).Select(entry => entry.Key).ToArray()) _history.Remove(key);
    }
    public Lease? Historical(Uri uri, long generation) => _history.TryGetValue(Endpoint(uri), out var lease)
        && lease.Generation == generation ? lease : null;
    public bool IsActiveProxy(Uri uri, long generation) => Active is { } lease && lease.Generation == generation
        && Endpoint(new Uri(lease.Local)) == Endpoint(uri);
    public bool IsActiveOriginal(Uri uri, long generation) => Active is { } lease && lease.Generation == generation
        && uri.Host.Equals(lease.Host, StringComparison.OrdinalIgnoreCase) && uri.Port == lease.Port;
    private bool IsActiveAlias(Uri uri, long generation) => Active is { } active && Historical(uri, generation) is { } historical
        && active.Generation == generation && active.Port == historical.Port && active.Host.Equals(historical.Host, StringComparison.OrdinalIgnoreCase);
    public string Display(string actual)
    {
        if (!Uri.TryCreate(actual, UriKind.Absolute, out var uri)) return actual;
        return _history.TryGetValue(Endpoint(uri), out var lease)
            ? new UriBuilder(uri) { Host = lease.Host, Port = lease.Port }.Uri.AbsoluteUri : actual;
    }
    public static string Through(Lease lease, Uri original) => new UriBuilder(original)
    { Host = new Uri(lease.Local).Host, Port = new Uri(lease.Local).Port }.Uri.AbsoluteUri;
    public static bool IsLoopback(Uri uri) => uri.IsLoopback || uri.Host.Equals("0.0.0.0", StringComparison.OrdinalIgnoreCase);
    public static bool IsTopLevelDocument(bool document, string? fetchDestination) => document && fetchDestination == "document";
    public static RequestAction WorkerRequest(Uri uri, bool currentListener) => !IsLoopback(uri) || currentListener
        ? RequestAction.Pass : RequestAction.Block;
    public RequestAction Request(Uri uri, string method, bool topLevelDocument, long generation)
    {
        if (!IsLoopback(uri)) return RequestAction.Pass;
        if (IsActiveProxy(uri, generation)) return RequestAction.Pass;
        if (IsActiveOriginal(uri, generation) || IsActiveAlias(uri, generation)) return RequestAction.Rewrite;
        return topLevelDocument && method.Equals("GET", StringComparison.OrdinalIgnoreCase) && Historical(uri, generation) is not null
            ? RequestAction.Reopen : RequestAction.Block;
    }
    public bool AllowsFrame(Uri uri, long generation) => !IsLoopback(uri)
        || IsActiveProxy(uri, generation) || IsActiveOriginal(uri, generation) || IsActiveAlias(uri, generation);
}
