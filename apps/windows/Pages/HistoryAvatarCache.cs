// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;

namespace Tokenstat.Pages;

/// Shares a bounded, account-scoped forge lookup across history views.
internal sealed class HistoryAvatarCache
{
    internal readonly record struct Key(long Owner, string Workspace, string From);
    private sealed record Entry(DateTime At, TaskCompletionSource<JsonNode?> Completion);
    private readonly object _gate = new();
    private readonly Dictionary<Key, Entry> _entries = new();

    internal async Task<JsonNode?> GetAsync(Key key, Func<Task<JsonNode?>> fetch)
    {
        Entry entry;
        bool start = false;
        lock (_gate)
        {
            if (!_entries.TryGetValue(key, out entry!) || DateTime.UtcNow - entry.At >= TimeSpan.FromMinutes(5))
            {
                entry = new Entry(DateTime.UtcNow, new(TaskCreationOptions.RunContinuationsAsynchronously));
                _entries[key] = entry;
                start = true;
                foreach (var old in _entries.OrderByDescending(pair => pair.Value.At).Skip(64).Select(pair => pair.Key).ToArray())
                    _entries.Remove(old);
            }
        }
        if (start) _ = CompleteAsync(key, entry, fetch);
        return (await entry.Completion.Task)?.DeepClone();
    }

    private async Task CompleteAsync(Key key, Entry entry, Func<Task<JsonNode?>> fetch)
    {
        JsonNode? result = null;
        try { result = await fetch(); }
        catch { /* A later open may retry a failed lookup. */ }
        if (result is null)
        {
            lock (_gate)
                if (_entries.TryGetValue(key, out var current) && ReferenceEquals(current, entry)) _entries.Remove(key);
        }
        entry.Completion.TrySetResult(result);
    }
}
