// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI
import UIKit

// Only resource loading is stubbed. The pager, scroll view and geometry are
// shipping sources; synthetic pixels keep gesture tests offline and repeatable.
struct ChatImageResource: Equatable {
    struct Attachment: Equatable { let id: String }
    let attachment: Attachment
}
private let fixturePixels: CGImage = {
    let context = CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(UIColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
    context.setFillColor(UIColor.red.cgColor)
    context.fill(CGRect(x: 290, y: 190, width: 20, height: 20))
    return context.makeImage()!
}()
struct ChatImageSurface: View {
    let resource: ChatImageResource
    var zoom: Binding<CGFloat>?
    var pagesAtFit = false
    var body: some View {
        ChatImageViewport(image: fixturePixels, zoom: zoom ?? .constant(1), move: { _ in }, pagesAtFit: pagesAtFit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
@main struct ImagePagerQA: App {
    @State private var zoom: CGFloat = 1
    @State private var page = 0
    private let images = (0..<3).map { ChatImageResource(attachment: .init(id: "image-\($0)")) }
    var body: some Scene {
        WindowGroup {
            VStack {
                Text("page \(page)").accessibilityIdentifier("page")
                Text("zoom \(zoom, specifier: "%.2f")").monospacedDigit().accessibilityIdentifier("zoom")
                ChatImagePager(resources: images, selection: page, zoom: $zoom,
                    reduceMotion: ProcessInfo.processInfo.arguments.contains("--reduced-motion")) {
                    page = $0; zoom = 1
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier("viewport")
                HStack {
                    Button("Previous") { page = max(0, page - 1); zoom = 1 }.disabled(page == 0)
                    Button("Reset") { zoom = 1 }.accessibilityIdentifier("reset")
                    Button("Next") { page = min(2, page + 1); zoom = 1 }.disabled(page == 2)
                }
            }.padding(16)
        }
    }
}
