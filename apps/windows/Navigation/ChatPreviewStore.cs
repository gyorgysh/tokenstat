// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text;
using System.Text.Json.Nodes;

namespace Tokenstat.Navigation;

/// <summary>Small, ephemeral cache; never persisted and invalidated on account changes.</summary>
internal sealed class ChatPreviewStore(Func<DateTime>? clock = null)
{
    private sealed record Entry(JsonNode Chunk, DateTime Expires);
    private readonly Dictionary<(string Workspace, string Chat), Entry> _entries = new();
    private readonly Func<DateTime> _now = clock ?? (() => DateTime.UtcNow);
    public int Generation { get; private set; }
    public void Clear() { Generation++; _entries.Clear(); }
    public bool Contains(string workspace, string chat) =>
        _entries.TryGetValue((workspace, chat), out var entry) && entry.Expires > _now();
    public JsonNode? Take(string workspace, string chat) =>
        _entries.Remove((workspace, chat), out var entry) && entry.Expires > _now() ? entry.Chunk : null;

    public bool Store(string workspace, string chat, JsonNode chunk, int generation)
    {
        if (generation != Generation || Encoding.UTF8.GetByteCount(chunk.ToJsonString()) > 512 * 1024) return false;
        var now = _now();
        foreach (var stale in _entries.Where(item => item.Value.Expires <= now).Select(item => item.Key).ToArray())
            _entries.Remove(stale);
        var key = (workspace, chat);
        if (_entries.Count >= 10 && !_entries.ContainsKey(key))
            _entries.Remove(_entries.MinBy(item => item.Value.Expires).Key);
        _entries[key] = new Entry(chunk, now.AddSeconds(20));
        return true;
    }
}
