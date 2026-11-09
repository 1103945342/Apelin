import UIKit

/// Hands an `apelin://` link (`ApelinLink`) to the window that shows the
/// conversations: from the scene's URL contexts (a widget, the Live
/// Activity, another app, `uiopen`), and from a link tapped in a
/// conversation, which opens in place rather than through the system.
@MainActor
enum ApelinLinkRouter {
    /// Opens `url` when it is an `apelin:` link and says so; any other URL
    /// is left to its caller.
    @discardableResult
    static func open(_ url: URL, in scene: UIWindowScene?) -> Bool {
        guard let link = ApelinLink(url: url) else { return false }
        let connected = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        // The scene that handed the link over first, then whichever is in
        // front — a link tapped in a conversation or a message arrives with
        // none — and only then the rest: a window the reader cannot see must
        // not be the one that takes the link, or nothing appears to happen.
        let candidates = [scene].compactMap(\.self)
            + connected.filter { $0 !== scene && $0.activationState == .foregroundActive }
            + connected.filter { $0 !== scene && $0.activationState != .foregroundActive }
        let root = candidates.lazy
            .flatMap(\.windows)
            .compactMap { $0.rootViewController as? RootInterfaceController }
            .first
        root?.open(link)
        return true
    }
}
