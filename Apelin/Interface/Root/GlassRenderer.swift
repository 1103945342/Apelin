import Metal
import QuartzCore
import UIKit

/// The lens of a hand-made Liquid Glass, for the systems that have no
/// `UIGlassEffect`: one fragment shader draws the edge of a rounded surface
/// and bends what lies behind it, the way thick glass does, leaving the face
/// itself to the system's material underneath.
///
/// Only the rim is drawn here, for a reason that decides the whole design: the
/// backdrop has to be photographed to be bent, and a photograph taken by the
/// window holds the surface itself. Keeping the shader to the band just inside
/// the edge means every sample it takes falls outside the surface, on content
/// that is really there, and the face between the rims stays the live material
/// the system draws for free.
final class GlassRenderer {
    /// What a surface asks for: where it is in the snapshot, how round, and
    /// how the light finds it.
    struct Request {
        /// The surface's own rect, in the drawable's pixels.
        var rect: CGRect
        /// The drawable's size, in pixels: the surface's own bounds.
        var canvas: CGSize
        /// The snapshot's size, in pixels, and where the surface starts in it.
        var texture: CGSize
        var origin: CGPoint
        /// The snapshot, with the surface somewhere inside it.
        var backdrop: CGImage
        var radius: CGFloat
        var tint: SIMD4<Float>
        var specular: Float
        var shade: Float
    }

    static let shared = GlassRenderer()

    /// Set once the shader has compiled; a surface draws its material until
    /// then, and asks to be drawn again when `prepare` says it is ready.
    private(set) var isReady = false

    /// The device a surface must give its layer, since a `CAMetalLayer`
    /// draws nothing without one.
    private(set) var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    /// Kept between frames, since a surface redraws at most a few times a
    /// second and a fresh texture each time would throw the old one away.
    private var staging: MTLTexture?
    private var stagingSize = CGSize.zero
    private let lock = NSLock()
    private var readyWork: [() -> Void] = []

