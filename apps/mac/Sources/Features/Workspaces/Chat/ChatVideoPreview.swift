// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI
import AVFoundation

/// Only a downloaded file is inspected. Opening a transcript never fetches video.
struct ChatVideoPreview: View {
    let file: URL
    @State private var poster: CGImage?
    @State private var duration: String?
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let poster {
                Image(decorative: poster, scale: 1)
                    .resizable().scaledToFit().frame(maxHeight: 240)
            }
            if let duration {
                Text(duration).font(Theme.caption).padding(Theme.Space.xs)
                    .background(Theme.panel.opacity(0.9), in: RoundedRectangle(cornerRadius: 4))
                    .padding(Theme.Space.s)
            }
        }
        .task(id: file) {
            let asset = AVURLAsset(url: file)
            if let time = try? await asset.load(.duration), time.seconds.isFinite, time.seconds > 0 {
                let seconds = Int(min(time.seconds, 86400 * 365))
                duration = String(format: "%d:%02d", seconds / 60, seconds % 60)
            }
            guard !Task.isCancelled else { return }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.maximumSize = CGSize(width: 640, height: 360)
            generator.appliesPreferredTrackTransform = true
            if let image = try? await generator.image(at: .zero), !Task.isCancelled { poster = image.image }
        }
        .accessibilityHidden(true)
    }
}
