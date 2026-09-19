// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Text.Json;
using System.Text.Json.Nodes;
using Tokenstat.Design;
using Tokenstat.Pages;

namespace Tokenstat.Navigation;

/// <summary>
/// One folder on another machine, as the sidebar lists it. The id is the
/// shared remote namespace, remote:peer:inner, so a terminal spawned in the
/// folder and the folder itself group under the same peer.
/// </summary>
internal sealed record RemoteFolder(
    string Id,
    string InnerId,
    string Name,
    string Path,
    string PeerKey,
    string MachineLabel)
{
    /// <summary>How the row reads, matching the desktop Mac sidebar.</summary>
    public string DisplayName =>
        string.IsNullOrEmpty(MachineLabel) ? Name : MachineLabel + " / " + Name;
}

/// <summary>
/// Whether an explicit Connect worked, and what to tell the person. A refusal
/// is a notice rather than an error: the other screen shows this machine
/// waiting, which is the point, not a failure.
/// </summary>
internal sealed record RemoteConnectResult(bool Connected, string Message, bool IsNotice);

/// <summary>
/// Folders on other machines, read through this PC's daemon. Mirrors the
/// desktop Mac split: the daemon answers remote.call, and this store keeps
/// the merged list, the per-peer backoff, and the explicit Disconnect.
///
/// A peer that is offline does not make local folders disappear: its failure
/// is remembered rather than raised, and its last known folders stay listed
/// until it has missed twice in a row.
/// </summary>
internal static class RemoteWorkspaces
{
    public const string Prefix = "remote:";

    /// <summary>Raised on a background thread when the cached list changes.</summary>
    public static event Action? Changed;

    private static readonly object Gate = new();
    private static int _sweeping;
    private static readonly Dictionary<string, List<RemoteFolder>> FoldersByPeer =
        new(StringComparer.Ordinal);
    private static readonly HashSet<string> Suppressed = new(StringComparer.Ordinal);
    private static readonly Dictionary<string, int> Failures = new(StringComparer.Ordinal);
    private static readonly Dictionary<string, DateTime> NextDial = new(StringComparer.Ordinal);
    private static readonly HashSet<string> EverAnswered = new(StringComparer.Ordinal);
    private static readonly HashSet<string> AskedWorkspace = new(StringComparer.Ordinal);
    private static readonly HashSet<string> Connected = new(StringComparer.Ordinal);

    private static readonly TimeSpan RefreshAfter = TimeSpan.FromSeconds(60);
    private static readonly TimeSpan RetryAfter = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan ColdRetryAfter = TimeSpan.FromMinutes(10);
    private const int BackOffAfter = 3;
    private const int DropAfter = 2;

    public static bool IsRemote(string id) =>
        id.StartsWith(Prefix, StringComparison.Ordinal);

    /// <summary>
    /// Split remote:peer:inner into its peer key and the folder id on that
    /// machine. False for a local id.
    /// </summary>
    public static bool TrySplit(string id, out string peer, out string inner)
    {
        peer = "";
        inner = "";
        if (!IsRemote(id))
        {
            return false;
        }
        var rest = id[Prefix.Length..];
        var i = rest.IndexOf(':');
        if (i <= 0 || i + 1 >= rest.Length)
        {
            return false;
        }
        peer = rest[..i];
        inner = rest[(i + 1)..];
        return true;
    }

    public static string Join(string peer, string inner) => Prefix + peer + ":" + inner;

    /// <summary>
    /// A host answered, and the answer was no. Connection failures and a
    /// phone that cannot host a folder are different, and must not raise a
    /// permission request. Same three strings the desktop Mac matches.
    /// </summary>
    public static bool IsWorkspaceRefusal(string message)
    {
        var lower = message.ToLowerInvariant();
        return lower.Contains("has not let this device")
            || lower.Contains("workspace_not_allowed")
            || lower.Contains("open its work");
    }

    /// <summary>
    /// Ask a peer a question, through this machine's daemon. The result is
    /// the peer's own, unwrapped: a failure over there is a failure here.
    /// </summary>
    public static Task<JsonNode> CallOnPeerAsync(string peer, string method, JsonNode? parameters = null) =>
        AppServices.Host.CallAsync(
            "remote.call",
            new JsonObject
            {
                ["peer"] = peer,
                ["method"] = method,
                ["params"] = parameters ?? new JsonObject(),
            });

