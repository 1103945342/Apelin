import SnapKit
import UIKit

/// A ground made of the system's glass, the material the composer and the
/// buttons in the chat already sit on.
///
/// On iOS 26 that is `UIGlassEffect` itself. Before it there is no glass to
/// ask for, so the thinnest material stands in for the face, and a rim drawn
/// by `GlassRenderer` gives it what a material has not got: the edge of thick
/// glass, bending what lies behind it (owner, 2026-11-06). The colour and the
/// fringe at that edge come from a snapshot of the page around the surface,
/// taken through the window and read only outside the surface itself, so the
/// glass never samples its own last frame.
///
/// A panel (no corner radius) is an edge of the window rather than a piece
/// lying on it, and keeps the material it had.
final class GlassSurfaceView: UIView {
    private let effectView = UIVisualEffectView()
    /// The drawn rim, in a layer Metal can render into.
    private let lens = LensView()
    private let radius: CGFloat
    private var link: CADisplayLink?
    /// How far past the surface the snapshot reaches: what the rim bends.
    private static let margin: CGFloat = 28
    /// The page behind moves at 120 Hz; the rim is a blur of it, and follows
    /// ten times a second, which is what a snapshot costs.
    private static let redrawsPerSecond: Float = 10

    /// Never interactive: the controls that press sit above it, so the
    /// effect view would never see the touch it answers.
    init(cornerRadius: CGFloat = 0) {
        radius = cornerRadius
        super.init(frame: .zero)
        var handMade = false
        if #available(iOS 26, *) {
            effectView.effect = UIGlassEffect()
        } else {
            effectView.effect = UIBlurEffect(
                style: cornerRadius > 0 ? .systemUltraThinMaterial : .systemChromeMaterial,
            )
            handMade = cornerRadius > 0
        }
        effectView.layer.cornerRadius = cornerRadius
        effectView.layer.cornerCurve = .continuous
        effectView.clipsToBounds = true
        addSubview(effectView)
        effectView.snp.makeConstraints { x in x.edges.equalToSuperview() }

        if handMade {
            lens.isUserInteractionEnabled = false
            lens.isHidden = true
            addSubview(lens)
            lens.snp.makeConstraints { x in x.edges.equalToSuperview() }
            // The shader is compiled once, off the main thread: until it is
            // ready the material is the whole surface.
            GlassRenderer.shared.prepare { [weak self] in
                guard let self else { return }
                lens.isHidden = false
                setNeedsLayout()
            }
        }
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(cornerRadius:)")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            link?.invalidate()
            link = nil
            return
        }
        if lens.isHidden { return }
        if link == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.preferredFramesPerSecond = Int(Self.redrawsPerSecond)
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        drawLens()
    }

    @objc private func tick() {
        drawLens()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let metal = lens.layer as? CAMetalLayer else { return }
        let scale = window?.traitCollection.displayScale ?? UIScreen.main.scale
        metal.device = GlassRenderer.shared.device
        metal.isOpaque = false
        metal.contentsScale = scale
        metal.drawableSize = CGSize(
            width: max(1, bounds.width * scale),
            height: max(1, bounds.height * scale),
        )
        drawLens()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        guard previous?.userInterfaceStyle != traitCollection.userInterfaceStyle else { return }
        setNeedsLayout()
        drawLens()
    }

    /// Anywhere up the tree, hidden or faded out: nothing to draw the page
    /// from, and no one to see it. UIKit keeps this answer private, so it is
    /// walked here.
    private var isShown: Bool {
        var view: UIView? = self
        while let current = view {
            if current.isHidden || current.alpha < 0.01 { return false }
            view = current.superview
        }
        return true
    }

    // MARK: Drawing

    private func drawLens() {
        guard let metal = lens.layer as? CAMetalLayer,
              !lens.isHidden,
              window != nil,
              alpha > 0,
              isShown,
              bounds.width > 1,
              bounds.height > 1,
              GlassRenderer.shared.isReady
        else { return }
        let scale = metal.contentsScale
        guard let backdrop = capture(scale: scale) else { return }
        let dark = traitCollection.userInterfaceStyle == .dark
        GlassRenderer.shared.draw(
            GlassRenderer.Request(
                rect: CGRect(origin: .zero, size: metal.drawableSize),
                canvas: metal.drawableSize,
                texture: CGSize(width: backdrop.width, height: backdrop.height),
                origin: CGPoint(x: Self.margin * scale, y: Self.margin * scale),
                backdrop: backdrop,
                radius: radius * scale,
                tint: dark
                    ? SIMD4<Float>(0.03, 0.03, 0.04, 0.30)
                    : SIMD4<Float>(0.97, 0.97, 0.99, 0.30),
                specular: dark ? 0.55 : 0.85,
                shade: dark ? 0.35 : 0.18,
            ),
            in: metal,
        )
    }

    /// What lies behind the surface, and around it: the window's own picture
    /// of that strip, which costs a fraction of the screen it is drawn from.
    private func capture(scale: CGFloat) -> CGImage? {
        guard let window else { return nil }
        let region = convert(bounds.insetBy(dx: -Self.margin, dy: -Self.margin), to: window)
        guard region.width > 1, region.height > 1 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: region.size, format: format).image { context in
            context.cgContext.translateBy(x: -region.minX, y: -region.minY)
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        return image.cgImage
    }
}

/// A view that is only somewhere to put a Metal layer.
private final class LensView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
}
