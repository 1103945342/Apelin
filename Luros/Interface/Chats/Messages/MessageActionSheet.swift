import ApelinCore
import SnapKit
import UIKit

/// A message's choices — More's, Checkpoint & Rewind's — in a sheet of the
/// system's own: on iOS 26 its Liquid Glass shows through, the page's
/// background being clear, and before that the grouped background. Sized
/// to its choices on a phone, a form sheet of that height on a wider
/// window. A choice closes the sheet, then runs.
final class MessageActionSheet: UIViewController {
    struct Action {
        var title: String
        var subtitle: String?
        var symbol: String
        var destructive = false
        var enabled = true
        var handler: () -> Void
    }

    private let heading: String
    private let preview: String?
    private let actions: [Action]
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private static let margin: CGFloat = 20

    init(title: String, preview: String?, actions: [Action]) {
        heading = title
        self.preview = preview
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(title:preview:actions:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if #available(iOS 26, *) {
            view.backgroundColor = .clear
        } else {
            view.backgroundColor = .systemGroupedBackground
        }
        stack.axis = .vertical
        stack.spacing = 8
        let titleLabel = UILabel()
        titleLabel.text = heading
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        titleLabel.accessibilityTraits = .header
        stack.addArrangedSubview(titleLabel)
        if let preview, !preview.isEmpty {
            let previewLabel = UILabel()
            previewLabel.text = preview
            previewLabel.font = .preferredFont(forTextStyle: .subheadline)
            previewLabel.adjustsFontForContentSizeCategory = true
            previewLabel.textColor = .secondaryLabel
            previewLabel.numberOfLines = 2
            stack.addArrangedSubview(previewLabel)
        }
        stack.setCustomSpacing(16, after: stack.arrangedSubviews.last ?? titleLabel)
        for action in actions {
            stack.addArrangedSubview(button(for: action))
        }
        scrollView.alwaysBounceVertical = false
        view.addSubview(scrollView)
        scrollView.addSubview(stack)
        scrollView.snp.makeConstraints { make in
            make.edges.equalTo(view.safeAreaLayoutGuide)
        }
        stack.snp.makeConstraints { make in
            make.top.equalTo(scrollView.contentLayoutGuide).offset(24)
            make.bottom.equalTo(scrollView.contentLayoutGuide).offset(-16)
            make.leading.trailing.equalTo(scrollView.frameLayoutGuide).inset(Self.margin)
        }
    }

    private func button(for action: Action) -> UIButton {
        var configuration = UIButton.Configuration.gray()
        configuration.cornerStyle = .large
        configuration.image = UIImage(systemName: action.symbol)
        configuration.imagePlacement = .leading
        configuration.imagePadding = 12
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .body)
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
        configuration.titleAlignment = .leading
        configuration.titleLineBreakMode = .byWordWrapping
        configuration.subtitleLineBreakMode = .byWordWrapping
        let color: UIColor = action.destructive ? .systemRed : .label
        configuration.baseForegroundColor = color
        configuration.attributedTitle = AttributedString(action.title, attributes: AttributeContainer([
            .font: UIFont.preferredFont(forTextStyle: .body),
            .foregroundColor: color,
        ]))
        if let subtitle = action.subtitle {
            configuration.attributedSubtitle = AttributedString(subtitle, attributes: AttributeContainer([
                .font: UIFont.preferredFont(forTextStyle: .footnote),
                .foregroundColor: UIColor.secondaryLabel,
            ]))
        }
        let button = UIButton(configuration: configuration)
        button.contentHorizontalAlignment = .leading
        button.isEnabled = action.enabled
        let handler = action.handler
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            dismiss(animated: true) { handler() }
        }, for: .touchUpInside)
        return button
    }

    /// The height its choices take at `width`, the margins with them.
    private func contentHeight(width: CGFloat) -> CGFloat {
        loadViewIfNeeded()
        let fitted = stack.systemLayoutSizeFitting(
            CGSize(width: max(width - Self.margin * 2, 1), height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel,
        )
        return ceil(fitted.height) + 24 + 16
    }

    /// Presents `sheet` from `presenter`, sized as the type says.
    static func present(_ sheet: MessageActionSheet, from presenter: UIViewController) {
        let window = presenter.view.window
        let width = min(window?.bounds.width ?? 390, 540)
        if window?.traitCollection.horizontalSizeClass == .compact {
            sheet.modalPresentationStyle = .pageSheet
            if let controller = sheet.sheetPresentationController {
                controller.detents = [.custom(identifier: .init("content")) { [weak sheet] context in
                    guard let sheet else { return context.maximumDetentValue }
                    return min(context.maximumDetentValue, sheet.contentHeight(width: width))
                }]
                controller.prefersGrabberVisible = true
                controller.prefersEdgeAttachedInCompactHeight = true
            }
        } else {
            sheet.modalPresentationStyle = .formSheet
            sheet.preferredContentSize = CGSize(width: 480, height: sheet.contentHeight(width: 480))
        }
        presenter.present(sheet, animated: true)
    }
}

