import CoreGraphics

/// A pure policy shared by the UIKit adapter and the device test. It does
/// not construct effects, load shaders or stand in for a rendering test.
enum GlassSurfaceStyle: Equatable {
    case native, legacy, material, opaque

    static func choose(
        nativeAvailable: Bool,
        rounded: Bool,
        reduceTransparency: Bool,
        lowPower: Bool,
        active: Bool,
        metalAvailable: Bool
    ) -> Self {
        if reduceTransparency { return .opaque }
        if nativeAvailable { return .native }
        if !rounded || lowPower || !active || !metalAvailable { return .material }
        return .legacy
    }

    /// Frames a legacy surface draws per second. The library captures its
    /// backdrop and blocks on the GPU each frame, so a surface big enough for
    /// the refraction to read gets 30 and a small or decorative one 15.
    static func framesPerSecond(forArea area: CGFloat) -> Int {
        guard area.isFinite else { return 15 }
        return area >= 40_000 ? 30 : 15
    }
}