    /// <summary>
    /// One workspace method against a local or remote folder id. A remote id
    /// travels as remote.call with the peer's own id, the way the desktop Mac
    /// routes every workspace read. The params object is copied, never
    /// mutated, so a retry cannot forward an already rewritten id.
    /// </summary>
    public static Task<JsonNode> CallWorkspaceAsync(string id, string method, JsonNode? parameters = null)
    {
        if (!TrySplit(id, out var peer, out var inner))
        {
            return AppServices.Host.CallAsync(method, parameters);
        }
        var forwarded = parameters is null
            ? new JsonObject()
            : (JsonObject)JsonNode.Parse(parameters.ToJsonString())!;
        forwarded["id"] = inner;
        return CallOnPeerAsync(peer, method, forwarded);
    }

    /// <summary>Whether the row offers Disconnect instead of Connect.</summary>
    public static bool IsConnected(string peerKey)
    {
        lock (Gate)
        {
            return Connected.Contains(peerKey);
        }
    }

    public static IReadOnlyList<RemoteFolder> CachedFolders()
    {
        lock (Gate)
        {
            return FoldersByPeer.Values.SelectMany(f => f).ToList();
        }
    }

    public static RemoteFolder? CachedFolder(string id)
    {
        lock (Gate)
        {
            return FoldersByPeer.Values
                .SelectMany(f => f)
                .FirstOrDefault(f => f.Id == id);
        }
    }

    /// <summary>
    /// Dial one peer now, on an explicit Connect. Marks the row connected
    /// only after the dial works: a failed dial under an offline machine
    /// must not look like a stuck connection.
    /// </summary>
    public static async Task<RemoteConnectResult> ConnectAsync(
        string peerKey, string label, bool tunnelOn, bool? online)
    {
        var name = string.IsNullOrEmpty(label) ? "That machine" : label;
        if (!tunnelOn)
        {
            return new RemoteConnectResult(
                false, $"Turn on Reach devices from anywhere before connecting to {name}.", false);
        }
        if (online == false)
        {
            return new RemoteConnectResult(false, $"{name} is offline. Connect when it is awake.", false);
        }
        try
        {
            var folders = await ReadPeerFoldersAsync(peerKey, label);
            lock (Gate)
            {
                Suppressed.Remove(peerKey);
                Failures.Remove(peerKey);
                NextDial.Remove(peerKey);
                EverAnswered.Add(peerKey);
                FoldersByPeer[peerKey] = folders;
                Connected.Add(peerKey);
            }
            SetAutoConnect(true, peerKey);
            Changed?.Invoke();
            return new RemoteConnectResult(
                true, $"Connected to {name}. Its workspaces are now available in the sidebar.", true);
        }
        catch (Exception ex)
        {
            var text = ex.Message;
            lock (Gate)
            {
                Connected.Remove(peerKey);
            }
            if (text.Contains("has not approved", StringComparison.OrdinalIgnoreCase)
                || text.Contains("not approved", StringComparison.OrdinalIgnoreCase))
            {
                return new RemoteConnectResult(
                    true,
                    $"{name} has been asked to let this device in. Approve it on the other device and its workspaces will appear here.",
                    true);
            }
            if (IsWorkspaceRefusal(text))
            {
                try
                {
                    await CallOnPeerAsync(peerKey, "workspace.access.ask");
                }
                catch
                {
                    // The question may already stand over there. The notice
                    // below still says what to do about it.
                }
                return new RemoteConnectResult(
                    true,
                    $"{name} has been asked to let this device open its work. Approve it on that computer and its folders will appear here.",
                    true);
            }
            if (text.Contains("closed before the answer arrived", StringComparison.OrdinalIgnoreCase))
            {
                return new RemoteConnectResult(
                    false,
                    $"The connection to {name} dropped mid-answer. It reconnects automatically. Try again in a moment.",
                    true);
            }
            var lower = text.ToLowerInvariant();
            if (lower.Contains("offline") || lower.Contains("not reachable")
                || lower.Contains("timed out") || lower.Contains("timeout"))
            {
                return new RemoteConnectResult(
                    false,
                    $"{name} is offline or not reachable right now. Wait until it is awake, then try Connect again.",
                    false);
            }
            return new RemoteConnectResult(false, FriendlyError.Display(text), false);
        }
    }

    /// <summary>
    /// Drop the peer's folders from the sidebar now. The connection itself is
    /// a tunnel channel that ends when its last use does; what was asked for
    /// is that the machine stops appearing as connected here.
    /// </summary>
    public static void Disconnect(string peerKey)
    {
        lock (Gate)
        {
            Suppressed.Add(peerKey);
            FoldersByPeer.Remove(peerKey);
            NextDial.Remove(peerKey);
            Failures.Remove(peerKey);
            Connected.Remove(peerKey);
        }
        Changed?.Invoke();
    }

