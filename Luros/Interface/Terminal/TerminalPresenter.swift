import UIKit

/// The one way into the terminal page.
///
/// A caller has a folder — a project's, a row in the file browser, General
/// Chat's temporary workspace — and hands it here. Which project it belongs to,
/// and which folder this run starts the shell in, are worked out here
/// (`TerminalIdentity`); the page is shown the way the other working screens
/// are: full screen, closed by the cross in its bar. Closing it hides the page
/// and leaves the shell running.
@MainActor
enum TerminalPresenter {
    /// The page on screen, so a second open from the same chat switches the
    /// page it already shows instead of stacking another one.
    private static weak var openPage: TerminalPageController?

    static func open(directory: URL, projectRoot: URL? = nil, from presenter: UIViewController) {
        let identity = TerminalIdentity.resolve(
            directory: directory,
            projectRoot: projectRoot,
            dataRoot: TerminalSessions.dataRoot
        )
        if let page = openPage, page.isShown {
            page.show(identity: identity)
            return
        }
        let page = TerminalPageController(identity: identity)
        openPage = page
        presenter.presentPageFullScreen(page)
    }
}
