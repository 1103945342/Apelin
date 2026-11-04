import SnapKit
import UIKit

/// A ground made of the system's glass, the material the composer and the
/// buttons in the chat already sit on.
///
/// On iOS 26 that is `UIGlassEffect` itself; before it there is no glass to
/// ask for, so a blur stands in, and the sidebar reads as a material rather
/// than a flat grey panel either way. The effect view is what carries the
/// corner radius: a corner on this view would clip nothing, since the
/// material is drawn by its subview.
final class GlassSurfaceView: UIView {
    /// Never interactive: the controls that press sit above it, so the
    /// effect view would never see the touch it answers.
    init(cornerRadius: CGFloat = 0) {
        super.init(frame: .zero)
        let effectView = UIVisualEffectView()
        if #available(iOS 26, *) {
            effectView.effect = UIGlassEffect()
        } else {
            effectView.effect = UIBlurEffect(style: .systemChromeMaterial)
        }
        effectView.layer.cornerRadius = cornerRadius
        effectView.layer.cornerCurve = .continuous
        effectView.clipsToBounds = true
        addSubview(effectView)
        effectView.snp.makeConstraints { x in x.edges.equalToSuperview() }
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
