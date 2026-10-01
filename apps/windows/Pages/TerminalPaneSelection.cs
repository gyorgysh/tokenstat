// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
namespace Tokenstat.Pages;

/// <summary>Stable terminal IDs keep transport, focus and split positions independent.</summary>
internal sealed class TerminalPaneSelection
{
    public string? Selected { get; set; }
    public string? Leading { get; set; }
    public string? Trailing { get; set; }
    public string? Active(IReadOnlyList<string> available) => Selected is not null && available.Contains(Selected) ? Selected : available.FirstOrDefault();
    public (string? Leading, string? Trailing) Panes(IReadOnlyList<string> available, bool split)
    {
        if (!split) return (Active(available), null);
        var trail = Trailing is not null && available.Contains(Trailing) ? Trailing : null;
        var lead = Leading is not null && available.Contains(Leading) ? Leading
            : available.FirstOrDefault(id => id == Active(available) && id != trail)
                ?? available.FirstOrDefault(id => id != trail) ?? Active(available);
        return (lead, trail == lead ? null : trail);
    }
    public void SetSplit(bool split, IReadOnlyList<string> available)
    {
        if (!split) { Leading = Trailing = null; return; }
        var panes = Panes(available, true);
        Leading = panes.Leading;
        Trailing = panes.Trailing ?? available.FirstOrDefault(id => id != Leading);
    }
    public void Select(string id, IReadOnlyList<string> available, bool split)
    {
        if (!available.Contains(id)) return;
        if (split)
        {
            var panes = Panes(available, true);
            if (id != panes.Leading && id != panes.Trailing)
            {
                if (panes.Trailing is null && panes.Leading is not null) { Leading = panes.Leading; Trailing = id; }
                else if (Active(available) == panes.Trailing) Trailing = id;
                else Leading = id;
            }
        }
        Selected = id;
    }
    public void SendToOtherHalf(string id, IReadOnlyList<string> available)
    {
        if (!available.Contains(id) || id == Active(available)) return;
        var panes = Panes(available, true);
        if (id == panes.Leading || id == panes.Trailing) Selected = id;
        else if (Active(available) == panes.Leading) Trailing = id;
        else Leading = id;
    }
    public void Swap(IReadOnlyList<string> available)
    {
        var panes = Panes(available, true);
        if (panes.Leading is null || panes.Trailing is null) return;
        Leading = panes.Trailing;
        Trailing = panes.Leading;
    }
    public bool Reconcile(IReadOnlyList<string> available)
    {
        var lostLead = Leading is not null && !available.Contains(Leading);
        var lostTrail = Trailing is not null && !available.Contains(Trailing);
        if (lostLead || lostTrail) { Selected = lostLead ? Trailing : Leading; Leading = Trailing = null; }
        Selected = Active(available);
        return lostLead || lostTrail;
    }
    public void Rename(string oldId, string id)
    {
        if (Selected == oldId) Selected = id;
        if (Leading == oldId) Leading = id;
        if (Trailing == oldId) Trailing = id;
    }
}
