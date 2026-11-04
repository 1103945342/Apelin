import SnapKit
import Then
import UIKit

/// The Git screen's page switch: the platform's own segmented control,
/// centred at the bottom of the page inside a Liquid Glass capsule.
///
/// The reference app grew its own floating bar; here the platform draws the
/// control, so a reader gets the system's materials, motion, Dynamic Type
/// and VoiceOver behaviour without the page imitating any of them.
final class GitGlassTabs: UIView {
    /// Called when the reader picks a segment.
    var onSelect: ((Int) -> Void)?

    private let glass = UIVisualEffectView()
    private let control: UISegmentedControl

    init(titles: [String]) {
        control = UISegmentedControl(items: titles)
        super.init(frame: .zero)

        if #available(iOS 26.0, *) {
            glass.effect = UIGlassEffect(style: .regular)
        } else {
            glass.effect = UIBlurEffect(style: .systemThickMaterial)
        }
        glass.layer.cornerRadius = 23
        glass.layer.cornerCurve = .continuous
        glass.clipsToBounds = true
        glass.contentView.backgroundColor = .clear
        addSubview(glass)
        glass.snp.makeConstraints { make in make.edges.equalToSuperview() }

        control.selectedSegmentIndex = UISegmentedControl.noSegment
        control.backgroundColor = .clear
        control.addTarget(self, action: #selector(selectionChanged), for: .valueChanged)
        control.setTitleTextAttributes(
            [.font: GitTheme.font(13, .semibold)], for: .selected,
        )
        control.setTitleTextAttributes(
            [.font: GitTheme.font(13, .regular)], for: .normal,
        )
        glass.contentView.addSubview(control)
        control.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(UIEdgeInsets(top: 7, left: 7, bottom: 7, right: 7))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The segment that is shown, without telling the reader's handler.
    func select(_ index: Int) {
        guard index >= 0, index < control.numberOfSegments, control.selectedSegmentIndex != index else { return }
        control.selectedSegmentIndex = index
    }

    @objc private func selectionChanged() {
        onSelect?(control.selectedSegmentIndex)
    }
}