    /// <summary>
    /// A folder was registered or cloned on this peer. Fetch now rather than
    /// on the next sweep, so the sidebar shows what was just made.
    /// </summary>
    public static void RefreshPeer(string peerKey)
    {
        lock (Gate)
        {
            // Registering a folder is an explicit return to this computer,
            // even if it was disconnected earlier in the session.
            Suppressed.Remove(peerKey);
            Failures.Remove(peerKey);
            NextDial.Remove(peerKey);
        }
        SetAutoConnect(true, peerKey);
        _ = SweepAsync();
    }

    /// <summary>
    /// Folders on other machines, read through the local daemon. Runs on the
    /// slow sidebar tick, never on a file change: every peer here is a dial
    /// with a connect timeout and a handshake.
    /// </summary>
    public static async Task SweepAsync()
    {
        // Boot, the sidebar timer and workspace creation can request a sweep
        // together. One pass owns the retry counters and peer requests.
        if (Interlocked.Exchange(ref _sweeping, 1) != 0)
        {
            return;
        }
        try
        {
            await SweepCoreAsync();
        }
        finally
        {
            Volatile.Write(ref _sweeping, 0);
        }
    }

    private static async Task SweepCoreAsync()
    {
        bool tunnelOn;
        List<(string Key, string Label, string? Address)> peers;
        try
        {
            var status = await AppServices.Host.CallAsync("remote.status");
            tunnelOn = status?["tunnel"]?.GetValue<bool>() ?? false;
            var listed = await AppServices.Host.CallAsync("machine.peers") as JsonArray ?? new();
            peers = new();
            foreach (var peer in listed.OfType<JsonNode>())
            {
                if (Format.Text(peer, "trust") != "approved")
                {
                    continue;
                }
                var key = Format.Text(peer, "key");
                if (string.IsNullOrEmpty(key))
                {
                    continue;
                }
                var address = Format.Text(peer, "address");
                // A peer without an address is dialled through the tunnel.
                // Without it the sweep would never reach a machine behind NAT.
                if (string.IsNullOrEmpty(address) && !tunnelOn)
                {
                    continue;
                }
                peers.Add((key, Format.Text(peer, "label"), address));
            }
        }
        catch
        {
            // Not surfaced. The peer list failing is not a reason to put an
            // error over a screen full of working local folders.
            return;
        }

        var changed = false;
        var now = DateTime.UtcNow;
        HashSet<string> live;
        lock (Gate)
        {
            live = new HashSet<string>(peers.Select(p => p.Key), StringComparer.Ordinal);
            foreach (var key in FoldersByPeer.Keys.ToList())
            {
                if (!live.Contains(key) || Suppressed.Contains(key))
                {
                    FoldersByPeer.Remove(key);
                    Failures.Remove(key);
                    Connected.Remove(key);
                    changed = true;
                }
            }
        }
        foreach (var (key, label, _) in peers)
        {
            DateTime? next;
            lock (Gate)
            {
                if (Suppressed.Contains(key) || !IsAutoConnectEnabledLocked(key))
                {
                    continue;
                }
                next = NextDial.TryGetValue(key, out var at) ? at : null;
            }
            if (next.HasValue && now < next.Value)
            {
                continue;
            }
            try
            {
                var folders = await ReadPeerFoldersAsync(key, label);
                lock (Gate)
                {
                    if (Suppressed.Contains(key))
                    {
                        continue;
                    }
                    // A steady refresh must not rebuild the sidebar: the
                    // folders are records, so a value compare says whether
                    // anything actually moved.
                    var newlySeen = !FoldersByPeer.ContainsKey(key);
                    var same = !newlySeen
                        && FoldersByPeer[key].SequenceEqual(folders);
                    FoldersByPeer[key] = folders;
                    NextDial[key] = now + RefreshAfter;
                    Failures[key] = 0;
                    EverAnswered.Add(key);
                    if (newlySeen)
                    {
                        Connected.Add(key);
                    }
                    if (newlySeen || !same)
                    {
                        changed = true;
                    }
                }
            }
            catch (Exception ex)
            {
                var text = ex.Message;
                lock (Gate)
                {
                    if (IsWorkspaceRefusal(text))
                    {
                        // Reached a host that has not let this device in. Ask
                        // once per session, then back off like any refusal, so
                        // a machine whose owner said no is not asked twice a
                        // minute for the rest of the session. Its folders stay:
                        // the host is reachable, it has simply not said yes.
                        if (AskedWorkspace.Add(key))
                        {
                            var askKey = key;
                            _ = Task.Run(async () =>
                            {
                                try
                                {
                                    await CallOnPeerAsync(askKey, "workspace.access.ask");
                                }
                                catch
                                {
                                }
                            });
                        }
                        Failures[key] = Failures.TryGetValue(key, out var refusals) ? refusals + 1 : 1;
                        var neverOpened = !EverAnswered.Contains(key);
                        NextDial[key] = now + (neverOpened && Failures[key] >= BackOffAfter
                            ? ColdRetryAfter : RetryAfter);
                        continue;
                    }
                    var failures = Failures.TryGetValue(key, out var n) ? n + 1 : 1;
                    Failures[key] = failures;
                    // A machine that answered before is worth asking again
                    // soon: it is probably asleep and will be back. One that
                    // never answered is usually a phone or a tablet, which
                    // cannot host a folder, and asking it every thirty seconds
                    // is three pointless tunnel dials a minute, forever.
                    var neverAnswered = !EverAnswered.Contains(key);
                    NextDial[key] = now + (neverAnswered && failures >= BackOffAfter
                        ? ColdRetryAfter : RetryAfter);
                    if (failures >= DropAfter && FoldersByPeer.Remove(key))
                    {
                        Connected.Remove(key);
                        changed = true;
                    }
                }
            }
        }
        if (changed)
        {
            Changed?.Invoke();
        }
    }

