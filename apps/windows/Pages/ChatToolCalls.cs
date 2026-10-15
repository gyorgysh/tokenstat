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
    private readonly Dictionary<(string Scope, string Call), ChatToolOwner> _owners = new();
    internal IEnumerable<int> Indices => _owners.Values.Select(owner => owner.Index);
    internal void Clear() => _owners.Clear();
    internal void Remember(string scope, string backend, string call, int index) =>
        _owners[(scope, call)] = new(index, scope, backend);
    internal bool TryResolve(string scope, string call, out ChatToolOwner owner)
    {
        if (_owners.TryGetValue((scope, call), out owner)) return true;
        var matches = _owners.Where(entry => entry.Key.Call == call).Take(2).Select(entry => entry.Value).ToArray();
        if (matches.Length != 1) { owner = default; return false; }
        owner = matches[0];
        return true;
    }
}
