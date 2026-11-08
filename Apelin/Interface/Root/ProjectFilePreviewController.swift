import QuickLook
import UIKit

/// Quick Look preview for a non-text file in the current project.
///
/// The workspace owns the file, so no temporary copy is needed: the URL stays
/// inside the project and is only handed to Quick Look for reading.
final class ProjectFilePreviewController: QLPreviewController, QLPreviewControllerDataSource {
    private let fileURL: URL

    init(url: URL) {
        fileURL = url
        super.init(nibName: nil, bundle: nil)
        dataSource = self
        title = url.lastPathComponent
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(url:)")
    }

    @objc dynamic func numberOfPreviewItems(in _: QLPreviewController) -> Int {
        1
    }

    @objc dynamic func previewController(_: QLPreviewController, previewItemAt _: Int) -> QLPreviewItem {
        fileURL as NSURL
    }
}
