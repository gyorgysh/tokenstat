// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// One decoded profile picture per URL, for the life of the process.
///
/// Exists because the picture must be a plain `Image` by the time it reaches
/// the layout (see `Avatar`), and because the same face is drawn on Home, in
/// the sidebar footer, and on the Account screen: fetching it three times to
/// show it three times is a request nobody asked for.
///
/// The store is an `NSCache` with count and size limits, so a session that
/// looks at a hundred people gives the bitmaps back under pressure instead of
/// holding every face it has ever seen. Fetching and decoding both happen off
/// the main actor: only the finished `Image` comes back to it.
@MainActor
final class AvatarCache {
    static let shared = AvatarCache()

    private final class Held {
        let image: Image
        init(_ image: Image) { self.image = image }
    }

    private let decoded = NSCache<NSString, Held>()
    /// In flight fetches, so three `Avatar` views for one account share a
    /// single request instead of racing each other.
    private var pending: [String: Task<AvatarFetch.Outcome, Never>] = [:]

    init() {
        decoded.countLimit = 128
        // Count decoded pixel storage rather than compressed downloads.
        decoded.totalCostLimit = 64 * 1024 * 1024
    }

    /// Already decoded, or nil. Synchronous so the first frame can paint the
    /// picture instead of the letter when it is a cache hit.
    func cached(_ url: String) -> Image? {
        decoded.object(forKey: url as NSString)?.image
    }

    /// The picture, asked for again while it cannot be reached.
    ///
    /// One timeout used to leave the letter on screen until something rebuilt
    /// the view. A picture that is not there (a 404, not an image) stops at
    /// once. One that could not be reached waits and tries again, backing off
    /// to every thirty seconds, for as long as the caller's task runs. The
    /// view's own task ends it when the view goes, so nothing polls for a
    /// face nobody is looking at.
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

/// Fetching and decoding one avatar, away from the main actor.
///
/// The download streams to a temporary file, so a body larger than the cap is
/// rejected by its size before any of it is read into memory and decoded.
private enum AvatarFetch {
    /// Avatars are small uploads. Four megabytes is already absurd; more than
    /// that is a response doing something other than showing a face.
    static let byteLimit = 4 * 1024 * 1024

    /// Errors that say the URL itself is the problem, not the network.
    static let permanentFailures: Set<URLError.Code> = [
        .badURL,
        .unsupportedURL,
        .appTransportSecurityRequiresSecureConnection,
        .fileDoesNotExist,
        .noPermissionsToReadFile,
        .dataLengthExceedsMaximum,
        // A certificate the host cannot prove, or a login it wants. Asking
        // again gets the same answer.
        .serverCertificateUntrusted,
        .serverCertificateHasBadDate,
        .serverCertificateNotYetValid,
        .serverCertificateHasUnknownRoot,
        .clientCertificateRejected,
        .clientCertificateRequired,
        .userAuthenticationRequired,
    ]

    /// A picture, no picture, or no answer. Only the last is worth asking
    /// again: a 404 or a body that is not an image will say the same thing.
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
            // A URL this device will never load. Asking again every thirty
            // seconds for as long as the face is on screen changes nothing.
            return .missing
        } catch {
            return .unreachable
        }
        let (file, response) = fetched
        defer { try? FileManager.default.removeItem(at: file) }
        // A 404 body is not a picture. Treating any bytes as an image is
        // how a missing upload became a random face.
        if let http = response as? HTTPURLResponse {
            // Busy, rate limited or failing on the server's side: the same
            // request can succeed in a moment.
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
    /// The name the person is shown as. Initials come from this first, then
    /// `handle`, matching the website's `initials()`.
    var name: String? = nil
    var handle: String?
    var size: CGFloat = 22
    /// Colour of the bubble when this is not the signed-in account. Left at
    /// the app's accent for our own picture. A per-person colour where
    /// several people appear in one list, so a row is recognisable before
    /// the name is read.
    var tint: Color = Theme.accent

    /// The fetched picture, once it has arrived.
    ///
    /// This is *not* what the first frame reads: a `.task` runs after that
    /// frame, and a fresh view with empty state is the common case wherever a
    /// toolbar or a list rebuilds its rows. `displayImage` reads the shared
    /// cache synchronously, so a picture fetched once paints immediately on
    /// every later view instead of flashing the letter tile again.
    @State private var image: Image?
    @State private var imageURL: String?

    /// A stable colour for a person, from the app's own ramp.
    ///
    /// Hashed over the bytes rather than with `hashValue`, which is seeded per
    /// process: the same author would get a different colour on every launch,
    /// and a mark that moves is not a mark.
    ///
    /// The ramp's first two steps are left out. They are the heatmap's "quiet
    /// day" greys, and a letter in one of them is a letter nobody can read.
    static func tint(for identity: String) -> Color {
        let palette = Theme.heat.dropFirst(2) + [Theme.warning, Theme.danger]
        var hash: UInt64 = 5381
        for byte in identity.lowercased().utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        return Array(palette)[Int(hash % UInt64(palette.count))]
    }

    /// One or two letters, uppercased, from a display name or a handle.
    ///
    /// First letter of the first two words, the same function the website
    /// uses. A name that begins with an emoji or a non-Latin script keeps
    /// its own first character.
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
                    // Under the photo, so a slow or failed load still shows
                    // the letters rather than a hole.
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
            // Refuse growth when a parent (Menu label) offers more space.
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
                // The task id is the URL so a change cancels this run, but the
                // fetch is detached and deduped and can still resume late: only
                // land while this URL is still the one on show, so a slow face
                // for the previous row cannot cover the new one.
                guard !Task.isCancelled, pictureURL == url else { return }
                image = loaded
                imageURL = url
            }
    }

    /// Only a real upload URL is fetched. Empty and blank are "no picture".
    private var pictureURL: String? {
        guard let raw = url?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        return raw
    }

    /// The fetched picture when one is on hand: this view's own image first,
    /// then the shared cache, read synchronously so the first frame already
    /// has it.
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

    /// The signed-in account uses the same two-stop fill as the phone's
    /// toolbar bubble. A per-person tint stays that person's colour.
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
