// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

namespace Tokenstat.Pages;

/// <summary>
/// Who this front end is when it tells a host what size terminal it can
/// show. Mirrors the Apple TerminalViewer: the host sizes a session to the
/// smallest of its viewers, and dropping this id on detach hands the other
/// viewers their own width back at once. Per launch, not persisted, so a
/// relaunched app never looks like a viewer that never left.
/// </summary>
internal static class TerminalViewer
{
    public static readonly string Id = Guid.NewGuid().ToString("N");
}