    private static async Task<List<RemoteFolder>> ReadPeerFoldersAsync(string peerKey, string peerLabel)
    {
        var answer = await CallOnPeerAsync(peerKey, "workspace.list");
        var array = answer as JsonArray ?? answer["folders"] as JsonArray ?? answer["workspaces"] as JsonArray;
        var folders = new List<RemoteFolder>();
        if (array is null)
        {
            return folders;
        }
        foreach (var folder in array.OfType<JsonNode>())
        {
            var inner = Format.Text(folder, "id");
            if (string.IsNullOrEmpty(inner))
            {
                continue;
            }
            var name = Format.Text(folder, "name", Format.Text(folder, "path", inner));
            folders.Add(new RemoteFolder(
                Join(peerKey, inner),
                inner,
                name,
                Format.Text(folder, "path"),
                peerKey,
                peerLabel));
        }
        return folders;
    }

    private static string PrefsPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "tokenstat",
        "remote-autoconnect.json");

    /// <summary>
    /// Whether the sweep dials this peer on its own. On by default, like the
    /// desktop Mac and the phone: an explicit Connect turns it back on, the
    /// toggle turns it off. A plain file, not LocalSettings: this app is
    /// unpackaged, and ApplicationData.Current throws there.
    /// </summary>
    public static bool IsAutoConnectEnabled(string peerKey)
    {
        lock (Gate)
        {
            return IsAutoConnectEnabledLocked(peerKey);
        }
    }

    public static void SetAutoConnect(bool on, string peerKey)
    {
        lock (Gate)
        {
            var prefs = ReadPrefsLocked();
            prefs[peerKey] = on;
            WritePrefsLocked(prefs);
        }
    }

    private static bool IsAutoConnectEnabledLocked(string peerKey)
    {
        var prefs = ReadPrefsLocked();
        return !prefs.TryGetValue(peerKey, out var on) || on;
    }

    private static Dictionary<string, bool> ReadPrefsLocked()
    {
        try
        {
            if (!File.Exists(PrefsPath))
            {
                return new Dictionary<string, bool>(StringComparer.Ordinal);
            }
            var parsed = JsonNode.Parse(File.ReadAllText(PrefsPath)) as JsonObject;
            var prefs = new Dictionary<string, bool>(StringComparer.Ordinal);
            if (parsed is not null)
            {
                foreach (var (key, value) in parsed)
                {
                    if (value is JsonValue v
                        && v.GetValueKind() is JsonValueKind.True or JsonValueKind.False)
                    {
                        prefs[key] = v.GetValue<bool>();
                    }
                }
            }
            return prefs;
        }
        catch
        {
            return new Dictionary<string, bool>(StringComparer.Ordinal);
        }
    }

    private static void WritePrefsLocked(Dictionary<string, bool> prefs)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(PrefsPath)!);
            var obj = new JsonObject();
            foreach (var (key, value) in prefs)
            {
                obj[key] = value;
            }
            File.WriteAllText(PrefsPath, obj.ToJsonString());
        }
        catch
        {
            // The toggle simply does not survive a restart.
        }
    }
}
