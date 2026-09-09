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
    private let installationID: String

    private init() {
        let key = "work.localInstallation.v1"
        let id = UserDefaults.standard.string(forKey: key) ?? UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
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
        if scope != next { scope = next }
    }

    func resolveLocalHostIdentity() async {
        guard localHostIdentity == nil else { return }
        if let identity = try? await Bridge.machineIdentity(), !identity.key.isEmpty {
            localHostIdentity = identity.key
        }
    }
}
