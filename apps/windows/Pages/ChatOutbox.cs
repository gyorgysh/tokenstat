// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Tokenstat.Pages;

internal sealed record QueuedChatMessage(string Id, string Text, string[] Attachments, long Revision,
    string State = "waiting", long? AttemptedAt = null);

/// <summary>Durable, bounded drafts. All readers and writers share the file lock.</summary>
internal sealed class ChatOutbox(string directory)
{
    public static readonly ChatOutbox Shared = new(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "tokenstat", "outbox"));
    public static string Key(string account, string workspace, string chat) => Convert.ToHexString(
        SHA256.HashData(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new[] { account, workspace, chat }))));

    public List<QueuedChatMessage> Read(string key) => Update(key, _ => { });

    public List<QueuedChatMessage> Update(string key, Action<List<QueuedChatMessage>> change)
    {
        if (key.Length != 64 || key.Any(c => !Uri.IsHexDigit(c))) throw new ArgumentException("Invalid outbox scope.");
        Directory.CreateDirectory(directory);
        using var gate = new FileStream(Path.Combine(directory, key + ".lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        var path = Path.Combine(directory, key + ".json");
        List<QueuedChatMessage> items = [];
        string? original = null;
        if (File.Exists(path))
        {
            if (new FileInfo(path).Length > 2 * 1024 * 1024) throw new IOException("Pending messages exceed the storage limit.");
            original = File.ReadAllText(path);
            items = JsonSerializer.Deserialize<List<QueuedChatMessage>>(original)
                ?? throw new IOException("Pending messages could not be read.");
        }
        change(items);
        if (items.Count > 20 || items.Select(item => item.Id).Distinct().Count() != items.Count)
            throw new IOException("At most 20 messages can be queued in a conversation.");
        var serialized = JsonSerializer.Serialize(items);
        if (Encoding.UTF8.GetByteCount(serialized) > 2 * 1024 * 1024) throw new IOException("Pending messages exceed the storage limit.");
        if (serialized != original)
        {
            var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                using (var file = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                {
                    file.Write(Encoding.UTF8.GetBytes(serialized));
                    file.Flush(flushToDisk: true);
                }
                File.Move(temporary, path, overwrite: true);
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
        return items;
    }

    public QueuedChatMessage Stage(string key, QueuedChatMessage expected, long now)
    {
        var staged = expected with { State = "sending", AttemptedAt = now };
        Update(key, items =>
        {
            var current = items.FirstOrDefault();
            if (current is null || current.Id != expected.Id || current.AttemptedAt.HasValue ||
                current.Text != expected.Text || current.Revision != expected.Revision ||
                !current.Attachments.SequenceEqual(expected.Attachments))
                throw new InvalidOperationException("The pending message changed in another window.");
            items[0] = staged;
        });
        return staged;
    }

    public List<QueuedChatMessage> Accept(string key, QueuedChatMessage accepted, long? revision) => Update(key, items =>
    {
        items.RemoveAll(item => item.Id == accepted.Id);
        if (revision != accepted.Revision + 1) return;
        for (var i = 0; i < items.Count; i++)
            if (items[i].State == "waiting" && items[i].Revision == accepted.Revision)
                items[i] = items[i] with { Revision = revision.Value };
    });
}
