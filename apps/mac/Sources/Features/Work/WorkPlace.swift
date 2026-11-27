// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

struct WorkPlace: Codable, Equatable, Sendable {
    var globalSection: String?
    var folder: WorkReference?
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

    var isWellFormed: Bool {
        if let globalSection {
            return !globalSection.isEmpty && folder == nil && folderSection == nil
        }
        guard let folder, let folderSection else { return false }
        return folder.kind == .workspace && !folder.hostIdentity.isEmpty
            && !folder.workspaceID.isEmpty && !folderSection.isEmpty
    }
}

enum WorkPlaceRestoration {
    enum Destination: Equatable, Sendable {
        case global(section: String)
        case workspace(folderID: String, section: String)
    }

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

@MainActor
enum WorkPlaceLaunch {
    private static var claimed = false

    static func claim() -> Bool {
        guard !claimed else { return false }
        claimed = true
        return true
    }

    static func resetForTesting() { claimed = false }
}
