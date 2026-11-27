// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Text.Json;
using System.Text.Json.Nodes;
using Tokenstat.Design;
using Tokenstat.Pages;

namespace Tokenstat.Navigation;

internal sealed record RemoteFolder(
    string Id,
    string InnerId,
    string Name,
    string Path,
    string PeerKey,
    string MachineLabel,
    JsonNode? Git = null,
    bool IsGeneral = false)
{
    public string DisplayName =>
        string.IsNullOrEmpty(MachineLabel) ? Name : MachineLabel + " / " + Name;
}

internal sealed record RemoteConnectResult(bool Connected, string Message, bool IsNotice);

internal static class RemoteWorkspaces
{
    static RemoteWorkspaces() => AppServices.AccountChanged += ResetForAccountChange;

    public const string Prefix = "remote:";

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
    private static readonly HashSet<string> Stale = new(StringComparer.Ordinal);
    private static readonly Dictionary<string, long> Revisions = new(StringComparer.Ordinal);
    private static readonly HostAutoConnectPreferences AutoConnect = new(
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "tokenstat", "remote-autoconnect-scoped.json"),
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "tokenstat", "remote-autoconnect.json"));
    private static string? _accountScope;

    public static void ResetForAccountChange()
    {
        lock (Gate)
        {
            FoldersByPeer.Clear();
            Suppressed.Clear();
            Failures.Clear();
            NextDial.Clear();
            EverAnswered.Clear();
            AskedWorkspace.Clear();
            Connected.Clear();
            Stale.Clear();
            Revisions.Clear();
            _accountScope = null;
        }
        Changed?.Invoke();
    }

    private static readonly TimeSpan RefreshAfter = TimeSpan.FromSeconds(60);
    private static readonly TimeSpan RetryAfter = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan ColdRetryAfter = TimeSpan.FromMinutes(10);
    private const int BackOffAfter = 3;
    private const int DropAfter = 2;

    public static bool IsRemote(string id) =>
        id.StartsWith(Prefix, StringComparison.Ordinal);

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

    private static long RevisionLocked(string peer) =>
        Revisions.TryGetValue(peer, out var revision) ? revision : 0;

    private static long AdvanceRevisionLocked(string peer) =>
        Revisions[peer] = RevisionLocked(peer) + 1;

    public static bool IsWorkspaceRefusal(string message)
    {
        var lower = message.ToLowerInvariant();
        return lower.Contains("has not let this device")
            || lower.Contains("workspace_not_allowed")
            || lower.Contains("open its work");
    }

    public static Task<JsonNode> CallOnPeerAsync(string peer, string method, JsonNode? parameters = null, TimeSpan? patience = null) =>
        AppServices.Host.CallAsync(
            "remote.call",
            new JsonObject
            {
                ["peer"] = peer,
                ["method"] = method,
                ["params"] = parameters ?? new JsonObject(),
            }, patience);

    public static Task<JsonNode> CallWorkspaceAsync(string id, string method, JsonNode? parameters = null, TimeSpan? patience = null)
    {
        if (!TrySplit(id, out var peer, out var inner))
        {
            return AppServices.Host.CallAsync(method, parameters, patience);
        }
        var forwarded = RemoteWorkspaceParameters.Forward(parameters, id, inner);
        return CallOnPeerAsync(peer, method, forwarded, patience);
    }

    public static void RememberRegisteredProject(string peer, string hostName, JsonNode folder)
    {
        var inner = Format.Text(folder, "id");
        if (string.IsNullOrEmpty(inner)) return;
        var remote = new RemoteFolder(Join(peer, inner), inner, Format.Text(folder, "name"),
            Format.Text(folder, "path"), peer, hostName, folder["git"]?.DeepClone(), GeneralFolder.IsGeneral(folder));
        lock (Gate)
        {
            if (Suppressed.Contains(peer)) return;
            AdvanceRevisionLocked(peer);
            if (!FoldersByPeer.TryGetValue(peer, out var folders))
                FoldersByPeer[peer] = folders = new List<RemoteFolder>();
            folders.RemoveAll(existing => existing.Id == remote.Id);
            folders.Add(remote);
            NextDial.Remove(peer);
        }
        Changed?.Invoke();
    }

    public static void ProjectChanged(string id, string? name = null)
    {
        if (!TrySplit(id, out var peer, out _)) return;
        lock (Gate)
        {
            AdvanceRevisionLocked(peer);
            if (FoldersByPeer.TryGetValue(peer, out var folders))
            {
                var index = folders.FindIndex(folder => folder.Id == id);
                if (index >= 0)
                {
                    if (name is null) folders.RemoveAt(index);
                    else folders[index] = folders[index] with { Name = name };
                }
            }
            NextDial.Remove(peer);
        }
        Changed?.Invoke();
    }

    public static bool IsConnected(string peerKey)
    {
        lock (Gate)
        {
            return Connected.Contains(peerKey);
        }
    }

    public static bool IsStale(string peerKey)
    {
        lock (Gate) return Stale.Contains(peerKey);
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

    public static async Task<RemoteConnectResult> ConnectAsync(
        string peerKey, string label, bool tunnelOn, bool? online)
    {
        var account = AppServices.AccountGeneration;
        var name = string.IsNullOrEmpty(label) ? L10n.Text("windows.remoteworkspaces.that_machine.1c4194c9") : label;
        try
        {
            SetAccountScope(await AppServices.Host.CallAsync("account.status"), account);
            lock (Gate) { if (account != AppServices.AccountGeneration || _accountScope is null) return AccountChangedResult(); }
        }
        catch (Exception ex)
        {
            return new RemoteConnectResult(false, FriendlyError.Display(ex.Message), false);
        }
        if (!tunnelOn)
        {
            return new RemoteConnectResult(
                false, L10n.Text("windows.remoteworkspaces.turn_on_reach_devices_from_anywhere_before.4930ed6e", $"{name}"), false);
        }
        long revision;
        lock (Gate)
        {
            if (account != AppServices.AccountGeneration) return AccountChangedResult();
            revision = AdvanceRevisionLocked(peerKey);
        }
        try
        {
            await AppServices.Host.CallAsync("remote.nudge");
            var folders = await ReadPeerFoldersAsync(peerKey, label);
            if (account != AppServices.AccountGeneration)
                return AccountChangedResult();
            lock (Gate)
            {
                if (account != AppServices.AccountGeneration)
                    return AccountChangedResult();
                if (revision != RevisionLocked(peerKey))
                    return ConnectionChangedResult();
                Suppressed.Remove(peerKey);
                Failures.Remove(peerKey);
                NextDial.Remove(peerKey);
                EverAnswered.Add(peerKey);
                FoldersByPeer[peerKey] = folders;
                Connected.Add(peerKey);
                Stale.Remove(peerKey);
                AutoConnect.Set(_accountScope, peerKey, true);
            }
            Changed?.Invoke();
            return new RemoteConnectResult(
                true, L10n.Text("windows.remoteworkspaces.connected_to_0_its_workspaces_are_now_avai.c79dc8f5", $"{name}"), true);
        }
        catch (Exception ex)
        {
            var text = ex.Message;
            lock (Gate)
            {
                if (account != AppServices.AccountGeneration)
                    return AccountChangedResult();
                if (revision != RevisionLocked(peerKey))
                    return ConnectionChangedResult();
                Connected.Remove(peerKey);
            }
            if (text.Contains("has not approved", StringComparison.OrdinalIgnoreCase)
                || text.Contains("not approved", StringComparison.OrdinalIgnoreCase))
            {
                return new RemoteConnectResult(
                    true,
                    L10n.Text("windows.remoteworkspaces.approval_requested", name),
                    true);
            }
            if (IsWorkspaceRefusal(text))
            {
                bool removed;
                lock (Gate)
                {
                    if (account != AppServices.AccountGeneration)
                        return AccountChangedResult();
                    if (revision != RevisionLocked(peerKey))
                        return ConnectionChangedResult();
                    removed = FoldersByPeer.Remove(peerKey);
                }
                if (removed) Changed?.Invoke();
                try
                {
                    await CallOnPeerAsync(peerKey, "workspace.access.ask");
                }
                catch
                {
                }
                return new RemoteConnectResult(
                    true,
                    L10n.Text("windows.remoteworkspaces.workspace_approval_requested", name),
                    true);
            }
            if (text.Contains("closed before the answer arrived", StringComparison.OrdinalIgnoreCase))
            {
                return new RemoteConnectResult(
                    false,
                    L10n.Text("windows.remoteworkspaces.the_connection_to_0_dropped_mid_answer_it.0e22c33a", $"{name}"),
                    true);
            }
            var lower = text.ToLowerInvariant();
            if (lower.Contains("offline") || lower.Contains("not reachable")
                || lower.Contains("timed out") || lower.Contains("timeout"))
            {
                return new RemoteConnectResult(
                    false,
                    L10n.Text("windows.remoteworkspaces.0_is_offline_or_not_reachable_right_now_wa.b6a9fae4", $"{name}"),
                    false);
            }
            return new RemoteConnectResult(false, FriendlyError.Display(text), false);
        }
    }

    private static RemoteConnectResult AccountChangedResult() =>
        new(false, L10n.Text("windows.remoteworkspaces.account_changed"), false);

    private static RemoteConnectResult ConnectionChangedResult() =>
        new(false, L10n.Text("windows.remoteworkspaces.connection_changed"), true);

    public static void SetAccountScope(JsonNode status, long accountGeneration)
    {
        var scope = BrowserProjectMemory.Scope(status);
        var account = status["account"] ?? status;
        var members = (account["machines"] as JsonArray ?? new JsonArray())
            .OfType<JsonNode>()
            .Select(machine => Format.Text(machine, "publicIdentity"))
            .Where(key => key.Length > 0);
        lock (Gate)
        {
            if (accountGeneration != AppServices.AccountGeneration) return;
            _accountScope = scope;
            AutoConnect.Migrate(scope, members);
        }
    }

    public static void Disconnect(string peerKey)
    {
        lock (Gate)
        {
            AdvanceRevisionLocked(peerKey);
            Suppressed.Add(peerKey);
            FoldersByPeer.Remove(peerKey);
            NextDial.Remove(peerKey);
            Failures.Remove(peerKey);
            Connected.Remove(peerKey);
            Stale.Remove(peerKey);
            AutoConnect.Set(_accountScope, peerKey, false);
        }
        Changed?.Invoke();
    }

    public static void RefreshPeer(string peerKey)
    {
        lock (Gate)
        {
            AdvanceRevisionLocked(peerKey);
            Suppressed.Remove(peerKey);
            Failures.Remove(peerKey);
            NextDial.Remove(peerKey);
            AutoConnect.Set(_accountScope, peerKey, true);
        }
        _ = SweepAsync();
    }

    public static async Task SweepAsync()
    {
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
        var account = AppServices.AccountGeneration;
        bool tunnelOn;
        List<(string Key, string Label, string? Address)> peers;
        try
        {
            var accountStatus = await AppServices.Host.CallAsync("account.status");
            SetAccountScope(accountStatus, account);
            lock (Gate) { if (account != AppServices.AccountGeneration || _accountScope is null) return; }
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
                if (string.IsNullOrEmpty(address) && !tunnelOn)
                {
                    continue;
                }
                peers.Add((key, Format.Text(peer, "label"), address));
            }
        }
        catch
        {
            return;
        }

        var changed = false;
        var now = DateTime.UtcNow;
        HashSet<string> live;
        lock (Gate)
        {
            if (account != AppServices.AccountGeneration) return;
            live = new HashSet<string>(peers.Select(p => p.Key), StringComparer.Ordinal);
            foreach (var key in FoldersByPeer.Keys.ToList())
            {
                if (!live.Contains(key) || Suppressed.Contains(key))
                {
                    AdvanceRevisionLocked(key);
                    FoldersByPeer.Remove(key);
                    Failures.Remove(key);
                    Connected.Remove(key);
                    Stale.Remove(key);
                    changed = true;
                }
            }
        }
        if (changed) Changed?.Invoke();
        await BoundedHostSweep.RunAsync(peers, 4, async peer =>
        {
            if (await SweepPeerAsync(peer.Key, peer.Label, now, account))
                Changed?.Invoke();
        });
    }

    private static async Task<bool> SweepPeerAsync(string key, string label, DateTime now, long account)
    {
        var changed = false;
        DateTime? next;
        long revision;
        lock (Gate)
        {
            if (account != AppServices.AccountGeneration) return false;
            if (Suppressed.Contains(key) || !IsAutoConnectEnabledLocked(key))
            {
                return false;
            }
            next = NextDial.TryGetValue(key, out var at) ? at : null;
            revision = RevisionLocked(key);
        }
        if (next.HasValue && now < next.Value)
        {
            return false;
        }
        try
        {
            var folders = await ReadPeerFoldersAsync(key, label);
            lock (Gate)
            {
                if (account != AppServices.AccountGeneration ||
                    revision != RevisionLocked(key) || Suppressed.Contains(key) ||
                    !IsAutoConnectEnabledLocked(key))
                {
                    return false;
                }
                var newlySeen = !FoldersByPeer.ContainsKey(key);
                var same = !newlySeen
                    && FoldersByPeer[key].Count == folders.Count
                    && FoldersByPeer[key].Zip(folders).All(pair =>
                        (pair.First with { Git = null }) == (pair.Second with { Git = null })
                        && JsonNode.DeepEquals(pair.First.Git, pair.Second.Git));
                FoldersByPeer[key] = folders;
                NextDial[key] = now + RefreshAfter;
                Failures[key] = 0;
                EverAnswered.Add(key);
                var recovered = Connected.Add(key);
                Stale.Remove(key);
                if (recovered || !same)
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
                if (account != AppServices.AccountGeneration ||
                    revision != RevisionLocked(key) || Suppressed.Contains(key) ||
                    !IsAutoConnectEnabledLocked(key)) return false;
                if (IsWorkspaceRefusal(text))
                {
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
                    if (FoldersByPeer.Remove(key))
                    {
                        Connected.Remove(key);
                        Stale.Remove(key);
                        changed = true;
                    }
                    var neverOpened = !EverAnswered.Contains(key);
                    NextDial[key] = now + (neverOpened && Failures[key] >= BackOffAfter
                        ? ColdRetryAfter : RetryAfter);
                    return changed;
                }
                var failures = Failures.TryGetValue(key, out var n) ? n + 1 : 1;
                Failures[key] = failures;
                var neverAnswered = !EverAnswered.Contains(key);
                NextDial[key] = now + (neverAnswered && failures >= BackOffAfter
                    ? ColdRetryAfter : RetryAfter);
                if (FoldersByPeer.ContainsKey(key) && failures < DropAfter)
                {
                    var becameStale = Stale.Add(key);
                    var disconnected = Connected.Remove(key);
                    if (becameStale || disconnected) changed = true;
                }
                if (failures >= DropAfter && FoldersByPeer.Remove(key))
                {
                    Connected.Remove(key);
                    Stale.Remove(key);
                    changed = true;
                }
            }
        }
        return changed;
    }

    private static async Task<List<RemoteFolder>> ReadPeerFoldersAsync(string peerKey, string peerLabel)
    {
        var answer = await CallOnPeerAsync(peerKey, "workspace.list", GeneralFolder.ListParameters());
        var array = answer as JsonArray ?? answer["folders"] as JsonArray ?? answer["workspaces"] as JsonArray;
        var folders = new List<RemoteFolder>();
        if (array is null)
        {
            throw new InvalidDataException("The host returned no workspace list.");
        }
        array = GeneralFolder.Present(array);
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
                peerLabel,
                folder["git"]?.DeepClone(),
                GeneralFolder.IsGeneral(folder)));
        }
        return folders;
    }

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

    public static void SetAutoConnect(bool on, string peerKey, long? accountGeneration = null)
    {
        lock (Gate)
        {
            if (accountGeneration.HasValue && accountGeneration != AppServices.AccountGeneration) return;
            AdvanceRevisionLocked(peerKey);
            AutoConnect.Set(_accountScope, peerKey, on);
            if (on) Suppressed.Remove(peerKey);
        }
    }

    private static bool IsAutoConnectEnabledLocked(string peerKey)
    {
        return AutoConnect.IsEnabled(_accountScope, peerKey);
    }
}
