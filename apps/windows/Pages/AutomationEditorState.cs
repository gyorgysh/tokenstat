// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
namespace Tokenstat.Pages;

/// <summary>A clean refresh replaces the saved payload and its revision together.</summary>
internal sealed class AutomationEditorState<T> where T : class
{
    public T? Draft { get; set; }
    public ulong? Revision { get; set; }
    public void Refresh(T saved, ulong? revision, bool dirty)
    {
        if (dirty) return;
        Draft = saved;
        Revision = revision;
    }
}
