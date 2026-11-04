import SnapKit
import UIKit

/// The field both the conversations' page and the files' page put above
/// their list, as aimini's drawer does: a capsule that holds the magnifier,
/// the text and a clear button that is there whenever there is something to
/// clear.
///
/// No `UISearchBar`: this is not the system's search, which arrives and
/// leaves with a scroll and carries a Cancel button nothing here needs. It
/// stays put, because both lists are searched often enough that hiding it
/// behind a pull costs more than the row it takes.
final class SidebarSearchField: UIView {
    var onChange: ((String) -> Void)?

    var text: String {
        get { field.text ?? "" }
        set {
            field.text = newValue
            updateClearButton()
        }
    }

    private let field = UITextField().then {
        $0.borderStyle = .none
        $0.clearButtonMode = .never
        $0.returnKeyType = .search
        $0.autocorrectionType = .no
        $0.autocapitalizationType = .none
        $0.font = UIFont.preferredFont(forTextStyle: .callout)
        $0.textColor = .label
    }

    private lazy var clearButton = UIButton(type: .system).then {
        $0.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        $0.tintColor = .tertiaryLabel
        $0.accessibilityLabel = String(localized: "Clear Search")
        $0.isHidden = true
        $0.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                text = ""
                onChange?("")
                field.becomeFirstResponder()
            },
            for: .touchUpInside
        )
    }

    init(placeholder: String.LocalizationValue) {
        super.init(frame: .zero)
        field.placeholder = String(localized: placeholder)
        let glass = GlassSurfaceView(cornerRadius: 20)
        addSubview(glass)
        glass.snp.makeConstraints { x in x.edges.equalToSuperview() }
        // A capsule whatever it is laid out at.
        clipsToBounds = true

        let magnifier = UIImageView(image: UIImage(systemName: "magnifyingglass")).then {
            $0.tintColor = .secondaryLabel
            $0.contentMode = .scaleAspectFit
            $0.setContentHuggingPriority(.required, for: .horizontal)
        }

        addSubview(magnifier)
        addSubview(field)
        addSubview(clearButton)
        bringSubviewToFront(magnifier)
        bringSubviewToFront(field)
        bringSubviewToFront(clearButton)

        magnifier.snp.makeConstraints { x in
            x.leading.equalToSuperview().offset(12)
            x.centerY.equalToSuperview()
            x.size.equalTo(16)
        }
        field.snp.makeConstraints { x in
            x.leading.equalTo(magnifier.snp.trailing).offset(8)
            x.top.bottom.equalToSuperview()
            x.trailing.equalTo(clearButton.snp.leading).offset(-6)
        }
        clearButton.snp.makeConstraints { x in
            x.trailing.equalToSuperview().offset(-4)
            x.centerY.equalToSuperview()
            x.size.equalTo(28)
        }
        snp.makeConstraints { x in x.height.equalTo(40) }

        field.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                updateClearButton()
                onChange?(text)
            },
            for: .editingChanged
        )
        field.delegate = self
        // The capsule is one control to VoiceOver, not a box around one.
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func becomeFirstResponder() -> Bool {
        field.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        field.resignFirstResponder()
    }

    private func updateClearButton() {
        clearButton.isHidden = text.isEmpty
    }
}

extension SidebarSearchField: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}
