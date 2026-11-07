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
}
