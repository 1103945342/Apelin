import ApelinCore
import CoreGraphics
import Foundation

/// The path area's trail: the resolved path from the root down, the folder on
/// screen marked once, a long name kept whole for VoiceOver while the drawing
/// is capped, and a sideways move only for a folder the trail has not shown
/// yet.
func checkFileBrowserBreadcrumb() throws {
    let work = try temporaryFolder("breadcrumb")
    defer { try? FileManager.default.removeItem(at: work) }

    let deep = work.appendingPathComponent("Sources/App/Views", isDirectory: true)
    try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
    guard let location = FileBrowserLocation(url: deep) else {
        preconditionFailure("the folder it just made is a location")
    }

    // Root first, current last, and neither reversed: the order the old menu
    // built for its top-down list is the model's own order here.
    let trail = FileBrowserBreadcrumb(location: location, rootTitle: "This Device")
    precondition(
        trail.segments.map(\.location.path) == location.ancestors.map(\.path),
        "the trail is the canonical path from the root down"
    )
    precondition(trail.segments.first?.location.path == "/", "it starts at the root")
    precondition(trail.segments.last?.location == location, "and ends at the folder on screen")
    precondition(trail.segments.first?.title == "This Device", "the root is called what the page calls it")
    precondition(trail.segments.filter(\.isRoot).count == 1, "only the root says it is the root")
    precondition(trail.segments.first?.isRoot == true, "the first crumb is the root")
    precondition(trail.segments.filter(\.isCurrent).count == 1, "one crumb is the folder on screen")
    precondition(trail.current?.isCurrent == true, "and it is the last one")
    precondition(
        Array(trail.segments.map(\.title).suffix(4)) == [work.lastPathComponent, "Sources", "App", "Views"],
        "each folder is called by its last component"
    )
    precondition(
        trail.ancestors.map(\.location) == Array(location.ancestors.dropLast()),
        "the crumbs above are the ancestors, root first"
    )
    precondition(trail.ancestors.last?.location == location.parent, "the one above is the parent")
    precondition(trail.ancestors.first?.isRoot == true, "the list above starts at the root")

    // The top of the file system is one crumb, and the current one.
    guard let root = FileBrowserLocation(path: "/") else { preconditionFailure("the root is a location") }
    let rootTrail = FileBrowserBreadcrumb(location: root, rootTitle: "This Device")
    precondition(rootTrail.segments.count == 1, "the root is a trail of one")
    precondition(rootTrail.current?.isCurrent == true, "which is the folder on screen")
    precondition(rootTrail.current?.isRoot == true, "and the root itself")
    precondition(rootTrail.current?.title == "This Device", "called what the page calls it")
    precondition(rootTrail.ancestors.isEmpty, "with nothing above it")

    // A link is browsed as what it leads to, so its trail is the target's.
    let alias = work.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: deep.path)
    guard let aliasLocation = FileBrowserLocation(url: alias) else {
        preconditionFailure("a link is a location at its target")
    }
    let aliasTrail = FileBrowserBreadcrumb(location: aliasLocation, rootTitle: "This Device")
    precondition(
        aliasTrail.segments.map(\.location.path) == trail.segments.map(\.location.path),
        "a link's trail is the target's, canonical"
    )
    precondition(
        !aliasTrail.segments.contains { $0.title == "alias" },
        "the link's own name is not a crumb"
    )

    // The page redraws the trail only when it is another one.
    precondition(
        trail == FileBrowserBreadcrumb(location: location, rootTitle: "This Device"),
        "the same folder is the same trail"
    )
    precondition(
        trail != FileBrowserBreadcrumb(location: location, rootTitle: "Device"),
        "another name for the root is another trail"
    )

    // A long name is kept whole — VoiceOver reads it — and can only be drawn
    // as wide as the path area allows.
    let longName = String(repeating: "folder-", count: 30)
    let long = work.appendingPathComponent(longName, isDirectory: true)
    try FileManager.default.createDirectory(at: long, withIntermediateDirectories: true)
    guard let longLocation = FileBrowserLocation(url: long) else {
        preconditionFailure("a long name is a location too")
    }
    let longTrail = FileBrowserBreadcrumb(location: longLocation, rootTitle: "This Device")
    precondition(longTrail.current?.title == longName, "the whole name is kept")
    precondition(longName.count > 100 && longName.count < 255, "and it is a name the file system holds")

    // How wide one name may be drawn: a share of a narrow path area, at most
    // the maximum, never under a full touch target. A bar not laid out yet
    // takes the maximum.
    precondition(
        FileBrowserBreadcrumbLayout.titleWidthLimit(available: 0) == FileBrowserBreadcrumbLayout.maximumTitleWidth,
        "a bar with no width yet takes the maximum"
    )
    precondition(
        FileBrowserBreadcrumbLayout.titleWidthLimit(available: 2000) == FileBrowserBreadcrumbLayout.maximumTitleWidth,
        "a wide screen does not draw one name wider than the maximum"
    )
    precondition(
        FileBrowserBreadcrumbLayout.titleWidthLimit(available: 320) == 192,
        "a narrow screen gives one name a share of it"
    )
    precondition(
        FileBrowserBreadcrumbLayout.titleWidthLimit(available: 40) == FileBrowserBreadcrumbLayout.minimumTarget,
        "and never a width under the touch target"
    )
    for width in stride(from: CGFloat(0), through: 1400, by: 40) {
        let limit = FileBrowserBreadcrumbLayout.titleWidthLimit(available: width)
        precondition(limit >= FileBrowserBreadcrumbLayout.minimumTarget, "a name is always hittable")
        precondition(limit <= FileBrowserBreadcrumbLayout.maximumTitleWidth, "and never the whole bar")
    }

    // Moving sideways: once for each folder the trail comes to show, and never
    // for that folder drawn again — a reload keeps the reader's position.
    var reveal = FileBrowserBreadcrumbReveal()
    precondition(reveal.shouldReveal(trail.current!.location.path), "the first trail is brought into view")
    precondition(!reveal.shouldReveal(trail.current!.location.path), "reloading it is not")
    precondition(!reveal.shouldReveal(trail.current!.location.path), "and neither is reloading it again")
    precondition(reveal.shouldReveal(root.path), "another folder is")
    precondition(reveal.shouldReveal(trail.current!.location.path), "and coming back to one is")

    print("ok: the path trail runs root to current, is canonical, and moves only for another folder")
}
