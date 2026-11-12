import Foundation

/// The row and the list's height estimate use the same vertical geometry.
/// A gap separates two visible parts; it never stands in for a hidden one.
struct ChatActivityLayout {
    let sourceY: CGFloat
    let titleY: CGFloat
    let bannerY: CGFloat
    let stepsY: CGFloat
    let height: CGFloat

    init(source: CGFloat, title: CGFloat, banner: CGFloat, steps: CGFloat,
         top: CGFloat, bottom: CGFloat) {
        let source = max(0, source)
        let title = max(0, title)
        let banner = max(0, banner)
        let steps = max(0, steps)
        let hasContent = source > 0 || title > 0 || banner > 0 || steps > 0
        var y: CGFloat = hasContent ? top : 0
        sourceY = y
        y += source
        if source > 0, title > 0 || banner > 0 || steps > 0 { y += 4 }
        titleY = y
        y += title
        if title > 0, banner > 0 { y += 8 }
        bannerY = y
        y += banner
        if steps > 0, title > 0 || banner > 0 { y += 10 }
        stepsY = y
        y += steps
        height = hasContent ? y + bottom : 0
    }
}
