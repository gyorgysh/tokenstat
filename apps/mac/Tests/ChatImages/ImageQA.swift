// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI
import UIKit
let fixturePixels: CGImage = {
    let context = CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(UIColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
    context.setFillColor(UIColor.red.cgColor); context.fill(CGRect(x: 290, y: 190, width: 20, height: 20))
    return context.makeImage()!
}()
@main struct ImageQA: App {
    @State var zoom: CGFloat = 1
    @State var page = 0
    var body: some Scene {
        WindowGroup {
            VStack {
                Text("page \(page)").accessibilityIdentifier("page")
                Text("zoom \(zoom, specifier: "%.2f")").accessibilityIdentifier("zoom")
                ChatImageViewport(image: fixturePixels, zoom: $zoom, move: { direction in
                    page = min(2, max(0, page + direction)); zoom = 1
                }).id(page).accessibilityIdentifier("viewport")
                Button("Reset") { zoom = 1 }.accessibilityIdentifier("reset")
            }.padding(16)
        }
    }
}