/// A message's or a reply's text, edited in a sheet: Save gives it to the
/// conversation, Cancel leaves it. The text view fills the sheet, on the
/// same glass as `MessageActionSheet`.
final class EditMessageSheet: UIViewController, UITextViewDelegate, UIAdaptivePresentationControllerDelegate {
    private let initialText: String
    private let onSave: (String) -> Void
    private let textView = UITextView()
    private var saveItem: UIBarButtonItem?
    private let allowsEmpty: Bool
    private let onCancel: (() -> Void)?
    @objc dynamic private var completed = false
    @objc dynamic private var committing = false
    /// A queue edit stays on screen if its atomic host update fails.
    var onCommit: ((String) async throws -> Void)?

    init(title: String, text: String, allowsEmpty: Bool = false, onCancel: (() -> Void)? = nil,
         onSave: @escaping (String) -> Void) {
        initialText = text
        self.allowsEmpty = allowsEmpty
        self.onCancel = onCancel
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(title:text:onSave:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if #available(iOS 26, *) {
            view.backgroundColor = .clear
        } else {
            view.backgroundColor = .systemBackground
        }
        textView.text = initialText
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        textView.delegate = self
        textView.accessibilityLabel = title
        view.addSubview(textView)
        textView.snp.makeConstraints { make in
            make.edges.equalTo(view.safeAreaLayoutGuide)
        }
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.cancelEditing()
            self?.dismiss(animated: true)
        })
        let save = UIBarButtonItem(systemItem: .save, primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            let text = textView.text ?? ""
            if let onCommit {
                guard !committing else { return }
                committing = true
                textView.isEditable = false
                saveItem?.isEnabled = false
                navigationItem.leftBarButtonItem?.isEnabled = false
                navigationController?.isModalInPresentation = true
                Task { @MainActor [self] in
                    defer {
                        self.committing = false
                        self.textView.isEditable = true
                        self.navigationItem.leftBarButtonItem?.isEnabled = true
                        self.navigationController?.isModalInPresentation = false
                        self.updateSave()
                    }
                    do {
                        try await onCommit(text)
                        self.completed = true
                        self.dismiss(animated: true)
                    } catch {
                        self.presentNotice(title: "Unable to Edit", message: error.readableMessage)
                    }
                }
            } else {
                completed = true
                dismiss(animated: true) { self.onSave(text) }
            }
        })
        saveItem = save
        navigationItem.rightBarButtonItem = save
        updateSave()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        textView.becomeFirstResponder()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true { cancelEditing() }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        cancelEditing()
    }

    @objc dynamic private func cancelEditing() {
        guard !completed else { return }
        completed = true
        onCancel?()
    }

    func textViewDidChange(_: UITextView) {
        updateSave()
    }

    /// Nothing changed, or nothing left, saves nothing.
    private func updateSave() {
        let text = textView.text ?? ""
        saveItem?.isEnabled = text != initialText && (allowsEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    static func present(_ sheet: EditMessageSheet, from presenter: UIViewController) {
        let navigation = UINavigationController(rootViewController: sheet)
        if #available(iOS 26, *) {
            let appearance = UINavigationBarAppearance()
            appearance.configureWithTransparentBackground()
            sheet.navigationItem.standardAppearance = appearance
            sheet.navigationItem.scrollEdgeAppearance = appearance
        }
        let window = presenter.view.window
        if window?.traitCollection.horizontalSizeClass == .compact {
            navigation.modalPresentationStyle = .pageSheet
            navigation.sheetPresentationController?.detents = [.medium(), .large()]
            navigation.sheetPresentationController?.prefersGrabberVisible = true
        } else {
            navigation.modalPresentationStyle = .formSheet
            navigation.preferredContentSize = CGSize(width: 540, height: 420)
        }
        navigation.presentationController?.delegate = sheet
        presenter.present(navigation, animated: true)
    }
}
