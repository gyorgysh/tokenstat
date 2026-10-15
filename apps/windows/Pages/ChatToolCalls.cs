// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
namespace Tokenstat.Pages;

internal readonly record struct ChatToolOwner(int Index, string Scope, string Backend);

/// <summary>
/// Tool starts own their backend metadata. Older archives sometimes stamp an
/// end with the selected backend instead; accept that only when the call has
/// one original owner in this user turn. Clear at every ordinary user message.
/// </summary>
internal sealed class ChatToolCalls
{
    private readonly Dictionary<(string Scope, string Call), List<ChatToolOwner>> _owners = new();
    internal IEnumerable<int> Indices => _owners.Values.SelectMany(owners => owners).Select(owner => owner.Index);
    internal void Clear() => _owners.Clear();
    internal void CloseRunning(List<ChatPage.DisplayItem> items, bool failed, string detail)
    {
        foreach (var index in Indices)
        {
            if (index < 0 || index >= items.Count) continue;
            var tool = items[index];
            // An edit merged into its call's row is still that call.
            if (tool.Kind is not (ChatPage.ItemKind.Tool or ChatPage.ItemKind.Edit) || !tool.Running) continue;
            tool.Running = false;
            tool.Failed = failed;
            if (string.IsNullOrEmpty(tool.Detail) && !string.IsNullOrEmpty(detail)) tool.Detail = detail;
            items[index] = tool;
        }
    }
    internal int Remember(string scope, string backend, string call, int index)
    {
        if (!_owners.TryGetValue((scope, call), out var owners)) _owners[(scope, call)] = owners = [];
        if (owners.All(owner => owner.Index != index)) owners.Add(new(index, scope, backend));
        return owners.Count;
    }
    internal bool TryResolve(string scope, string call, out ChatToolOwner owner, Func<int, bool>? preferRunning = null)
    {
        if (!_owners.TryGetValue((scope, call), out var owners)) {
            var matches = _owners.Where(entry => entry.Key.Call == call).Take(2).Select(entry => entry.Value).ToArray();
            if (matches.Length != 1) { owner = default; return false; }
            owners = matches[0];
        }
        owner = owners[^1];
        if (preferRunning is not null) foreach (var candidate in owners) {
            if (!preferRunning(candidate.Index)) continue;
            owner = candidate; break;
        }
        return true;
    }
}
