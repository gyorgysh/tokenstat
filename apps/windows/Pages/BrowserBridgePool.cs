// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
namespace Tokenstat.Pages;

/// <summary>The host's endpoint registry has no account namespace. Retire an
/// earlier account under the same gate before opening the next account's lease.</summary>
internal sealed class BrowserBridgePool(
    Func<long> currentGeneration,
    Func<string, string, int, Task<string>> listen,
    Func<string, string, int, Task> retire)
{
    private readonly record struct Endpoint(string Peer, string Host, int Port);
    private sealed class Held(long generation, string url)
    {
        public long Generation { get; } = generation;
        public string Url { get; } = url;
        public int Count { get; set; } = 1;
    }
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly Dictionary<Endpoint, Held> _held = new();
    private readonly record struct Listener(long Generation, string Host, int Port);
    private Listener[] _listeners = [];

    public bool IsCurrentListener(Uri uri)
    {
        if (uri.Scheme is not ("http" or "https") || uri.UserInfo.Length > 0) return false;
        var generation = currentGeneration();
        var live = Volatile.Read(ref _listeners).Any(listener => listener.Generation == generation
            && listener.Port == uri.Port && listener.Host.Equals(uri.Host, StringComparison.OrdinalIgnoreCase));
        return live && generation == currentGeneration();
    }

    public async Task<string> AcquireAsync(string peer, string host, int port, long generation)
    {
        await _gate.WaitAsync();
        try
        {
            EnsureCurrent(generation);
            await RetireStaleAsync(strict: true);
            EnsureCurrent(generation);
            var endpoint = new Endpoint(peer, host, port);
            if (_held.TryGetValue(endpoint, out var existing))
            {
                existing.Count++;
                return existing.Url;
            }
            string url;
            try { url = await listen(peer, host, port); }
            catch
            {
                // A lost answer can leave a host registration behind. Keep
                // uncertain cleanup in the pool so no later account reuses it.
                var uncertain = new Held(generation, "") { Count = 0 };
                _held[endpoint] = uncertain;
                PublishListeners();
                try { await RetireAsync(endpoint, uncertain); } catch { }
                throw;
            }
            var entry = new Held(generation, url);
            _held[endpoint] = entry;
            if (!ValidListener(url) || generation != currentGeneration())
            {
                entry.Count = 0;
                PublishListeners();
                await RetireAsync(endpoint, entry);
                EnsureCurrent(generation);
                throw new InvalidOperationException("The host did not return a local browser address.");
            }
            PublishListeners();
            return url;
        }
        finally { _gate.Release(); }
    }

    public async Task ReleaseAsync(string peer, string host, int port, long generation)
    {
        await _gate.WaitAsync();
        try
        {
            var endpoint = new Endpoint(peer, host, port);
            if (!_held.TryGetValue(endpoint, out var entry) || entry.Generation != generation) return;
            if (entry.Count > 1) { entry.Count--; return; }
            entry.Count = 0;
            PublishListeners();
            await RetireAsync(endpoint, entry);
        }
        finally { _gate.Release(); }
    }

    public async Task InvalidateAsync()
    {
        await _gate.WaitAsync();
        try { await RetireStaleAsync(strict: false); }
        finally { _gate.Release(); }
    }

    private async Task RetireStaleAsync(bool strict)
    {
        foreach (var (endpoint, entry) in _held.ToArray())
        {
            if (entry.Generation == currentGeneration() && entry.Count > 0) continue;
            try { await RetireAsync(endpoint, entry); }
            catch when (!strict) { /* A subsequent Open retries retirement before reuse. */ }
        }
    }

    private async Task RetireAsync(Endpoint endpoint, Held entry)
    {
        await retire(endpoint.Peer, endpoint.Host, endpoint.Port);
        if (_held.TryGetValue(endpoint, out var registered) && ReferenceEquals(entry, registered)) _held.Remove(endpoint);
        PublishListeners();
    }

    private void PublishListeners() => Volatile.Write(ref _listeners, _held.Values
        .Where(entry => entry.Count > 0 && ValidListener(entry.Url))
        .Select(entry => new Listener(entry.Generation, new Uri(entry.Url).Host, new Uri(entry.Url).Port)).ToArray());

    private void EnsureCurrent(long generation)
    {
        if (generation != currentGeneration()) throw new InvalidOperationException("The account changed before this preview opened.");
    }

    private static bool ValidListener(string url) => Uri.TryCreate(url, UriKind.Absolute, out var parsed)
        && parsed.IsLoopback && parsed.Scheme == "http" && parsed.UserInfo.Length == 0 && parsed.Port > 0;
}
