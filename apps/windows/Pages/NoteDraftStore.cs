// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
namespace Tokenstat.Pages;

/// <summary>UI-thread draft ownership and serialized writes for each note.</summary>
internal sealed class NoteDraftStore
{
    internal sealed record Text(string Title, string Notes);
    internal sealed class Entry(Text saved)
    {
        public Text Value { get; set; } = saved;
        public Text Saved { get; set; } = saved;
        public bool Saving { get; set; }
        public bool HasSaved { get; set; }
        public string? Error { get; set; }
        public bool Dirty => Value != Saved;
        public Task? Pending { get; set; }
    }

    private readonly Dictionary<string, Entry> _entries = new();
    public event Action<string>? Changed;
    public Entry? Get(string id) => _entries.GetValueOrDefault(id);

    public Text Open(string id, Text saved)
    {
        if (_entries.TryGetValue(id, out var current) && (current.Dirty || current.Saving || current.Error is not null))
            return current.Value;
        _entries[id] = new Entry(saved);
        return saved;
    }

    public void Edit(string id, Text value)
    {
        var entry = _entries[id];
        if (entry.Value == value) return;
        entry.Value = value;
        entry.Error = null;
        Changed?.Invoke(id);
    }

    public Task SaveAsync(string id, Func<Text, Task> write)
    {
        if (!_entries.TryGetValue(id, out var entry)) return Task.CompletedTask;
        if (entry.Saving) return entry.Pending ?? Task.CompletedTask;
        if (!entry.Dirty) return Task.CompletedTask;
        entry.Saving = true;
        entry.Pending = DrainAsync(id, entry, write);
        return entry.Pending;
    }

    private async Task DrainAsync(string id, Entry entry, Func<Text, Task> write)
    {
        try
        {
            entry.Error = null;
            Changed?.Invoke(id);
            while (entry.Dirty)
            {
                var submitted = entry.Value;
                var title = submitted.Title.Trim();
                var normalized = submitted with { Title = title.Length == 0 ? entry.Saved.Title : title };
                await write(normalized);
                if (entry.Value == submitted) entry.Value = normalized;
                entry.Saved = normalized;
                entry.HasSaved = true;
            }
        }
        catch (Exception ex) { entry.Error = ex.Message; }
        finally
        {
            entry.Saving = false;
            entry.Pending = null;
            Changed?.Invoke(id);
        }
    }
}
