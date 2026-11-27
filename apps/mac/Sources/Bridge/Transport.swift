// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Darwin
import Foundation
import TokenstatFFI

protocol Transport: Sendable {
    func call(method: String, params: String, patience: TimeInterval) throws -> String

    func callUrgent(method: String, params: String, patience: TimeInterval) throws -> String

    var describedAs: String { get }
}

extension Transport {
    func callUrgent(method: String, params: String, patience: TimeInterval) throws -> String {
        try call(method: method, params: params, patience: patience)
    }
}

struct InProcessTransport: Transport {
    var describedAs: String { "in-process" }

    static var protocolVersion: String {
        guard let raw = tokenstat_ffi_protocol_version() else { return "" }
        return String(cString: raw)
    }

    func call(method: String, params: String, patience _: TimeInterval) throws -> String {
        guard let raw = tokenstat_ffi_call(method, params) else {
            throw BridgeError.core(code: "null", message: L10n.text("apple.transport.the_core_returned_nothing.d880260c"))
        }
        defer { tokenstat_ffi_string_free(raw) }
        return String(cString: raw)
    }
}
