// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// The screen the shell was last pointed at, so a relaunch lands where the
/// work was left rather than on Home.
///
/// Identifiers only, like every other continuity record: a folder is named by
/// the machine that owns it and that machine's own id for it, never by the
/// route string one shell happened to build for it. The route string is
/// rebuilt from the folder list at restore time, which is also what stops a
/// folder that has since been removed from being reopened.
struct WorkPlace: Codable, Equatable, Sendable {
    /// A machine-wide screen, by `GlobalSection` raw value. Set when the shell
    /// was not inside a folder.
    var globalSection: String?
    /// The folder, when it was. `kind` is always `.workspace`.
    var folder: WorkReference?
    /// That folder's section, by `WorkspaceSection` raw value.
    var folderSection: String?
    var savedAt: Date

    static func global(_ section: String, at date: Date = Date()) -> Self {
        Self(globalSection: section, savedAt: date)
    }

    static func workspace(_ folder: WorkReference, section: String,
                          at date: Date = Date()) -> Self? {
        guard folder.kind == .workspace, !folder.hostIdentity.isEmpty,
              !folder.workspaceID.isEmpty, !section.isEmpty else { return nil }
        return Self(folder: folder, folderSection: section, savedAt: date)
    }

    /// Exactly one of the two shapes, and nothing half filled in.
    var isWellFormed: Bool {
        if let globalSection {
            return !globalSection.isEmpty && folder == nil && folderSection == nil
        }
        guard let folder, let folderSection else { return false }
        return folder.kind == .workspace && !folder.hostIdentity.isEmpty
            && !folder.workspaceID.isEmpty && !folderSection.isEmpty
    }
}

/// What to open at launch, decided from stored identifiers and the folders
/// this machine can actually see right now.
///
/// Pure, and deliberately so: the rule that decides whether somebody's last
/// folder may be reopened is worth a test that needs no window.
enum WorkPlaceRestoration {
    /// A route, in the vocabulary the shells already use.
    enum Destination: Equatable, Sendable {
        case global(section: String)
        case workspace(folderID: String, section: String)
    }

    /// The folder id this shell knows the reference by, or nil when no folder
    /// in the list is that folder.
    ///
    /// Local ids are the host's own; a folder on another machine is
    /// `remote:<peer>:<id>`. Matching by resolving both sides means a peer key
    /// that is written differently in one place cannot open the wrong folder.
    static func folderID(for reference: WorkReference, among ids: [String],
                         localHostIdentity: String?) -> String? {
        ids.first { id in
            let route = WorkDestinationResolver.route(folderID: id)
            guard route.workspaceID == reference.workspaceID else { return false }
            if let peer = route.peer { return peer == reference.hostIdentity }
            guard let localHostIdentity, !localHostIdentity.isEmpty else { return false }
            return localHostIdentity == reference.hostIdentity
        }
    }

    /// Where to land, or nil to stay on the default screen.
    ///
    /// A folder on **another machine** is account content, so its scope has to
    /// be the scope that stored it. A folder on **this** machine is this
    /// machine's own registration, visible to whoever is at the keyboard
    /// whether or not anyone is signed in, so it reopens without waiting for
    /// an account to load. What is inside it stays scoped by the models that
    /// read it.
    static func destination(place: WorkPlace?, folderIDs: [String],
                            scope: WorkReference.Scope?,
                            localHostIdentity: String?) -> Destination? {
        guard let place, place.isWellFormed else { return nil }
        if let section = place.globalSection { return .global(section: section) }
        guard let folder = place.folder, let section = place.folderSection,
              let id = folderID(for: folder, among: folderIDs,
                                localHostIdentity: localHostIdentity) else { return nil }
        let isRemote = WorkDestinationResolver.route(folderID: id).peer != nil
        if isRemote, scope != folder.scope { return nil }
        return .workspace(folderID: id, section: section)
    }
}

/// One restoration per process.
///
/// A second window is somewhere else to work, not a copy of the one already
/// open, so it starts on Home. Both windows still write where they are: the
/// record answers "where was I", and the last window to move holds the answer.
@MainActor
enum WorkPlaceLaunch {
    private static var claimed = false

    static func claim() -> Bool {
        guard !claimed else { return false }
        claimed = true
        return true
    }

    /// Tests run more than one launch in a process.
    static func resetForTesting() { claimed = false }
}
