// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if os(macOS)
import MetalKit
import IOSurface

/// IOSurface textures stay on the GPU. A CALayer does not render an IOSurface
/// assigned to contents, so use a small native Metal pass with no pixel copies.
@MainActor
final class SimulatorMetalRenderer: NSObject, MTKViewDelegate {
    private struct Pipeline {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let state: MTLRenderPipelineState
    }
    private static let pipeline: Pipeline? = {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: shader, options: nil),
              let vertex = library.makeFunction(name: "simulatorVertex"),
              let fragment = library.makeFunction(name: "simulatorFragment") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex; descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let state = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        return Pipeline(device: device, queue: queue, state: state)
    }()
    let view: MTKView
    private var texture: MTLTexture?
    private var surfaceID: IOSurfaceID = 0
    private var orientation: UInt32 = 1
    private var backing: Any?
    private let capacity = DispatchSemaphore(value: 2)
    private var pendingDraw = false

    override init() {
        view = MTKView(frame: .zero, device: Self.pipeline?.device)
        super.init()
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.isPaused = true; view.enableSetNeedsDisplay = true
        view.delegate = self
    }
    var isAvailable: Bool { Self.pipeline != nil }

    func present(_ surface: IOSurface, orientation: Int, backing: Any? = nil) {
        self.backing = backing
        self.orientation = UInt32(max(1, min(4, orientation)))
        let id = IOSurfaceGetID(surface)
        if surfaceID != id || texture?.width != IOSurfaceGetWidth(surface) || texture?.height != IOSurfaceGetHeight(surface) {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: IOSurfaceGetWidth(surface), height: IOSurfaceGetHeight(surface), mipmapped: false)
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
            texture = Self.pipeline?.device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0)
            surfaceID = id
        }
        view.needsDisplay = true
    }
    func clear() { texture = nil; backing = nil; surfaceID = 0; view.needsDisplay = true }
    func redraw() {
        guard view.window != nil, !view.bounds.isEmpty else { return }
        view.needsDisplay = true
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { view.needsDisplay = true }
    func draw(in view: MTKView) {
        guard let pipeline = Self.pipeline else { return }
        guard capacity.wait(timeout: .now()) == .success else { pendingDraw = true; return }
        pendingDraw = false
        let pass = view.currentRenderPassDescriptor, drawable = view.currentDrawable
        guard let pass, let drawable,
              let command = pipeline.queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            capacity.signal(); return
        }
        if let texture {
            let displayed = SimulatorGeometry.displaySize(pixels: CGSize(width: texture.width, height: texture.height), orientation: Int(orientation))
            let scale = min(view.drawableSize.width / displayed.width, view.drawableSize.height / displayed.height)
            var fit = SIMD2<Float>(Float(displayed.width * scale / max(1, view.drawableSize.width)),
                                   Float(displayed.height * scale / max(1, view.drawableSize.height)))
            var turn = orientation
            encoder.setRenderPipelineState(pipeline.state)
            encoder.setVertexBytes(&fit, length: MemoryLayout.size(ofValue: fit), index: 0)
            encoder.setVertexBytes(&turn, length: MemoryLayout.size(ofValue: turn), index: 1)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        command.present(drawable)
        let capacity = capacity
        let backing = backing
        command.addCompletedHandler { [weak self] _ in
            withExtendedLifetime(backing) { _ = capacity.signal() }
            DispatchQueue.main.async { [weak self] in
                if self?.pendingDraw == true { self?.view.needsDisplay = true }
            }
        }
        command.commit()
    }
    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct SimulatorPixel { float4 position [[position]]; float2 uv; };
    vertex SimulatorPixel simulatorVertex(uint i [[vertex_id]], constant float2 &fit [[buffer(0)]], constant uint &turn [[buffer(1)]]) {
        float2 p = float2((i & 1) ? 1.0 : -1.0, (i & 2) ? -1.0 : 1.0);
        float2 uv = float2((p.x + 1.0) / 2.0, (1.0 - p.y) / 2.0);
        if (turn == 2) uv = 1.0 - uv;
        else if (turn == 3) uv = float2(uv.y, 1.0 - uv.x);
        else if (turn == 4) uv = float2(1.0 - uv.y, uv.x);
        return {float4(p * fit, 0.0, 1.0), uv};
    }
    fragment float4 simulatorFragment(SimulatorPixel in [[stage_in]], texture2d<float> screen [[texture(0)]]) {
        constexpr sampler sampling(filter::linear, address::clamp_to_edge);
        return screen.sample(sampling, in.uv);
    }
    """
}
#endif
