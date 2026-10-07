// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import Observation

@MainActor protocol SSHRetainedDraft: AnyObject {
    var active: Bool { get }
    func retire()
}

/// Editors are retained with their library, above the phone's layout choice.
/// Explicit completion or account retirement clears their private input.
@MainActor final class SSHLibraryDraftStore {
    private var values: [SSHLibraryRoute: any SSHRetainedDraft] = [:]
    func draft<T: SSHRetainedDraft>(for route: SSHLibraryRoute, make: () -> T) -> T {
        if let value = values[route] as? T { return value }
        let value = make(); values[route] = value; return value
    }
    func remove(_ route: SSHLibraryRoute) { values.removeValue(forKey: route)?.retire() }
    func retireAll() {
        for value in values.values { value.retire() }
        values.removeAll()
    }
}

@MainActor @Observable
final class SSHHostDraft: SSHRetainedDraft {
    var active = true
    var host = SSHHost(
        id: "", label: "", hostname: "", port: 22, username: "root",
        initialDirectory: "~", credentialID: nil, jumpHostID: nil,
        tags: [], provider: nil, hostKeys: []
    )
    var loaded = false
    var working = false
    var error: String?
    var confirmingDelete = false
    var newEnvName = ""
    var newEnvValue = ""

    func retire() { active = false; working = false;  }
}

@MainActor @Observable
final class SSHKeyDraft: SSHRetainedDraft {
    var active = true
    var label = L10n.text("apple.sshlibraryeditors.my_ssh_key.127c1dd4")
    var pem = ""
    var passphrase = ""
    var record: SSHKeyRecord?
    var loaded = false
    var working = false
    var error: String?
    var copied = false
    var confirmingDelete = false
    var algorithm = SSHKeyAlgorithm.ed25519

    func retire() { active = false; working = false; pem = ""; passphrase = ""; }
}

@MainActor @Observable
final class SSHSnippetDraft: SSHRetainedDraft {
    var active = true
    var snippet = SSHSnippet(id: "", title: "", command: "", tags: [], hostIDs: [])
    var loaded = false
    var working = false
    var error: String?
    var confirmingDelete = false

    func retire() { active = false; working = false;  }
}

@MainActor @Observable
final class SSHFolderDraft: SSHRetainedDraft {
    var active = true
    var folder = SSHFolder(id: "", name: "", parentID: nil, color: nil)
    var loaded = false
    var working = false
    var error: String?
    var confirmingDelete = false

    func retire() { active = false; working = false;  }
}

@MainActor @Observable
final class SSHConfigDraft: SSHRetainedDraft {
    var active = true
    var candidates: [SSHConfigCandidate] = []
    var loading = true
    var working = false
    var imported: SSHConfigImport?
    var error: String?

    func retire() { active = false; working = false;  }
}

enum SSHCloudProvider: String, CaseIterable { case digitalOcean = "DigitalOcean", aws = "AWS" }

@MainActor @Observable
final class SSHCloudDraft: SSHRetainedDraft {
    var active = true
    var token = ""
    var username = "root"
    var provider = SSHCloudProvider.digitalOcean
    var profile = "default"
    var region = ""
    var error: String?
    var importing = false
    var importedCount: Int?
    func retire() { active = false; importing = false; token = "" }
}
