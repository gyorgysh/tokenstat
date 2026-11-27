// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
namespace Tokenstat.Pages;

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
