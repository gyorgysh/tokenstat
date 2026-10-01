// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
namespace Tokenstat.Pages;

/// <summary>A create acknowledgement clears only the draft that was submitted.</summary>
internal sealed class TaskCreationDraft
{
    public long Revision { get; private set; }
    public void Edited() => Revision++;
    public bool Accepts(long submittedRevision) => Revision == submittedRevision;
}
