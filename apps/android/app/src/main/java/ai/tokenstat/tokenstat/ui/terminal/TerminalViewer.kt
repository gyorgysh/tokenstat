// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.terminal

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonObjectBuilder
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.util.UUID

/// Who this front end is, when it tells a host what size terminal it can show.
/// Port of `TerminalViewer.swift`.
///
/// A pty has one size and can have two front ends: the Mac that owns the
/// session, and this phone attached to it over the tunnel. Neither can be given
/// its own geometry, so rather than one overwriting the other's, each says what
/// *it* can display and the host sizes the session to the smallest of them.
/// That is what makes both correct at once, and what puts the Mac back to its
/// own width when the phone lets go, because the constraint belongs to the
/// viewer rather than to the session.
///
/// Without an id the host takes its older path and resizes the session
/// outright. That is what collapsed an agent's interface to the phone's width
/// on the Mac as well, and then flapped between the two widths every time
/// either end laid out again: each flip is a SIGWINCH, and a full-screen
/// program repaints on every one, so the transcript filled with half-drawn
/// frames of the last one.
///
/// Per launch, not persisted. It only has to be unique among the front ends
/// attached to one session at one moment, and a relaunched app that inherited
/// its old id would look like a viewer that never left. A process that dies
/// without detaching is forgotten by the host's own lease instead.
object TerminalViewer {
    /// Stable for the lifetime of this process, and different in every other.
    val id: String = UUID.randomUUID().toString()
}

/// Params for a pty call made on behalf of a viewer: `pty.info`, `pty.read`,
/// `pty.resize` and `pty.detach`.
///
/// One builder for all four so the id cannot be left off one of them: the
/// resize takes the lease, the reads are what keep it alive, and the detach is
/// what gives it back. A host too old to know the field declares it and ignores
/// it, behaving exactly as it did before, so nothing here gates on a protocol
/// version.
internal fun ptyViewerParams(
    id: String,
    build: JsonObjectBuilder.() -> Unit = {},
): JsonObject = buildJsonObject {
    put("id", id)
    put("viewer", TerminalViewer.id)
    build()
}
