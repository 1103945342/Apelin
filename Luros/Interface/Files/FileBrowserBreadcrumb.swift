import CoreGraphics
import Foundation

/// The path area's trail: the root, every folder between, and the one on
/// screen.
///
/// Each crumb is a `FileBrowserLocation`, so it is a place the browser has
/// already resolved rather than a name between slashes, and the trail always
/// runs from the root down to the current folder — the file system's order,
/// whichever way the interface reads. The page lays the trail out; a
/// right-to-left interface mirrors the drawing, not the order.
struct FileBrowserBreadcrumb: Equatable {
    struct Segment: Equatable {
        let location: FileBrowserLocation
        /// What the crumb is called: the root's own word for itself, or the
        /// folder's last component.
        let title: String
        let isRoot: Bool
        let isCurrent: Bool
    }

    /// From the root down to the folder on screen, the current one last.
    let segments: [Segment]

    /// `rootTitle` is the name the root is shown under, kept as a parameter so
    /// the model carries no words of its own.
    init(location: FileBrowserLocation, rootTitle: String) {
        segments = location.ancestors.map { step in
            let isRoot = step.path == "/"
            return Segment(
                location: step,
                title: isRoot ? rootTitle : step.title,
                isRoot: isRoot,
                isCurrent: step == location
            )
        }
    }

    var current: Segment? { segments.last }

    /// Every crumb above the folder on screen, root first.
    var ancestors: [Segment] { Array(segments.dropLast()) }
}

/// How the path area is drawn: a name may be shortened, but never below a
/// target and never to a whole narrow screen, so the crumbs on either side
/// stay in sight.
enum FileBrowserBreadcrumbLayout {
    /// The widest one name is drawn at, whatever the screen.
    static let maximumTitleWidth: CGFloat = 280
    /// One crumb's smallest width, so even a one-letter name is easy to hit.
    static let minimumTarget: CGFloat = 44
    /// The share of a narrow path area one name may take.
    static let titleShare: CGFloat = 0.6

    /// The width a crumb's title is cut at, for a path area `available` points
    /// wide: a share of a narrow one, at most `maximumTitleWidth`, and never
    /// under `minimumTarget`. An area not laid out yet (0) takes the maximum,
    /// and the first layout narrows it.
    static func titleWidthLimit(available: CGFloat) -> CGFloat {
        guard available > 0 else { return maximumTitleWidth }
        let share = available * titleShare
        return max(minimumTarget, min(maximumTitleWidth, share))
    }
}

/// When the path area moves sideways to the folder it is showing: the first
/// trail, and a trail that leads somewhere else. The same folder drawn again —
/// a reload, a file saved beside the reader — leaves the sideways position
/// where they left it.
struct FileBrowserBreadcrumbReveal {
    private var revealed: String?

    /// True once per folder the area comes to show, and never for that folder
    /// drawn again.
    mutating func shouldReveal(_ path: String) -> Bool {
        guard revealed != path else { return false }
        revealed = path
        return true
    }
}
