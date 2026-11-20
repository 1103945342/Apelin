import Foundation

/// Leading-to-trailing slots. Even at accessibility sizes or in a narrow
/// pane the token view never includes the disclosure's reserved rectangle.
struct ChatHeaderLayout {
    let stateWidth: CGFloat
    let tokensX: CGFloat
    let tokensWidth: CGFloat
    let chevronX: CGFloat
    let chevronWidth: CGFloat

    init(width: CGFloat, stateWidth: CGFloat, showsTokens: Bool) {
        let width = max(0, width)
        chevronWidth = min(14, width)
        chevronX = width - chevronWidth
        let end = max(0, chevronX - 6)
        self.stateWidth = min(max(0, stateWidth), showsTokens ? max(0, end - 6) / 2 : end)
        tokensX = min(end, self.stateWidth + 6)
        tokensWidth = max(0, end - tokensX)
    }
}
