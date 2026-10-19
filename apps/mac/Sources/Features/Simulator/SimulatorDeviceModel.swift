// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if os(macOS)
import SwiftUI
import MetalKit
import IOSurface
import simd

struct SimulatorDeviceModel: NSViewRepresentable {
    let session: SimulatorSession
    let visible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeNSView(context: Context) -> SimulatorDeviceModelView {
        let view = SimulatorDeviceModelView()
        if !view.isAvailable { session.error = L10n.text("apple.simulator.metal_unavailable") }
        view.onOrbitChanged = { [weak session] in session?.updateModelOrbit($0) }
        view.onInteraction = { [weak session, weak view] in if let view { session?.beginModelInteraction(view) } }
        session.register(view)
        return view
    }
    func updateNSView(_ view: SimulatorDeviceModelView, context: Context) {
        let physical = session.hasFrame ? SimulatorGeometry.displaySize(pixels: session.pixels, orientation: session.orientation) : session.previewPixels
        view.setShape(pixels: physical, tablet: session.selected?.isTablet == true)
        view.zoom = Float(session.zoom)
        view.reduceMotion = reduceMotion
        view.onZoom = { session.zoom = Double($0) }
        view.isHidden = !visible
        if !visible { view.stopOrbit() }
        view.redraw()
    }
    static func dismantleNSView(_ view: SimulatorDeviceModelView, coordinator: ()) { view.clear(); view.stopOrbit() }
}

