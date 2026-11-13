import UIKit

extension UIViewController {
    /// Shows a folder that belongs to Apelin's own storage — an SDK's or a
    /// toolchain's — in the app's file browser, the page `Browse Files`
    /// opens. Such a folder is under no project, so there is no project root
    /// to hand over: the browser has none to name.
    ///
    /// Editing is never the way one of these folders changes: it is removed
    /// through the page's own Remove, which clears the record with it.
    func browseFiles(directory: String) {
        FileBrowserPresenter.open(
            directory: URL(fileURLWithPath: directory, isDirectory: true),
            projectRoot: nil,
            from: self,
        )
    }
}
