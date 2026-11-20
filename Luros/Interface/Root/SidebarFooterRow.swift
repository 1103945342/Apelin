import SnapKit
import Then
import UIKit

/// The one row at the foot of the sidebar, as aimini's drawer has there: a
/// card the width of the page holding the way out to Settings.
///
/// A card rather than a bar button, because the pages above it scroll and a
/// bar button would slide away with them; the reader is as likely to want
/// Settings while reading a file as while reading a conversation.
final class SidebarFooterRow: UIView {
    private let action: () -> Void

    init(symbol: String, title: String, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        let glass = GlassSurfaceView(cornerRadius: 12)
        addSubview(glass)
        glass.snp.makeConstraints { x in x.edges.equalToSuperview() }

        let icon = UIImageView(image: UIImage(systemName: symbol)).then {
            $0.tintColor = .label
            $0.contentMode = .scaleAspectFit
            $0.setContentHuggingPriority(.required, for: .horizontal)
        }
        let label = UILabel().then {
            $0.text = title
            $0.font = UIFont.preferredFont(forTextStyle: .body)
            $0.textColor = .label
            $0.adjustsFontForContentSizeCategory = true
        }
        let chevron = UIImageView(image: UIImage(systemName: "chevron.forward")).then {
            $0.tintColor = .tertiaryLabel
            $0.contentMode = .scaleAspectFit
            $0.setContentHuggingPriority(.required, for: .horizontal)
        }

        let button = UIButton(type: .system).then {
            $0.accessibilityLabel = title
            $0.addAction(
                UIAction { [weak self] _ in self?.action() },
                for: .touchUpInside,
            )
        }

        addSubview(icon)
        addSubview(label)
        addSubview(chevron)
        addSubview(button)
        bringSubviewToFront(icon)
        bringSubviewToFront(label)
        bringSubviewToFront(chevron)
        bringSubviewToFront(button)

        icon.snp.makeConstraints { x in
            x.leading.equalToSuperview().offset(14)
            x.centerY.equalToSuperview()
            x.size.equalTo(20)
        }
        label.snp.makeConstraints { x in
            x.leading.equalTo(icon.snp.trailing).offset(12)
            x.centerY.equalToSuperview()
            x.trailing.lessThanOrEqualTo(chevron.snp.leading).offset(-8)
        }
        chevron.snp.makeConstraints { x in
            x.trailing.equalToSuperview().offset(-14)
            x.centerY.equalToSuperview()
            x.size.equalTo(13)
        }
        button.snp.makeConstraints { x in x.edges.equalToSuperview() }
        snp.makeConstraints { x in x.height.equalTo(48) }

        // The row already says what it does; the label beside the symbol
        // would be read twice.
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