/// A depth-tested hardware mesh and a live IOSurface texture share one Metal
/// pass. There is no screenshot capture, pixel readback or idle render loop.
final class SimulatorDeviceModelView: MTKView, MTKViewDelegate, SimulatorFrameSink {
    private struct Pipeline {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let state: MTLRenderPipelineState
        let depth: MTLDepthStencilState
        let blank: MTLTexture
    }
    private struct Uniforms {
        var projection: simd_float4x4
        var model: simd_float4x4
        var options: SIMD4<Float>
    }
    private static let pipeline: Pipeline? = {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: shader, options: nil) else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "deviceVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "deviceFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.depthAttachmentPixelFormat = .depth32Float
        descriptor.rasterSampleCount = 4
        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .lessEqual; depth.isDepthWriteEnabled = true
        guard let state = try? device.makeRenderPipelineState(descriptor: descriptor),
              let test = device.makeDepthStencilState(descriptor: depth) else { return nil }
        let pixel = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        // Let Metal select shared or managed memory for this CPU-populated
        // texture on Apple silicon and Intel GPUs respectively.
        pixel.usage = .shaderRead
        guard let blank = device.makeTexture(descriptor: pixel) else { return nil }
        [UInt8(0), 0, 0, 255].withUnsafeBytes { bytes in
            blank.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: bytes.baseAddress!, bytesPerRow: 4)
        }
        return Pipeline(device: device, queue: queue, state: state, depth: test, blank: blank)
    }()
    private var mesh: MTLBuffer?
    private var vertexCount = 0
    private var shape: (aspect: Float, tablet: Bool)?
    private var radius: Float = 1.25
    private var texture: MTLTexture?
    private var surface: IOSurface?
    private var surfaceID: IOSurfaceID = 0
    private var backing: Any?
    private var orientation = 1
    private(set) var orbit = SimulatorOrbit()
    private var previousPoint: SIMD3<Float>?
    private var previousTime = 0.0
    private var velocity = SIMD3<Float>.zero
    private var inertia: Timer?
    private var pendingDraw = false
    private let capacity = DispatchSemaphore(value: 2)
    var isAvailable: Bool { Self.pipeline != nil }
    var zoom: Float = 1
    var reduceMotion = false
    var onZoom: ((Float) -> Void)?
    var onOrbitChanged: ((SimulatorOrbit) -> Void)?
    var onInteraction: (() -> Void)?

    init() {
        super.init(frame: .zero, device: Self.pipeline?.device)
        colorPixelFormat = .bgra8Unorm; depthStencilPixelFormat = .depth32Float
        sampleCount = 4
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        wantsLayer = true; layer?.isOpaque = false
        isPaused = true; enableSetNeedsDisplay = true; delegate = self
        setAccessibilityElement(true); setAccessibilityRole(.image)
        setAccessibilityLabel(L10n.text("apple.simulator.perspective"))
        setAccessibilityHelp(L10n.text("apple.simulator.orbit_help"))
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { stopOrbit() }; redraw() }
    override func layout() { super.layout(); redraw() }
    func redraw() { if !isHidden { needsDisplay = true } }
    func setShape(pixels: CGSize, tablet: Bool) {
        let aspect = Float(pixels.width / max(1, pixels.height))
        guard shape?.aspect != aspect || shape?.tablet != tablet else { return }
        shape = (aspect, tablet)
        let model = SimulatorDeviceMesh(aspect: aspect, tablet: tablet)
        radius = sqrt(model.width * model.width + model.height * model.height + model.depth * model.depth) / 2
        vertexCount = model.vertices.count
        mesh = model.vertices.withUnsafeBytes { bytes in
            guard let pointer = bytes.baseAddress else { return nil }
            return device?.makeBuffer(bytes: pointer, length: bytes.count, options: .storageModeShared)
        }
        redraw()
    }
    func present(_ surface: Any, pixels: CGSize, orientation: Int, backing: Any?) {
        guard let surface = surface as? IOSurface else { return }
        self.backing = backing; self.orientation = orientation
        let id = IOSurfaceGetID(surface)
        if surfaceID != id || texture?.width != IOSurfaceGetWidth(surface) || texture?.height != IOSurfaceGetHeight(surface) {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: IOSurfaceGetWidth(surface), height: IOSurfaceGetHeight(surface), mipmapped: false)
            descriptor.usage = .shaderRead; descriptor.storageMode = .shared
            texture = device?.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0)
            surfaceID = id
        }
        self.surface = surface
        redraw()
    }
    func clear() { stopOrbit(); texture = nil; surface = nil; surfaceID = 0; orientation = 1; backing = nil; redraw() }
    func cancelGestures() { stopOrbit() }
    func applyOrbit(_ value: SimulatorOrbit) { orbit = value; redraw() }
    private func publishOrbit() { onOrbitChanged?(orbit); redraw() }
    func stopOrbit() { inertia?.invalidate(); inertia = nil; velocity = .zero; previousPoint = nil }
    override func mouseDown(with event: NSEvent) {
        stopOrbit(); onInteraction?(); window?.makeFirstResponder(self)
        if event.clickCount == 2 { orbit = SimulatorOrbit(); publishOrbit(); return }
        previousPoint = SimulatorOrbit.point(convert(event.locationInWindow, from: nil), in: bounds.size)
        previousTime = event.timestamp
    }
    override func mouseDragged(with event: NSEvent) {
        guard let previousPoint else { return }
        let point = SimulatorOrbit.point(convert(event.locationInWindow, from: nil), in: bounds.size)
        let delta = orbit.rotate(from: previousPoint, to: point)
        let elapsed = Float(max(1.0 / 240, event.timestamp - previousTime))
        velocity = delta.axis * min(5, delta.angle / elapsed)
        self.previousPoint = point; previousTime = event.timestamp
        publishOrbit()
    }
    override func mouseUp(with event: NSEvent) {
        previousPoint = nil
        guard !reduceMotion, simd_length(velocity) > 0.05 else { return }
        var previous = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window != nil, !self.isHidden else { self?.stopOrbit(); return }
                let now = ProcessInfo.processInfo.systemUptime
                let elapsed = Float(min(0.05, now - previous)); previous = now
                self.orbit.advance(velocity: self.velocity, seconds: elapsed)
                self.velocity *= exp(-6 * elapsed)
                self.publishOrbit()
                if simd_length(self.velocity) < 0.025 { self.stopOrbit() }
            }
        }
        inertia = timer; RunLoop.main.add(timer, forMode: .common)
    }
    override func scrollWheel(with event: NSEvent) {
        onInteraction?()
        zoom = max(0.5, min(3, zoom * exp(Float(event.scrollingDeltaY) * 0.008)))
        onZoom?(zoom); redraw()
    }
    override func keyDown(with event: NSEvent) {
        stopOrbit(); onInteraction?()
        switch event.keyCode {
        case 123: orbit.advance(velocity: [0, -1, 0], seconds: 0.2)
        case 124: orbit.advance(velocity: [0, 1, 0], seconds: 0.2)
        case 125: orbit.advance(velocity: [-1, 0, 0], seconds: 0.2)
        case 126: orbit.advance(velocity: [1, 0, 0], seconds: 0.2)
        case 115: orbit = SimulatorOrbit()
        default: super.keyDown(with: event); return
        }
        publishOrbit()
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { redraw() }
    func draw(in view: MTKView) {
        guard !isHidden, let pipeline = Self.pipeline, let mesh, vertexCount > 0 else { return }
        guard capacity.wait(timeout: .now()) == .success else { pendingDraw = true; return }
        pendingDraw = false
        guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let command = pipeline.queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { capacity.signal(); return }
        let aspect = Float(max(1, drawableSize.width) / max(1, drawableSize.height))
        // A fixed bounding sphere fits every angle. Orbit never changes the
        // camera distance or clips the device when its long edge turns sideways.
        let distance = radius / (sin(Float.pi / 8) * min(1, aspect)) * 1.06 / zoom
        var translation = matrix_identity_float4x4; translation.columns.3.z = -distance
        let near: Float = 0.05, far: Float = 30, scale: Float = 1 / tan(.pi / 8)
        let projection = simd_float4x4(columns: (
            [scale / aspect, 0, 0, 0], [0, scale, 0, 0],
            [0, 0, far / (near - far), -1], [0, 0, near * far / (near - far), 0]))
        let model = orbit.rotation * SimulatorOrbit.deviceRotation(orientation: orientation)
        var uniforms = Uniforms(projection: projection * translation, model: simd_float4x4(model), options: [0, texture == nil ? 0 : 1, 0, 0])
        encoder.setRenderPipelineState(pipeline.state); encoder.setDepthStencilState(pipeline.depth)
        encoder.setVertexBuffer(mesh, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setFragmentTexture(texture ?? pipeline.blank, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
        encoder.endEncoding(); command.present(drawable)
        let capacity = capacity, backing = backing, surface = surface
        command.addCompletedHandler { [weak self] _ in
            withExtendedLifetime((backing, surface)) { _ = capacity.signal() }
            DispatchQueue.main.async { [weak self] in if self?.pendingDraw == true { self?.redraw() } }
        }
        command.commit()
    }
    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct DeviceVertex { float4 position; float4 normal; float4 color; float4 texture; };
    struct DeviceUniforms { float4x4 projection; float4x4 model; float4 options; };
    struct DevicePixel { float4 position [[position]]; float3 normal; float4 color; float3 uv; };
    vertex DevicePixel deviceVertex(uint i [[vertex_id]], const device DeviceVertex *v [[buffer(0)]], constant DeviceUniforms &u [[buffer(1)]]) {
        return {u.projection * u.model * v[i].position, (u.model * v[i].normal).xyz, v[i].color, v[i].texture.xyz};
    }
    fragment float4 deviceFragment(DevicePixel p [[stage_in]], constant DeviceUniforms &u [[buffer(1)]], texture2d<float> screen [[texture(0)]]) {
        if (p.uv.z > 0.5) {
            if (u.options.y < 0.5) return float4(0.025, 0.035, 0.05, 1);
            constexpr sampler sampling(filter::linear, address::clamp_to_edge);
            return float4(screen.sample(sampling, p.uv.xy).rgb, 1);
        }
        float3 n = normalize(p.normal);
        float3 key = normalize(float3(-0.6, 0.8, 1.2));
        float3 rim = normalize(float3(0.9, 0.2, -0.8));
        float diffuse = 0.24 + 0.56 * max(0.0, dot(n, key)) + 0.38 * max(0.0, dot(n, rim));
        float specular = pow(max(0.0, dot(n, normalize(key + float3(0,0,1)))), 42.0);
        float edge = pow(1.0 - abs(n.z), 3.0) * 0.16;
        return float4(p.color.rgb * diffuse + (specular * 0.5 + edge) * p.color.a, 1);
    }
    """
}
#endif
