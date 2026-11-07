#if !APELIN_GLASS_ADAPTER_TESTS
#error("Test-only API stand-in; never compile in the app target")
#endif

import UIKit

// Written only for the two public signatures the adapter calls. This is NOT
// LiquidGlassKit, cannot render, and cannot validate the dependency's build.
public final class LiquidGlassEffect: UIVisualEffect {
    public enum Style { case regular, clear }

    public init(style _: Style, isNative _: Bool = true) {
        super.init()
    }

    public required init?(coder _: NSCoder) {
        fatalError("Test API stand-in")
    }
}

public final class LiquidGlassEffectView: UIView {
    public init(effect _: LiquidGlassEffect) {
        super.init(frame: .zero)
    }

    public required init?(coder _: NSCoder) {
        fatalError("Test API stand-in")
    }
}
