// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Distribution of builds is reserved. See LICENSE for terms.
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
