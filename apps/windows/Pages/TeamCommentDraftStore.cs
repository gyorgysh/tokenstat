// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Tokenstat.Pages;

internal sealed record TeamCommentTarget(string Origin, string Person, string Organization, string Repository, string Checkout, string Share, string Host);
internal sealed record TeamCommentAttempt(string Id, long CreatedAtMs);
internal sealed record TeamCommentDraft(string Revision, string Text, TeamCommentAttempt? Attempt, string Label)
{
    internal JsonObject? Input => Attempt is not { } a ? null : new JsonObject {
        ["text"] = Text, ["clientMessageId"] = a.Id, ["clientMessageCreatedAtMs"] = a.CreatedAtMs,
    };
    internal bool CanSend => !string.IsNullOrWhiteSpace(Text) && Encoding.UTF8.GetByteCount(Text) <= 8192
        && Encoding.UTF8.GetByteCount((this with { Attempt = Attempt ?? new(Guid.NewGuid().ToString(), 1) }).Input!.ToJsonString()) <= 14 * 1024;
}
internal sealed record TeamCommentRecovery(TeamCommentTarget Target, TeamCommentDraft? Draft, TeamCommentUnsaved? Unsaved);
internal sealed record TeamCommentUnsaved(string Text, TeamCommentDraft? Expected, string Label);
internal sealed record TeamCommentDraftPage(IReadOnlyList<TeamCommentRecovery> Entries, string? Next, bool Unreadable);
internal sealed class TeamDraftException(string key) : IOException(key) { internal string Key => Message; }

