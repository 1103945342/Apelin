#if APELIN_GLASS_ADAPTER_TESTS
import UIKit

// Only gives the iOS 17 SDK the name used in the availability-guarded branch.
// No native effect is built or executed; Xcode must validate the actual API.
@available(iOS 26, *)
final class UIGlassEffect: UIVisualEffect {
    var isInteractive = false
}
#else
#error("Test-only old SDK support; never compile in the app target")
#endif
