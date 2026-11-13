import UIKit

/// The one way into the file browser.
///
/// A whole page over what is on screen, opened at the folder the caller asks
/// for — a conversation's folder, a project, anywhere mobile may read. The
/// page holds its own place and nothing else: walking it never changes the
/// conversation's project, the Git page's repository or the root the agent
/// works in, because none of them is written here.
@MainActor
enum FileBrowserPresenter {
    static func open(directory: URL, projectRoot: URL? = nil, from presenter: UIViewController) {
        let page = FileBrowserController(directory: directory, projectRoot: projectRoot)
        presenter.presentPageFullScreen(page)
    }
}
