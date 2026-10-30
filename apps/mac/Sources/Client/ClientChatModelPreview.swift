// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import ModelIO
import SceneKit
import SceneKit.ModelIO
import SwiftUI

/// A small, self-contained model can be inspected without leaving the chat.
/// Model I/O reads USD on Apple devices; the bundled offline renderer handles
/// common game asset exports such as GLB and FBX.
struct ClientChatModelPreview: View {
    let name: String
    let id: String
    let data: Data?
    let file: URL?

    @Environment(\.colorScheme) private var colorScheme
    @State private var scene: SCNScene?
    @State private var camera: SCNNode?
    @State private var failed = false

    private static let inlineByteLimit = 16 * 1024 * 1024
    private var ext: String { (name as NSString).pathExtension.lowercased() }
    private var sourceKey: String { "\(id)|\(file?.path ?? "")|\(data?.count ?? 0)|\(colorScheme)" }

    static func canPreview(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["usdz", "usd", "usda", "usdc", "glb", "gltf", "fbx", "obj", "stl", "ply"].contains(ext)
    }

    var body: some View {
        Group {
            if ["glb", "gltf", "fbx", "obj", "stl", "ply"].contains(ext) {
                ClientChatModelWebView(name: name, data: data, file: file)
                    .id(sourceKey)
            } else {
                Group {
                    if let scene {
                        SceneView(scene: scene, pointOfView: camera,
                            options: [.allowsCameraControl, .autoenablesDefaultLighting])
                            .accessibilityLabel(name)
                    } else if failed {
                        Label(L10n.text("apple.clientchatmodelpreview.unavailable"), systemImage: "cube")
                            .font(Theme.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .task(id: sourceKey) { await load() }
            }
        }
        .frame(height: 260)
        .frame(maxWidth: .infinity)
        .background(Theme.background)
    }

    private func load() async {
        scene = nil
        camera = nil
        failed = false
        guard ["usdz", "usd", "usda", "usdc"].contains(ext), file != nil || data != nil else { failed = true; return }
        let file = file, data = data, id = id, name = name, ext = ext
        let prepared = await Task.detached(priority: .utility) { () -> ModelSceneBox? in
            do {
                let url: URL
                if let file {
                    let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size > 0, size <= Self.inlineByteLimit else { return nil }
                    url = file
                } else if let data, !data.isEmpty, data.count <= Self.inlineByteLimit {
                    url = try ChatFileStaging.stage(data, id: id, name: name)
                } else { return nil }
                guard MDLAsset.canImportFileExtension(ext) else { return nil }
                let model = MDLAsset(url: url)
                guard model.count > 0 else { return nil }
                return ModelSceneBox(scene: SCNScene(mdlAsset: model))
            } catch { return nil }
        }.value
        guard !Task.isCancelled else { return }
        guard let prepared else { failed = true; return }
        let model = prepared.scene
        #if os(macOS)
        model.background.contents = NSColor(Theme.background)
        #else
        model.background.contents = UIColor(Theme.background)
        #endif
        let bounds = model.rootNode.boundingBox
        let center = SCNVector3(
            (bounds.min.x + bounds.max.x) / 2,
            (bounds.min.y + bounds.max.y) / 2,
            (bounds.min.z + bounds.max.z) / 2
        )
        let span = max(0.01, bounds.max.x - bounds.min.x,
            bounds.max.y - bounds.min.y, bounds.max.z - bounds.min.z)
        let view = SCNNode()
        view.camera = SCNCamera()
        view.camera?.zNear = 0.001
        view.camera?.zFar = max(100, Double(span * 100))
        view.position = SCNVector3(center.x, center.y, center.z + span * 2.8)
        view.look(at: center)
        model.rootNode.addChildNode(view)
        camera = view
        scene = model
    }
}

/// SceneKit objects are created on a detached task and handed to the main
/// actor exactly once. No task mutates the scene after this handoff.
private struct ModelSceneBox: @unchecked Sendable {
    let scene: SCNScene
}
