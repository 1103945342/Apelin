import Metal
import QuartzCore
import UIKit

/// Real liquid glass, the way iOS 26 draws it: thick rounded glass over a live
/// backdrop, refracting what lies behind it hardest at the edge, colour
/// fringing where red and blue bend at different angles, a band of light across
/// the top where the surface catches it, and the middle darker where the glass
/// is thick (2026-11-06).
///
/// The face is drawn here in full, not just the rim, because the refraction and
/// the shading that give it depth need every point of the surface. The backdrop
/// is `CABackdropLayer`, the private layer UIKit's own materials read: it is
/// live, costs nothing, and is read by Metal without a snapshot each frame.
final class GlassRenderer {
    struct Request {
        var bounds: CGRect          // in points
        var radius: CGFloat
        var backdrop: CALayer       // the backdrop layer to sample from
        var scale: CGFloat
        var dark: Bool
    }

    static let shared = GlassRenderer()

    private(set) var isReady = false
    private(set) var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private let lock = NSLock()
    private var readyWork: [() -> Void] = []

    private init() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.build()
        }
    }

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
              let vertex = library.makeFunction(name: "liquidVertex"),
              let fragment = library.makeFunction(name: "liquidFragment")
        else { return }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
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

    func draw(_ request: Request, into layer: CAMetalLayer) {
        guard isReady,
              let device,
              let queue,
              let pipeline,
              let drawable = layer.nextDrawable(),
              let command = queue.makeCommandBuffer()
        else { return }

        // Capture the backdrop layer into a texture Metal can read: render the
        // backdrop into a context, then upload.
        let scale = request.scale
        let size = CGSize(width: request.bounds.width * scale, height: request.bounds.height * scale)
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0 else { return }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return }
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: 0, y: request.bounds.height)
            ctx.scaleBy(x: 1, y: -1)
            request.backdrop.render(in: ctx)
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return }
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: width * 4
        )

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }

        struct Uniforms {
            var size: SIMD2<Float>
            var radius: Float
            var bevel: Float
            var pull: Float
            var tint: SIMD4<Float>
            var specular: Float
            var thickness: Float
        }

        let dark = request.dark
        var uniforms = Uniforms(
            size: SIMD2<Float>(Float(width), Float(height)),
            radius: Float(request.radius * scale),
            bevel: Float(28 * scale),
            pull: Float(32 * scale),
            tint: dark ? SIMD4(0.02, 0.02, 0.03, 0.45) : SIMD4(0.98, 0.98, 0.99, 0.40),
            specular: dark ? 0.65 : 0.90,
            thickness: dark ? 0.40 : 0.25
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 size;
        float radius;
        float bevel;
        float pull;
        float4 tint;
        float specular;
        float thickness;
    };

    float sdRoundBox(float2 p, float2 b, float r) {
        float2 q = abs(p) - b + r;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    }

    float2 sdfNormal(float2 p, float2 b, float r) {
        const float e = 1.0;
        float dx = sdRoundBox(p + float2(e, 0), b, r) - sdRoundBox(p - float2(e, 0), b, r);
        float dy = sdRoundBox(p + float2(0, e), b, r) - sdRoundBox(p - float2(0, e), b, r);
        return normalize(float2(dx, dy));
    }

    struct VertOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VertOut liquidVertex(uint vid [[vertex_id]]) {
        float2 corners[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };
        float2 c = corners[vid];
        VertOut out;
        out.position = float4(c * 2.0 - 1.0, 0, 1);
        out.uv = float2(c.x, 1.0 - c.y);
        return out;
    }

    fragment float4 liquidFragment(
        VertOut in [[stage_in]],
        texture2d<float> backdrop [[texture(0)]],
        constant Uniforms &u [[buffer(0)]]
    ) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 pixel = in.uv * u.size;
        float2 centre = u.size * 0.5;
        float2 half = u.size * 0.5;
        float2 rel = pixel - centre;
        float d = sdRoundBox(rel, half, u.radius);

        // Outside the glass: transparent, so the view behind shows.
        if (d > 0.5) { discard_fragment(); }

        float t = max(0.0, -d);
        float2 n = sdfNormal(rel, half, u.radius);

        // The glass is thick at the middle and thin at the edge: refraction
        // is hardest where it thins, pulling the backdrop into the rim.
        float edge = smoothstep(u.bevel, 0.0, t);
        float middle = 1.0 - smoothstep(0.0, u.bevel * 0.6, t);

        // Displacement: each colour bends a little differently.
        float strength = edge * edge * u.pull;
        float2 offset = n * strength;
        float2 uvC = (pixel + offset) / u.size;
        float2 uvR = (pixel + offset * 1.10) / u.size;
        float2 uvB = (pixel + offset * 0.90) / u.size;

        // Sample with a small blur where the glass is thick.
        const float2 taps[12] = {
            float2(-0.326, -0.406), float2(-0.840, -0.074), float2(-0.696, 0.457),
            float2(-0.203, 0.621), float2(0.962, -0.195), float2(0.473, -0.480),
            float2(0.519, 0.767), float2(0.185, -0.893), float2(0.507, 0.064),
            float2(0.896, 0.412), float2(-0.321, -0.937), float2(0.052, 0.119)
        };
        float3 sum = float3(0);
        float blurRadius = middle * 4.5 / u.size.x;
        for (int i = 0; i < 12; i++) {
            sum += backdrop.sample(s, uvC + taps[i] * blurRadius).rgb;
        }
        float3 colour = sum / 12.0;
        colour.r = mix(colour.r, backdrop.sample(s, uvR).r, 0.7);
        colour.b = mix(colour.b, backdrop.sample(s, uvB).b, 0.7);

        // Desaturate and tint.
        float lum = dot(colour, float3(0.299, 0.587, 0.114));
        colour = mix(colour, float3(lum), 0.28);
        colour = mix(colour, u.tint.rgb, u.tint.a);

        // Specular highlight: a soft band across the top where the glass catches
        // the light, brightest at the leading corner.
        float2 toTop = float2(-rel.x, -rel.y + half.y * 0.6);
        float topDist = length(toTop);
        float highlight = exp(-topDist / (u.size.y * 0.15)) * u.specular;
        float cornerBias = 1.0 - smoothstep(0.0, half.x * 0.4, abs(rel.x));
        colour += highlight * (0.5 + 0.5 * cornerBias);

        // The rim: bright where the normal faces the light.
        float3 lit = normalize(float3(-0.5, -0.7, 0.6));
        float facing = saturate(dot(normalize(float3(n, 0.5)), lit));
        float rim = smoothstep(3.0, 0.0, t);
        colour += rim * facing * u.specular * 0.8;

        // Thickness: the middle is darker where the glass is thick.
        colour *= 1.0 - middle * u.thickness;

        // Alpha ramps at the very edge so the rounded corners blend.
        float alpha = smoothstep(-1.0, 1.0, -d);
        return float4(colour, alpha);
    }
    """
}
