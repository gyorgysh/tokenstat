// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

/// An unfilled directory is not evidence that no projects or chats exist.
enum WorkspaceDirectoryPresentation: Equatable {
    case loading, failed, empty, content

    static func resolve(hasContent: Bool, hasLoaded: Bool, isLoading: Bool, error: String?) -> Self {
        if hasContent { return .content }
        if isLoading { return .loading }
        if error != nil { return .failed }
        return hasLoaded ? .empty : .loading
    }
}
