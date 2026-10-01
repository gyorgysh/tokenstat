// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// The address on the project computer, never a tunnel listener address.
struct BrowserTarget: Codable, Equatable, Hashable, Sendable {
    let url: String

    init?(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 4096,
              text.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        let address: String
        if let port = Self.parsePort(text) {
            address = "http://127.0.0.1:\(port)/"
        } else {
            address = text.contains("://") ? text : "http://\(text)"
        }
        guard var parts = URLComponents(string: address),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host?.lowercased(), Self.isLoopback(host),
              parts.user == nil, parts.password == nil,
              (1...65535).contains(parts.port ?? (scheme == "https" ? 443 : 80)) else { return nil }
        parts.scheme = scheme
        parts.host = host
        if parts.path.isEmpty { parts.path = "/" }
        guard let canonical = parts.string else { return nil }
        url = canonical
    }

    var port: Int { URLComponents(string: url)?.port ?? (url.hasPrefix("https:") ? 443 : 80) }
    var bridgeHost: String {
        let host = URLComponents(string: url)?.host ?? "127.0.0.1"
        if ["localhost", "0.0.0.0"].contains(host) { return "127.0.0.1" }
        return host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    static func parsePort(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }),
              let port = Int(trimmed), (1...65535).contains(port) else { return nil }
        return port
    }

    static func isLoopback(_ raw: String) -> Bool {
        let host = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if ["localhost", "::1", "0.0.0.0"].contains(host) { return true }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count == 4 && labels[0] == "127" && labels.allSatisfy {
            !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber })
                && Int($0).map { (0...255).contains($0) } == true
        }
    }

    func transportURL(through listener: String) -> String? {
        guard var target = URLComponents(string: url), let bridge = URLComponents(string: listener),
              let host = bridge.host, BrowserTarget.isLoopback(host), let port = bridge.port,
              (1...65535).contains(port) else { return nil }
        target.host = host
        target.port = port
        return target.string
    }

    func originalURL(for actual: String, through listener: String) -> String? {
        guard var page = URLComponents(string: actual), let bridge = URLComponents(string: listener),
              page.host?.lowercased() == bridge.host?.lowercased(), page.port == bridge.port,
              ["http", "https"].contains(page.scheme?.lowercased() ?? ""),
              let target = URLComponents(string: url) else { return nil }
        page.scheme = target.scheme
        page.host = target.host
        page.port = target.port
        return page.string
    }
}

/// Device-local suggestions. Opening a field does not write or load a page.
@MainActor
final class BrowserHistory {
    static let shared = BrowserHistory()
    static let capacity = 8
    struct Entry: Codable, Equatable {
        var lastTarget: String?
        var ports: [Int] = []
    }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func key(for owner: WorkReference?) -> String? {
        guard let owner, !owner.hostIdentity.isEmpty, !owner.workspaceID.isEmpty else { return nil }
        return "browser.project.v1." + WorkReferenceKey.folder(scope: owner.scope,
            hostIdentity: owner.hostIdentity, workspaceID: owner.workspaceID)
    }

    func entry(for owner: WorkReference?) -> Entry {
        guard let key = Self.key(for: owner), let data = defaults.data(forKey: key),
              var entry = try? JSONDecoder().decode(Entry.self, from: data) else { return Entry() }
        entry.lastTarget = entry.lastTarget.flatMap { BrowserTarget($0)?.url }
        var seen = Set<Int>()
        entry.ports = Array(entry.ports.filter { (1...65535).contains($0) && seen.insert($0).inserted }.prefix(Self.capacity))
        return entry
    }

    func portSuggestion(for owner: WorkReference?) -> String {
        let saved = entry(for: owner)
        if let last = saved.lastTarget.flatMap(BrowserTarget.init) { return String(last.port) }
        if let port = saved.ports.first { return String(port) }
        // An old global preference is a suggestion only, not a project migration.
        if let legacy = defaults.string(forKey: "browser.lastPort").flatMap(BrowserTarget.parsePort) {
            return String(legacy)
        }
        return "5173"
    }

    func record(_ target: BrowserTarget, for owner: WorkReference?) {
        guard let key = Self.key(for: owner) else { return }
        var value = entry(for: owner)
        value.lastTarget = target.url
        value.ports = Array(([target.port] + value.ports.filter { $0 != target.port }).prefix(Self.capacity))
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    func target(for owner: WorkReference?, port: Int) -> BrowserTarget? {
        if let saved = entry(for: owner).lastTarget.flatMap(BrowserTarget.init), saved.port == port { return saved }
        return BrowserTarget(String(port))
    }
}
