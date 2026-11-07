import SnapKit
import UIKit

/// Liquid glass, the surface everything in this app sits on: thick rounded
/// glass over a live backdrop, refracting what lies behind it and catching the
/// light across the top (owner, 2026-11-06).
///
/// On iOS 26 it is `UIGlassEffect` itself. Before that there is no glass to
/// ask for, so it is drawn here in full by `GlassRenderer`: a Metal layer over
/// a `CABackdropLayer`, the private layer UIKit's own materials read, which
/// gives the page behind it live without a snapshot each frame. A surface with
/// no corner stays `systemChromeMaterial`, the panel edge it always was.
final class GlassSurfaceView: UIView {
    private let glassHost = GlassHost()
    private let radius: CGFloat

    init(cornerRadius: CGFloat = 0) {
        radius = cornerRadius
        super.init(frame: .zero)

        if #available(iOS 26, *) {
            let effect = UIVisualEffectView()
            effect.effect = UIGlassEffect()
            effect.layer.cornerRadius = cornerRadius
            effect.layer.cornerCurve = .continuous
            effect.clipsToBounds = true
            addSubview(effect)
            effect.snp.makeConstraints { $0.edges.equalToSuperview() }
        } else if cornerRadius > 0 {
            glassHost.isUserInteractionEnabled = false
            glassHost.radius = cornerRadius
            glassHost.isHidden = true
            addSubview(glassHost)
            glassHost.snp.makeConstraints { $0.edges.equalToSuperview() }
            GlassRenderer.shared.prepare { [weak self] in
                self?.glassHost.isHidden = false
                self?.glassHost.setNeedsLayout()
            }
        } else {
            let effect = UIVisualEffectView()
            effect.effect = UIBlurEffect(style: .systemChromeMaterial)
            addSubview(effect)
            effect.snp.makeConstraints { $0.edges.equalToSuperview() }
        }
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(cornerRadius:)")
    }
}

/// A view holding the backdrop and the Metal layer that reads it: the two are
/// kept as sublayers of the same view, so the backdrop sits right behind the
/// Metal sheet and Metal samples what it draws.
private final class GlassHost: UIView {
    var radius: CGFloat = 0
    private var backdropLayer: CALayer?
    private let metalHost = MetalHost()
    private var link: CADisplayLink?

    override init(frame: CGRect) {
        super.init(frame: frame)
        if let cls = NSClassFromString("CABackdropLayer") as? CALayer.Type {
            let backdrop = cls.init()
            backdrop.setValue("default", forKey: "groupName")
            layer.insertSublayer(backdrop, at: 0)
            backdropLayer = backdrop
        }
        metalHost.isUserInteractionEnabled = false
        addSubview(metalHost)
        metalHost.snp.makeConstraints { $0.edges.equalToSuperview() }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            link?.invalidate()
            link = nil
            return
        }
        if link == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.preferredFramesPerSecond = 60
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        setNeedsLayout()
    }

    @objc private func tick() {
        guard let metal = metalHost.layer as? CAMetalLayer,
              !isHidden,
              alpha > 0.01,
              GlassRenderer.shared.isReady,
              let backdrop = backdropLayer,
              let window
        else { return }
        let scale = window.traitCollection.displayScale
        GlassRenderer.shared.draw(
            GlassRenderer.Request(
                bounds: bounds,
                radius: radius,
                backdrop: backdrop,
                scale: scale,
                dark: traitCollection.userInterfaceStyle == .dark
            ),
            into: metal
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        backdropLayer?.frame = bounds
        guard let metal = metalHost.layer as? CAMetalLayer,
              let window
        else { return }
        let scale = window.traitCollection.displayScale
        metal.device = GlassRenderer.shared.device
        metal.isOpaque = false
        metal.contentsScale = scale
        metal.drawableSize = CGSize(
            width: max(1, bounds.width * scale),
            height: max(1, bounds.height * scale)
        )
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        setNeedsLayout()
    }
}

private final class MetalHost: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
}
