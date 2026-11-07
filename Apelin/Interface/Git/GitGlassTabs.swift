import SnapKit
import Then
import UIKit

/// The system segmented control on the same native/legacy glass as the rest
/// of the app. The background never owns or intercepts the control's touches.
final class GitGlassTabs: UIView {
    /// Called when the reader picks a segment.
    var onSelect: ((Int) -> Void)?

    private let glass = GlassSurfaceView(cornerRadius: 23)
    private let control: UISegmentedControl

    init(titles: [String]) {
        control = UISegmentedControl(items: titles)
        super.init(frame: .zero)

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
        addSubview(control)
        control.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(UIEdgeInsets(top: 7, left: 7, bottom: 7, right: 7))
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The segment that is shown, without telling the reader's handler.
    func select(_ index: Int) {
        guard index >= 0, index < control.numberOfSegments, control.selectedSegmentIndex != index else { return }
        control.selectedSegmentIndex = index
    }

    @objc private func selectionChanged() {
        onSelect?(control.selectedSegmentIndex)
    }
}
