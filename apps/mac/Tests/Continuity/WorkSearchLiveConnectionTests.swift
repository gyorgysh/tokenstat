// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
@main struct WorkSearchLiveConnectionTests {
    @MainActor static func main() async throws {
        let scope = WorkReference.Scope.local(installationID:"client")
        for stop in ["access", "version", "search", "none"] {
            var current = true
            var calls: [String] = []
            let connection = WorkSearchLiveConnection(host:"host",scope:scope,transport:.init(
                allowed: { calls.append("access"); if stop == "access" { current=false }; return true },
                version: { calls.append("version"); if stop == "version" { current=false }; return 12 },
                search: { _,_,_ in
                    calls.append("search"); if stop == "search" { current=false }
                    return .init(hits:[],nextCursor:nil,coverage:.init(searched:0,unreadable:0,partial:false))
                }), ownsSession:{ current })
            do {
                _ = try await connection.search(query:"layout")
                assert(stop == "none")
            } catch is CancellationError { assert(stop != "none") }
            let expected = stop == "access" ? 1 : stop == "version" ? 2 : 3
            assert(calls.count == expected)
            connection.close()
            do { _ = try await connection.search(query:"layout"); fatalError("closed connection") } catch is CancellationError {}
            assert(calls.count == expected)
        }
        for allowed in [false,true] {
            var searches=0
            let connection=WorkSearchLiveConnection(host:"host",scope:scope,transport:.init(
                allowed:{allowed},version:{11},search:{_,_,_ in searches += 1; fatalError("unavailable host searched")}),ownsSession:{true})
            do { _ = try await connection.search(query:"layout"); fatalError("unsupported host") }
            catch is WorkSearchLiveConnection.Unavailable {}
            assert(searches == 0)
        }
        let cancelled = Task { @MainActor in
            let connection = WorkSearchLiveConnection(host:"host", scope:scope, transport:.init(
                allowed:{ withUnsafeCurrentTask { $0?.cancel() }; return true },
                version:{ fatalError("cancelled request probed protocol") },
                search:{_,_,_ in fatalError("cancelled request searched")}), ownsSession:{true})
            do { _ = try await connection.search(query:"layout"); fatalError("cancelled request accepted") }
            catch is CancellationError {}
        }
        try await cancelled.value
        let repeated = WorkSearchLiveConnection(host:"host",scope:scope,transport:.init(
            allowed:{true},version:{12},search:{_,_,_ in
                .init(hits:[],nextCursor:"same",coverage:.init(searched:0,unreadable:0,partial:false))
            }),ownsSession:{true})
        do { _ = try await repeated.search(query:"layout",cursor:"same"); fatalError("nonadvancing cursor") }
        catch WorkSearchLive.Invalid.response {}
        print("Live search connection: owner changes after every await, close, refusal and old host passed")
    }
}