/// App-owned local writing, separated by stable verified person and exact
/// published resource. Persist the immutable attempt before any network send.
internal sealed class TeamCommentDraftStore(string directory)
{
    internal static readonly TeamCommentDraftStore Shared = new(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "tokenstat", "team-comment-drafts"));
    private static readonly object Gate = new();
    private readonly Dictionary<TeamCommentTarget, TeamCommentUnsaved> _unsaved = new();
    private const int Limit = 128 * 1024;
    private sealed record Envelope(int Version, TeamCommentTarget Target, TeamCommentDraft Draft);
    private static string Hash(object value) => Convert.ToHexString(SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(value))).ToLowerInvariant();
    private string Owner(TeamCommentTarget t) => Path.Combine(directory, Hash(new[] { t.Origin, t.Person }));
    private static string Name(TeamCommentTarget t) => Hash(t) + ".json";
    private static TeamDraftException Changed() => new("comment_draft_changed");
    private static void RequireTarget(TeamCommentTarget t)
    {
        if (new[] { t.Origin, t.Person, t.Organization, t.Repository, t.Checkout, t.Share, t.Host }.Any(s => string.IsNullOrWhiteSpace(s) || Encoding.UTF8.GetByteCount(s) > 2048))
            throw new TeamDraftException("comment_save_failed");
    }
    private T Locked<T>(TeamCommentTarget target, Func<string, T> work)
    {
        lock (Gate)
        {
            RequireTarget(target);
            Directory.CreateDirectory(directory);
            if ((File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0) throw new TeamDraftException("comment_save_failed");
            var owner = Owner(target); Directory.CreateDirectory(owner);
            if ((File.GetAttributes(owner) & FileAttributes.ReparsePoint) != 0) throw new TeamDraftException("comment_save_failed");
            // FileShare.None also excludes another running app instance. Busy
            // storage fails promptly; it never discards the person's writing.
            using var guard = new FileStream(Path.Combine(owner, "drafts.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
            return work(owner);
        }
    }
    private static Envelope? Read(string file)
    {
        if (!File.Exists(file)) return null;
        if ((File.GetAttributes(file) & FileAttributes.ReparsePoint) != 0) throw new TeamDraftException("comment_save_failed");
        using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (stream.Length > Limit) throw new TeamDraftException("comment_save_failed");
        var bytes = new byte[Limit + 1]; var length = 0;
        while (length < bytes.Length) { var count = stream.Read(bytes, length, bytes.Length - length); if (count == 0) break; length += count; }
        if (length > Limit) throw new TeamDraftException("comment_save_failed");
        var envelope = JsonSerializer.Deserialize<Envelope>(bytes.AsSpan(0, length)) ?? throw new TeamDraftException("comment_save_failed");
        var d = envelope.Draft;
        RequireTarget(envelope.Target);
        if (envelope.Version != 1 || d is null || !Guid.TryParse(d.Revision, out _) || d.Text is null || Encoding.UTF8.GetByteCount(d.Text) > 64 * 1024 || d.Label is null || Encoding.UTF8.GetByteCount(d.Label) > 2560
            || d.Attempt is { } a && (!Guid.TryParse(a.Id, out _) || a.CreatedAtMs <= 0 || !d.CanSend)) throw new TeamDraftException("comment_save_failed");
        return envelope;
    }
    private TeamCommentDraft? ReadTarget(string owner, TeamCommentTarget target)
    {
        var e = Read(Path.Combine(owner, Name(target)));
        if (e is not null && e.Target != target) throw new TeamDraftException("comment_save_failed");
        return e?.Draft;
    }
    private static void Write(string owner, TeamCommentTarget target, TeamCommentDraft? draft)
    {
        var file = Path.Combine(owner, Name(target));
        if (draft is null) { File.Delete(file); return; }
        if (Encoding.UTF8.GetByteCount(draft.Text) > 64 * 1024) throw new TeamDraftException("comment_too_long");
        var bytes = JsonSerializer.SerializeToUtf8Bytes(new Envelope(1, target, draft));
        if (bytes.Length > Limit) throw new TeamDraftException("comment_too_long");
        var temp = Path.Combine(owner, "." + Guid.NewGuid().ToString("N") + ".tmp");
        try
        {
            using (var stream = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { stream.Write(bytes); stream.Flush(true); }
            if (OperatingSystem.IsWindows())
            {
                // Atomic replace with write-through, before a send is allowed.
                if (!MoveFileEx(temp, file, 0x1 | 0x8)) throw new IOException("draft rename failed", Marshal.GetLastWin32Error());
            }
            else File.Move(temp, file, true); // Portable fixture runner.
        }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }
    [DllImport("kernel32.dll", EntryPoint = "MoveFileExW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool MoveFileEx(string source, string destination, int flags);
    internal TeamCommentDraft? Load(TeamCommentTarget t) => Locked(t, owner => ReadTarget(owner, t));
    internal void Remember(TeamCommentTarget t, string text, TeamCommentDraft? expected, string label) { lock (Gate) _unsaved[t] = new(text, expected, label); }
    internal TeamCommentUnsaved? Unsaved(TeamCommentTarget t) { lock (Gate) return _unsaved.GetValueOrDefault(t); }
    internal void ForgetUnsaved(TeamCommentTarget t) { lock (Gate) _unsaved.Remove(t); }
    internal TeamCommentDraft? Save(TeamCommentTarget t, string text, TeamCommentDraft? expected, string label)
    {
        lock (Gate)
        {
            try
            {
                var next = Locked(t, owner => {
                    var current = ReadTarget(owner, t);
                    if (current != expected) throw Changed();
                    if (current?.Attempt is not null) throw new TeamDraftException("comment_check_first");
                    if (current?.Text == text) return current;
                    var value = text.Length == 0 ? null : new TeamCommentDraft(Guid.NewGuid().ToString(), text, null, label);
                    Write(owner, t, value); return value;
                });
                _unsaved.Remove(t); return next;
            }
            catch { _unsaved[t] = new(text, expected, label); throw; }
        }
    }
    internal TeamCommentDraft Reserve(TeamCommentTarget t, TeamCommentDraft expected) => Locked(t, owner => {
        if (ReadTarget(owner, t) != expected) throw Changed();
        if (!expected.CanSend) throw new TeamDraftException("comment_too_long");
        if (expected.Attempt is not null) return expected;
        var value = expected with { Revision = Guid.NewGuid().ToString(), Attempt = new(Guid.NewGuid().ToString(), DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()) };
        Write(owner, t, value); return value;
    });
    internal TeamCommentDraft? Resolve(TeamCommentTarget t, TeamCommentDraft expected, JsonNode receipt) => Locked(t, owner => {
        var state = ReceiptState(t, expected, receipt);
        var current = ReadTarget(owner, t);
        if (current is null && state == "accepted") return null;
        if (current != expected) throw Changed();
        if (state is "pending" or "unknown") return expected;
        var next = state == "accepted" ? null : expected with { Revision = Guid.NewGuid().ToString(), Attempt = null };
        Write(owner, t, next); return next;
    });
    internal static string ReceiptState(TeamCommentTarget t, TeamCommentDraft expected, JsonNode receipt)
    {
        static string? Text(JsonNode? n) => n is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;
        var state = Text(receipt["state"]);
        if (expected.Attempt is not { } a || Text(receipt["shareId"]) != t.Share || Text(receipt["clientMessageId"]) != a.Id
            || state is not ("unknown" or "pending" or "accepted" or "notAccepted")
            || (state == "accepted" ? receipt["sequence"] is not JsonValue seq || !seq.TryGetValue<ulong>(out _) || receipt["acceptedAtMs"] is not JsonValue at || !at.TryGetValue<long>(out var ms) || ms <= 0 : receipt["sequence"] is not null || receipt["acceptedAtMs"] is not null))
            throw new TeamDraftException("comment_unconfirmed");
        return state!;
    }
    internal TeamCommentDraftPage List(string origin, string person, string? after = null)
    {
        var probe = new TeamCommentTarget(origin, person, "list", "list", "list", "list", "list");
        return Locked(probe, owner => {
            var recovery = _unsaved.Where(p => p.Key.Origin == origin && p.Key.Person == person).ToDictionary(p => Name(p.Key), p => p);
            // Retain only the next bounded candidate window while scanning
            // the directory; recovery never materializes the whole archive.
            var candidates = new SortedSet<string>(StringComparer.Ordinal);
            foreach (var name in Directory.EnumerateFiles(owner, "*.json").Select(Path.GetFileName).OfType<string>().Concat(recovery.Keys))
            {
                if (after is not null && string.CompareOrdinal(name, after) <= 0) continue;
                candidates.Add(name); if (candidates.Count > 201) candidates.Remove(candidates.Max!);
            }
            var names = candidates.ToList();
            var entries = new List<TeamCommentRecovery>(); var visited = 0; var unreadable = false;
            foreach (var name in names)
            {
                visited++;
                try
                {
                    var e = Read(Path.Combine(owner, name));
                    var t = e?.Target ?? recovery[name].Key;
                    if (t.Origin != origin || t.Person != person || Name(t) != name) throw new IOException();
                    entries.Add(new(t, e?.Draft, recovery.TryGetValue(name, out var r) ? r.Value : null));
                }
                catch { unreadable = true; if (recovery.TryGetValue(name, out var r)) entries.Add(new(r.Key, r.Value.Expected, r.Value)); }
                if (entries.Count == 40 || visited == 200) break;
            }
            return new TeamCommentDraftPage(entries, visited < names.Count ? names[visited - 1] : null, unreadable);
        });
    }
    internal void Discard(TeamCommentRecovery entry) => Locked(entry.Target, owner => {
        if (ReadTarget(owner, entry.Target) != entry.Draft || _unsaved.GetValueOrDefault(entry.Target) != entry.Unsaved) throw Changed();
        Write(owner, entry.Target, null); _unsaved.Remove(entry.Target); return true;
    });
}
