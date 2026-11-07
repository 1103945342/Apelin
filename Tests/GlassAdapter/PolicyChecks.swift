import Foundation

/// Exercises production policy only. No window, UIKit capture or shader runs.
@main
struct GlassPolicyChecks {
    static func main() {
        var failures: [String] = []
        var counts: [String: Int] = [:]
        for mask in 0..<64 {
            let native = mask & 1 != 0
            let rounded = mask & 2 != 0
            let reduced = mask & 4 != 0
            let lowPower = mask & 8 != 0
            let active = mask & 16 != 0
            let metal = mask & 32 != 0
            let actual = GlassSurfaceStyle.choose(
                nativeAvailable: native,
                rounded: rounded,
                reduceTransparency: reduced,
                lowPower: lowPower,
                active: active,
                metalAvailable: metal
            )
            // The priority contract: accessibility, native, eligible legacy,
            // then a system material. These assertions include native glass
            // with Low Power Mode/no Metal and transparency over native glass.
            let expected: GlassSurfaceStyle
            if reduced {
                expected = .opaque
            } else if native {
                expected = .native
            } else if rounded && !lowPower && active && metal {
                expected = .legacy
            } else {
                expected = .material
            }
            if actual != expected {
                failures.append("mask \(mask): \(actual), expected \(expected)")
            }
            counts[String(describing: actual), default: 0] += 1
        }
        if counts != ["opaque": 32, "native": 16, "legacy": 1, "material": 15] {
            failures.append("unexpected distribution: \(counts)")
        }
        guard failures.isEmpty else {
            print(failures.joined(separator: "\n"))
            exit(1)
        }
        print("PASS: 64 production glass policy combinations (no rendering tested)")
    }
}
