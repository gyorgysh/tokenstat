// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
namespace Tokenstat.Pages;

internal sealed class TaskCreationDraft
{
    public long Revision { get; private set; }
    public void Edited() => Revision++;
    public bool Accepts(long submittedRevision) => Revision == submittedRevision;
}