    private init() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.build()
        }
    }

    /// Runs `work` on the main queue once the shader can draw, at once if it
    /// already can.
    func prepare(_ work: @escaping () -> Void) {
        lock.lock()
        if isReady {
            lock.unlock()
            DispatchQueue.main.async(execute: work)
            return
        }
        readyWork.append(work)
        lock.unlock()
    }

    private func build() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return }
        guard let library = try? device.makeLibrary(source: Self.shader, options: nil),
              let function = library.makeFunction(name: "glassEdge"),
              let vertex = library.makeFunction(name: "glassVertex")
        else { return }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = function
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return }

        self.device = device
        self.queue = queue
        self.pipeline = pipeline

        lock.lock()
        isReady = true
        let work = readyWork
        readyWork = []
        lock.unlock()
        DispatchQueue.main.async {
            work.forEach { $0() }
        }
    }

    /// Draws the rim of `request` into `layer`, whose drawable is the surface's
    /// own bounds.
    func draw(_ request: Request, in layer: CAMetalLayer) {
        guard isReady,
              let device,
              let queue,
              let pipeline,
              let drawable = layer.nextDrawable(),
              let command = queue.makeCommandBuffer()
        else { return }
        let size = request.texture
        guard size.width >= 1, size.height >= 1 else { return }
        guard let backdrop = texture(for: request.backdrop, size: size, device: device) else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = Uniforms(
            rect: SIMD4<Float>(
                Float(request.rect.minX), Float(request.rect.minY),
                Float(request.rect.width), Float(request.rect.height),
            ),
            params: SIMD4<Float>(Float(request.radius), Self.bevel, Self.pull, Self.blur),
            tint: request.tint,
            light: SIMD4<Float>(-0.55, -0.75, request.specular, request.shade),
            size: SIMD4<Float>(
                Float(request.texture.width), Float(request.texture.height),
                Float(request.origin.x), Float(request.origin.y),
            ),
            canvas: SIMD4<Float>(
                Float(request.canvas.width), Float(request.canvas.height), 0, 0,
            ),
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(backdrop, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
    }

    /// The band the shader draws, in points: how far in from the edge the lens
    /// reaches, how hard it pulls, and how much of it is blurred.
    private static let bevel: Float = 12
    private static let pull: Float = 12
    private static let blur: Float = 3

    private struct Uniforms {
        var rect: SIMD4<Float>
        var params: SIMD4<Float>
        var tint: SIMD4<Float>
        var light: SIMD4<Float>
        var size: SIMD4<Float>
        var canvas: SIMD4<Float>
    }

    /// The snapshot as a texture, drawn into a bitmap first because Metal
    /// takes bytes and a `CGImage` is not bytes.
    private func texture(for image: CGImage, size: CGSize, device: MTLDevice) -> MTLTexture? {
        let width = Int(size.width), height = Int(size.height)
        if staging == nil || stagingSize != size {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                mipmapped: false,
            )
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .shared
            staging = device.makeTexture(descriptor: descriptor)
            stagingSize = size
        }
        guard let texture = staging else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue,
            ) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: width * 4,
        )
        return texture
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float4 rect;      // x, y, w, h in snapshot pixels, top left origin
        float4 params;    // radius, bevel, pull, blur
        float4 tint;      // rgba
        float4 light;     // dir.x, dir.y, specular, shade
        float4 size;      // snapshot w, h, where the surface starts in it
        float4 canvas;    // drawable w, h, -, -
    };

    float sdRoundBox(float2 p, float2 b, float r) {
        float2 q = abs(p) - b + r;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    }

    float2 sdfNormal(float2 p, float2 b, float r) {
        const float e = 0.75;
        float dx = sdRoundBox(p + float2(e, 0), b, r) - sdRoundBox(p - float2(e, 0), b, r);
        float dy = sdRoundBox(p + float2(0, e), b, r) - sdRoundBox(p - float2(0, e), b, r);
        return normalize(float2(dx, dy) + 1e-6);
    }

    struct VertOut {
        float4 position [[position]];
        float2 uv;
        float2 px;
    };

    vertex VertOut glassVertex(uint vid [[vertex_id]]) {
        float2 corners[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };
        float2 c = corners[vid];
        VertOut out;
        out.position = float4(c * 2.0 - 1.0, 0.0, 1.0);
        out.uv = float2(c.x, 1.0 - c.y);
        out.px = c;
        return out;
    }

    fragment float4 glassEdge(VertOut in [[stage_in]],
                              texture2d<float> backdrop [[texture(0)]],
                              constant Uniforms &u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 pixel = float2(in.px.x, 1.0 - in.px.y) * u.canvas.xy;

        float2 centre = u.rect.xy + u.rect.zw * 0.5;
        float2 halfSize = u.rect.zw * 0.5;
        float2 rel = pixel - centre;
        float d = sdRoundBox(rel, halfSize, u.params.x);
        float t = max(0.0, -d);
        // The face is the material's: this shader owns the rim alone.
        float bevel = 1.0 - smoothstep(0.0, u.params.y, t);
        if (t > u.params.y + 1.0) { discard_fragment(); }

        float2 n = sdfNormal(rel, halfSize, u.params.x);

        // Thick glass bends what is behind it, hardest at the edge, and each
        // colour by a little more or less, which leaves the fringe. Every
        // sample lands outside the surface, where the snapshot holds the page
        // rather than this surface's own last frame.
        float2 pull = n * (bevel * bevel * u.params.z);
        float2 sC = pixel + pull;
        float2 sR = pixel + pull * 1.06;
        float2 sB = pixel + pull * 0.94;
        // Whatever the pull, nothing is read from inside the surface.
        float sdC = sdRoundBox(sC - centre, halfSize, u.params.x);
        if (sdC < 0.75) { sC += n * (0.75 - sdC); }
        float sdR = sdRoundBox(sR - centre, halfSize, u.params.x);
        if (sdR < 0.75) { sR += n * (0.75 - sdR); }
        float sdB = sdRoundBox(sB - centre, halfSize, u.params.x);
        if (sdB < 0.75) { sB += n * (0.75 - sdB); }
        float2 uvC = (sC + u.size.zw) / u.size.xy;
        float2 uvR = (sR + u.size.zw) / u.size.xy;
        float2 uvB = (sB + u.size.zw) / u.size.xy;

        const float2 taps[8] = {
            float2(-0.61, 0.35), float2(0.42, 0.72), float2(0.74, -0.31), float2(-0.28, -0.78),
            float2(0.12, 0.15), float2(-0.83, -0.22), float2(0.55, 0.28), float2(0.05, -0.5)
        };
        float3 sum = float3(0.0);
        for (int i = 0; i < 8; i++) {
            sum += backdrop.sample(s, uvC + taps[i] * u.params.w / u.size.xy).rgb;
        }
        float3 colour = sum / 8.0;
        colour.r = mix(colour.r, backdrop.sample(s, uvR).r, 0.6);
        colour.b = mix(colour.b, backdrop.sample(s, uvB).b, 0.6);

        float lum = dot(colour, float3(0.299, 0.587, 0.114));
        colour = mix(colour, float3(lum), 0.22);
        colour = mix(colour, u.tint.rgb, u.tint.a);

        float3 lit = normalize(float3(u.light.x, u.light.y, 0.75));
        float facing = saturate(dot(normalize(float3(n, 0.55)), lit));
        float rim = 1.0 - smoothstep(0.0, 1.6, t);
        colour += u.light.z * rim * (0.25 + 0.75 * facing);
        colour *= 1.0 - u.light.w * (1.0 - facing) * exp(-t / 2.5);

        // Away from the rim the band fades into the material, so no edge shows.
        return float4(colour, saturate(bevel * 1.6));
    }
    """
}
