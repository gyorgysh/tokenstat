// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with LocalModelsModel.swift and L10n.swift.
import Foundation

struct LocalProvider {
    var id = "lmstudio"
    var port: Int? = 1234
    var baseURL = "http://127.0.0.1:1234/v1"
    var available = true
    var models = ["fixture"]
}
@MainActor enum Bridge {
    static var failSave = false
    static var failProbe = false
    static var savedPort = 1234
    static func setLocalProviderPort(_ id: String, port: Int) async throws {
        if failSave { throw NSError(domain: "fixture", code: 1) }
        savedPort = port
    }
    static func localModels() async throws -> [LocalProvider] {
        if failProbe { throw NSError(domain: "fixture", code: 2) }
        return [LocalProvider(port: savedPort, baseURL: "http://127.0.0.1:\(savedPort)/v1")]
    }
}

@main struct LocalModelsModelTests {
    @MainActor static func main() async throws {
        let model = LocalModelsModel()
        await model.load()
        precondition(model.providers.first?.available == true)
        Bridge.failProbe = true
        do {
            try await model.setPort(8080, for: "lmstudio")
            preconditionFailure("probe failure must explain that the port was saved")
        } catch {
            precondition(error.localizedDescription == L10n.text("common.local_provider_saved_refresh"))
        }
        precondition(Bridge.savedPort == 8080)
        precondition(model.providers.first?.port == 8080)
        precondition(model.providers.first?.baseURL == "http://127.0.0.1:8080/v1")
        precondition(model.providers.first?.available == false && model.providers.first?.models.isEmpty == true)
        precondition(!model.isLoading)
        Bridge.failProbe = false
        await model.load()
        precondition(model.providers.first?.available == true)
        Bridge.failSave = true
        do { try await model.setPort(9090, for: "lmstudio"); preconditionFailure("failed save") }
        catch { precondition(model.providers.first?.port == 8080 && Bridge.savedPort == 8080) }
        precondition(!model.isLoading)
        print("Local models: saved ports survive a failed probe; rejected saves keep previous state")
    }
}
