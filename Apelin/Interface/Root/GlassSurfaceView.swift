import LiquidGlassKit
import MetalKit
import UIKit

/// A background only: controls remain siblings above it, not children of the
/// library's Metal view. Native glass stays native on iOS 26; the older rounded
/// surfaces use LiquidGlassKit, never an application-owned refraction shader.
final class GlassSurfaceView: UIView {
    private let radius: CGFloat
    private let interactive: Bool
    private var surface: UIView?
    private var style: GlassSurfaceStyle?
    private var sceneIsDeactivating = false
    private static let hasMetalDevice = MTLCreateSystemDefaultDevice() != nil

    init(cornerRadius: CGFloat = 0, isInteractive: Bool = false) {
        radius = cornerRadius.isFinite ? max(0, cornerRadius) : 0
        interactive = isInteractive
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        layer.cornerCurve = .continuous
        clipsToBounds = true

        let center = NotificationCenter.default
        for name in [
            UIAccessibility.reduceTransparencyStatusDidChangeNotification,
            Notification.Name.NSProcessInfoPowerStateDidChange,
            UIScene.didActivateNotification,
            UIScene.willDeactivateNotification,
            UIScene.didEnterBackgroundNotification,
        ] {
            center.addObserver(self, selector: #selector(environmentChanged), name: name, object: nil)
        }
        updateSurface()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(cornerRadius:isInteractive:)")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var isHidden: Bool {
        didSet { updateSurface() }
    }

    override var alpha: CGFloat {
        didSet { updateSurface() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        sceneIsDeactivating = window?.windowScene?.activationState != .foregroundActive
        updateSurface()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateSurface()
        layoutSurface()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        // The library resolves its dynamic tint when its Metal view lays out.
        updateSurface()
        visitMetalViews(in: surface) { $0.setNeedsLayout() }
        setNeedsLayout()
    }

    @objc private func environmentChanged(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene !== window?.windowScene {
            return
        }
        // willDeactivate is delivered before activationState changes. Keep an
        // explicit guard so an intervening layout cannot restart Metal.
        if notification.name == UIScene.willDeactivateNotification ||
            notification.name == UIScene.didEnterBackgroundNotification
        {
            sceneIsDeactivating = true
        } else if notification.name == UIScene.didActivateNotification {
            sceneIsDeactivating = false
        }
        updateSurface()
        setNeedsLayout()
    }

    private func updateSurface() {
        let nativeAvailable: Bool
        if #available(iOS 26, *) {
            nativeAvailable = true
        } else {
            nativeAvailable = false
        }
        let active = !sceneIsDeactivating && window?.windowScene?.activationState == .foregroundActive &&
            !isHidden && alpha > 0.01 && bounds.width.isFinite && bounds.height.isFinite &&
            bounds.width >= 1 && bounds.height >= 1
        let next = GlassSurfaceStyle.choose(
            nativeAvailable: nativeAvailable,
            rounded: radius > 0,
            reduceTransparency: UIAccessibility.isReduceTransparencyEnabled,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            active: active,
            metalAvailable: nativeAvailable || Self.hasMetalDevice
        )
        setSurface(next)
    }

    private func setSurface(_ next: GlassSurfaceStyle) {
        guard style != next else { return }
        visitMetalViews(in: surface) { $0.isPaused = true }
        surface?.removeFromSuperview()

        let view: UIView
        switch next {
        case .native:
            if #available(iOS 26, *) {
                let effect = UIGlassEffect()
                effect.isInteractive = interactive
                view = UIVisualEffectView(effect: effect)
            } else {
                preconditionFailure("Native glass requires iOS 26")
            }
        case .legacy:
            // Do not use the library's factory: Apelin owns the native/legacy
            // decision explicitly, and leaves the library's shaders untouched.
            view = LiquidGlassEffectView(effect: LiquidGlassEffect(style: .regular, isNative: false))
            // The library captures its superview's backdrop and waits for the
            // GPU on every frame, on the main thread: at its own 60 Hz one
            // surface alone costs more than a scroll. Small or decorative
            // surfaces show no visible refraction difference at 15.
            let frames = GlassSurfaceStyle.framesPerSecond(forArea: bounds.width * bounds.height)
            visitMetalViews(in: view) {
                $0.isPaused = true
                $0.preferredFramesPerSecond = frames
            }
        case .material:
            view = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
        case .opaque:
            view = UIView()
            view.backgroundColor = .secondarySystemBackground
        }
        view.isUserInteractionEnabled = false
        view.layer.cornerCurve = .continuous
        view.clipsToBounds = true
        surface = view
        style = next
        addSubview(view)
        layoutSurface()
        if next == .legacy {
            // A valid frame and texture buffer must exist before the first draw.
            view.setNeedsLayout()
            view.layoutIfNeeded()
            visitMetalViews(in: view) { $0.isPaused = false }
        }
    }

    private func layoutSurface() {
        let corner = min(radius, max(0, min(bounds.width, bounds.height) / 2))
        layer.cornerRadius = corner
        surface?.layer.cornerRadius = corner
        surface?.frame = bounds
    }

    private func visitMetalViews(in view: UIView?, _ body: (MTKView) -> Void) {
        guard let view else { return }
        if let metal = view as? MTKView {
            body(metal)
        }
        for child in view.subviews {
            visitMetalViews(in: child, body)
        }
    }
}
