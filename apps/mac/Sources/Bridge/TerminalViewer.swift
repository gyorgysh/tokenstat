// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation

/// Who this front end is, when it tells a host what size terminal it can show.
///
/// A pty has one size and can have two front ends: the Mac that owns the
/// session and a phone attached to it over the tunnel. Neither can be given its
/// own geometry, so instead of one overwriting the other's, each says what *it*
/// can display and the host sizes the session to the smallest of them. That is
/// what makes both correct at the same time, and it is what puts the Mac back
/// to its own width when the phone lets go, because the constraint belongs to
/// the viewer rather than to the session.
///
/// Per launch, not persisted. It only has to be unique among the front ends
/// attached to one session at one moment, and a relaunched app that inherited
/// its old id would look like a viewer that never left. A process that dies
/// without detaching is forgotten by the host's own lease instead.
enum TerminalViewer {
    /// Stable for the lifetime of this process, and different in every other.
    static let id = UUID().uuidString
}
