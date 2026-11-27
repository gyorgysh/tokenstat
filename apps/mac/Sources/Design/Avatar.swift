// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class AvatarCache {
    static let shared = AvatarCache()

    private final class Held {
        let image: Image
        init(_ image: Image) { self.image = image }
    }

    private let decoded = NSCache<NSString, Held>()
    private var pending: [String: Task<AvatarFetch.Outcome, Never>] = [:]

    init() {
        decoded.countLimit = 128
        decoded.totalCostLimit = 64 * 1024 * 1024
    }

    func cached(_ url: String) -> Image? {
        decoded.object(forKey: url as NSString)?.image
    }

    func image(for url: String) async -> Image? {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }
        var wait: Duration = .seconds(2)
        while !Task.isCancelled {
            switch await attempt(url) {
            case .image(let image, _):
                return image
            case .missing:
                return nil
            case .unreachable:
                try? await Task.sleep(for: wait)
                wait = min(wait * 2, .seconds(30))
            }
        }
        return nil
    }

    private func attempt(_ url: String) async -> AvatarFetch.Outcome {
        if let hit = decoded.object(forKey: url as NSString) { return .image(hit.image, bytes: 0) }
        if let running = pending[url] { return await running.value }

        let task = Task.detached(priority: .utility) {
            await AvatarFetch.image(from: url)
        }
        pending[url] = task
        let outcome = await task.value
        pending[url] = nil
        if case .image(let image, let bytes) = outcome {
            decoded.setObject(Held(image), forKey: url as NSString, cost: bytes)
        }
        return outcome
    }
}

private enum AvatarFetch {
    static let byteLimit = 4 * 1024 * 1024

    static let permanentFailures: Set<URLError.Code> = [
        .badURL,
        .unsupportedURL,
        .appTransportSecurityRequiresSecureConnection,
        .fileDoesNotExist,
        .noPermissionsToReadFile,
        .dataLengthExceedsMaximum,
        .serverCertificateUntrusted,
        .serverCertificateHasBadDate,
        .serverCertificateNotYetValid,
        .serverCertificateHasUnknownRoot,
        .clientCertificateRejected,
        .clientCertificateRequired,
        .userAuthenticationRequired,
    ]

    enum Outcome {
        case image(Image, bytes: Int)
        case missing
        case unreachable
    }

    static func image(from url: String) async -> Outcome {
        guard let parsed = URL(string: url) else { return .missing }
        var request = URLRequest(url: parsed)
        request.timeoutInterval = 15
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let fetched: (URL, URLResponse)
        do {
            fetched = try await URLSession.shared.download(for: request)
        } catch let error as URLError where permanentFailures.contains(error.code) {
            return .missing
        } catch {
            return .unreachable
        }
        let (file, response) = fetched
        defer { try? FileManager.default.removeItem(at: file) }
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 408 || http.statusCode == 429 || http.statusCode >= 500 {
                return .unreachable
            }
            guard (200..<300).contains(http.statusCode) else { return .missing }
            guard http.expectedContentLength <= Int64(byteLimit) else { return .missing }
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size > 0, size <= byteLimit,
              let data = try? Data(contentsOf: file, options: .mappedIfSafe)
        else {
            return .missing
        }
        guard let thumbnail = AvatarImageDecode.thumbnail(data) else { return .missing }
        let decodedBytes = thumbnail.bytesPerRow * thumbnail.height
        #if os(macOS)
        let image = NSImage(cgImage: thumbnail, size: .zero)
        return .image(Image(nsImage: image), bytes: decodedBytes)
        #else
        let image = UIImage(cgImage: thumbnail)
        return .image(Image(uiImage: image), bytes: decodedBytes)
        #endif
    }
}

/// The account's profile picture, or initials when there is none.
///
/// Same rule as the website and the phone toolbar. A real upload is the
/// picture. A missing one is letters from the display name, first letter
/// of the first two words, on a filled bubble.
///
/// **Not `AsyncImage`.** That view reports the *remote pixel size* as its own
/// ideal size, so any parent that asks a child what it would like rather than
/// proposing a size is handed a photograph where a 22 point circle was asked
/// for. `safeAreaInset` and a `Menu` label are both such parents, and this
/// picture is drawn inside a `safeAreaInset` at the foot of the sidebar. A
/// plain `Image` built from an already decoded bitmap has no such opinion:
/// `.resizable()` takes whatever size it is handed, and the fixed clear host
/// below owns the geometry outright.
///
/// The full-width photograph that used to fill the sidebar footer was a
/// separate fault, in how a macOS `Menu` rebuilds a custom label. That is
/// fixed where it happened, in `RootView.accountRow`.
struct Avatar: View {
    var url: String?
    var name: String? = nil
    var handle: String?
    var size: CGFloat = 22
    var tint: Color = Theme.accent

    @State private var image: Image?
    @State private var imageURL: String?

    static func tint(for identity: String) -> Color {
        let palette = Theme.heat.dropFirst(2) + [Theme.warning, Theme.danger]
        var hash: UInt64 = 5381
        for byte in identity.lowercased().utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        return Array(palette)[Int(hash % UInt64(palette.count))]
    }

    static func initials(from name: String?) -> String? {
        let parts = (name ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .filter { !$0.isEmpty }
        guard let first = parts.first, let ch = first.first else { return nil }
        var letters = String(ch)
        if parts.count > 1, let second = parts[1].first {
            letters.append(second)
        }
        return letters.uppercased()
    }

    var body: some View {
        Color.clear
            .frame(width: size, height: size)
            .overlay {
                ZStack {
                    bubble
                    letter
                    if let picture = displayImage {
                        picture
                            .resizable()
                            .scaledToFill()
                    }
                }
            }
            .clipShape(Circle())
            .contentShape(Circle())
            .fixedSize()
            .task(id: pictureURL) {
                guard let url = pictureURL else {
                    image = nil
                    return
                }
                if let hit = AvatarCache.shared.cached(url) {
                    image = hit
                    imageURL = url
                    return
                }
                image = nil
                let loaded = await AvatarCache.shared.image(for: url)
                guard !Task.isCancelled, pictureURL == url else { return }
                image = loaded
                imageURL = url
            }
    }

    private var pictureURL: String? {
        guard let raw = url?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        return raw
    }

    private var displayImage: Image? {
        guard let url = pictureURL else { return nil }
        if imageURL == url, let image { return image }
        return AvatarCache.shared.cached(url)
    }

    private var bubble: some View {
        Circle().fill(
            LinearGradient(
                colors: brandGradient
                    ? [Theme.accent, Theme.secondary]
                    : [tint, tint.opacity(0.72)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var brandGradient: Bool { tint == Theme.accent }

    private var monogram: String {
        Self.initials(from: name) ?? Self.initials(from: handle) ?? ""
    }

    @ViewBuilder
    private var letter: some View {
        if monogram.isEmpty {
            Image(systemName: "person.fill")
                .font(Theme.fixed(size * 0.44, weight: .medium))
                .foregroundStyle(.white)
        } else {
            Text(monogram)
                .font(Theme.fixed(
                    size * (monogram.count > 1 ? 0.34 : 0.42),
                    weight: .semibold
                ))
                .foregroundStyle(.white)
        }
    }
}
