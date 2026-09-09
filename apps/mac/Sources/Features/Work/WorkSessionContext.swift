// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import Observation

/// Unknown account state is distinct from signed-out local work. AccountModel
/// publishes its already-loaded identity here; continuity never fetches an account.
@MainActor @Observable
final class WorkSessionContext {
    static let shared = WorkSessionContext()
    private(set) var scope: WorkReference.Scope?
    private(set) var localHostIdentity: String?
    /// Only saved-page ownership may use this fallback. Live routing continues
    /// to require `scope`, which remains nil until the account answers.
    var readingScope: WorkReference.Scope? { scope ?? savedAccess.reader?.scope }
    private let installationID: String
    private let savedAccess: SavedWorkAccess

    init(defaults: UserDefaults = .standard, savedAccess: SavedWorkAccess? = nil) {
        self.savedAccess = savedAccess ?? .shared
        let key = "work.localInstallation.v1"
        let id = defaults.string(forKey: key) ?? UUID().uuidString
        defaults.set(id, forKey: key)
        installationID = id
    }

    func update(account: Account?) {
        let next: WorkReference.Scope?
        if let account {
            next = account.signedIn
                ? account.handle.flatMap { WorkReference.Scope.account(origin: account.host, handle: $0) }
                : .local(installationID: installationID)
        } else {
            next = nil
        }
        if let account {
            let owner = next.flatMap { scope -> SavedWorkOwner? in
                guard account.signedIn, scope.kind == .account else { return nil }
                let hosts = account.machines.reduce(into: [String: String]()) { result, machine in
                    guard let identity = machine.publicIdentity, !identity.isEmpty else { return }
                    result[identity] = machine.displayName
                }
                return SavedWorkOwner(scope: scope, name: account.title ?? scope.identity, hosts: hosts)
            }
            savedAccess.verified(owner)
        } else {
            savedAccess.accountUnknown()
        }
        if scope != next { scope = next }
    }

    func resolveLocalHostIdentity() async {
        guard localHostIdentity == nil else { return }
        if let identity = try? await Bridge.machineIdentity(), !identity.key.isEmpty {
            localHostIdentity = identity.key
        }
    }
}
