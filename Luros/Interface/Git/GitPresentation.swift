import AlertController
import SnapKit
import Then
import UIKit

extension UIConfigurationTextAttributesTransformer {
    /// The font a configuration's title keeps. A configuration lays its own
    /// title out, so a font set on `titleLabel` is gone the next time it
    /// does; this is the one place the font is stated instead.
    static func git(_ font: UIFont) -> Self {
        UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = font
            return outgoing
        }
    }
}

// The reference app's presentation pieces: a centred dialog, a bottom sheet,
// the outlined field and its switch, and the status badge. They are written
// once here so the status, branches and commits pages show the same thing.

// MARK: - Glass

/// The platform's own material: Liquid Glass where the system has it, a
/// thick material before that. The sheets and the controls in them sit on it.
final class GitGlassBackground: UIVisualEffectView {
    init(cornerRadius: CGFloat? = nil) {
        if #available(iOS 26.0, *) {
            super.init(effect: UIGlassEffect(style: .regular))
        } else {
            super.init(effect: UIBlurEffect(style: .systemThickMaterial))
        }
        isUserInteractionEnabled = false
        if let cornerRadius {
            layer.cornerRadius = cornerRadius
            layer.cornerCurve = .continuous
            clipsToBounds = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// The platform's glass button, in either weight.
enum GitGlassButton {
    static func configuration(prominent: Bool) -> UIButton.Configuration {
        if #available(iOS 26.0, *) {
            return prominent ? .prominentGlass() : .glass()
        }
        var configuration = prominent ? UIButton.Configuration.filled() : .gray()
        configuration.background.cornerRadius = 14
        configuration.cornerStyle = .fixed
        return configuration
    }

    /// A round glass button holding one glyph, for a bar's ends.
    static func icon(_ symbol: String, pointSize: CGFloat = 17, label: String) -> UIButton {
        var configuration = configuration(prominent: false)
        configuration.image = GitIcon.image(symbol, pointSize: pointSize)
        configuration.cornerStyle = .capsule
        configuration.baseForegroundColor = GitTheme.onSurface
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = label
        button.snp.makeConstraints { make in make.size.equalTo(40) }
        return button
    }

    /// A control with a word in it, on the sheet's glass.
    static func make(
        title: String,
        symbol: String? = nil,
        prominent: Bool = false,
        destructive: Bool = false,
    ) -> UIButton {
        var configuration = configuration(prominent: prominent)
        configuration.title = title
        configuration.image = symbol.flatMap { GitIcon.image($0, pointSize: 16) }
        configuration.imagePadding = 8
        configuration.baseForegroundColor = destructive
            ? GitTheme.error
            : prominent ? GitTheme.onPrimary : GitTheme.onSurface
        configuration.titleTextAttributesTransformer = .git(GitTheme.labelLarge)
        let button = UIButton(configuration: configuration)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.8
        return button
    }
}

// MARK: - Dialog

/// What a dialog offers: a word and what it runs.
struct GitDialogAction {
    let title: String
    var destructive = false
    let handler: () -> Void
}

/// A dialog with something to fill in or choose: the system's sheet, on the
/// platform's glass, with the actions as glass buttons under it.
final class GitFormSheetController: UIViewController {
    private let heading: String
    private let message: String?
    private let content: UIView
    private let actions: [GitDialogAction]

    init(title: String, message: String?, content: UIView, actions: [GitDialogAction]) {
        heading = title
        self.message = message
        self.content = content
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let glass = GitGlassBackground()
        view.addSubview(glass)
        glass.snp.makeConstraints { make in make.edges.equalToSuperview() }

        if let sheet = sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 28
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
            sheet.prefersEdgeAttachedInCompactHeight = true
        }

        let scroll = UIScrollView()
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceVertical = false
        let titleLabel = UILabel().then {
            $0.text = heading
            $0.font = GitTheme.font(22, .semibold)
            $0.adjustsFontForContentSizeCategory = true
            $0.textColor = GitTheme.onSurface
            $0.numberOfLines = 0
            $0.accessibilityTraits = .header
        }
        let stack = UIStackView(arrangedSubviews: [titleLabel]).then {
            $0.axis = .vertical
            $0.spacing = GitTheme.Space.md
        }
        if let message, !message.isEmpty {
            let label = UILabel().then {
                $0.text = message
                $0.font = GitTheme.bodyMedium
                $0.adjustsFontForContentSizeCategory = true
                $0.textColor = GitTheme.onSurfaceVariant
                $0.numberOfLines = 0
            }
            stack.addArrangedSubview(label)
        }
        stack.setCustomSpacing(GitTheme.Space.md, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(content)

        let buttons = UIStackView().then {
            $0.axis = .horizontal
            $0.spacing = GitTheme.Space.sm
            $0.alignment = .center
            $0.distribution = .fill
        }
        for (index, action) in actions.enumerated() {
            let button = GitGlassButton.make(
                title: action.title,
                prominent: index == actions.count - 1,
                destructive: action.destructive,
            )
            buttons.addArrangedSubview(button)
            button.addAction(UIAction { [weak self] _ in self?.run(action) }, for: .touchUpInside)
        }
        stack.setCustomSpacing(GitTheme.Space.lg, after: content)
        stack.addArrangedSubview(buttons)
        stack.alignment = .fill

        scroll.addSubview(stack)
        view.addSubview(scroll)
        stack.snp.makeConstraints { make in
            make.edges.equalTo(scroll.contentLayoutGuide)
            make.width.equalTo(scroll.frameLayoutGuide)
        }
        scroll.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide).offset(24)
            make.leading.trailing.equalToSuperview().inset(GitTheme.Space.lg)
            make.bottom.equalTo(view.safeAreaLayoutGuide).offset(-GitTheme.Space.lg)
        }
        stack.isLayoutMarginsRelativeArrangement = false
    }

    private func run(_ action: GitDialogAction) {
        dismiss(animated: true) { action.handler() }
    }
}

// MARK: - Bottom sheet

/// A sheet of rows or of content: the system's own sheet, so it is swiped
/// away, darkened and rounded the way every sheet on the platform is, with
/// the platform's glass under the controls and glass buttons for the rows.
class GitBottomSheetController: UIViewController {
    /// One tappable row inside a sheet, with its glyph and whether it is
    /// destructive.
    struct Row {
        let title: String
        let symbol: String
        var destructive = false
        let handler: () -> Void
    }

    private let sheetTitle: String?
    private let rows: [Row]
    private let contentView: UIView?
    private let scroll = UIScrollView()
    let stack = UIStackView()

    init(title: String? = nil, content: UIView? = nil, rows: [Row] = []) {
        sheetTitle = title
        contentView = content
        self.rows = rows
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let glass = GitGlassBackground()
        view.addSubview(glass)
        glass.snp.makeConstraints { make in make.edges.equalToSuperview() }

        if let sheet = sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 28
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
            sheet.prefersEdgeAttachedInCompactHeight = true
        }

        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.addSubview(stack)
        stack.axis = .vertical
        stack.spacing = GitTheme.Space.xs
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(
            top: GitTheme.Space.sm, left: GitTheme.Space.lg,
            bottom: GitTheme.Space.xl, right: GitTheme.Space.lg,
        )

        if let sheetTitle {
            let header = UIStackView().then {
                $0.axis = .horizontal
                $0.alignment = .center
                $0.spacing = GitTheme.Space.sm
            }
            let label = UILabel().then {
                $0.text = sheetTitle
                $0.font = GitTheme.font(20, .semibold)
                $0.adjustsFontForContentSizeCategory = true
                $0.textColor = GitTheme.onSurface
                $0.numberOfLines = 2
                $0.lineBreakMode = .byTruncatingMiddle
                $0.accessibilityTraits = .header
                $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            }
            var closeConfiguration = GitGlassButton.configuration(prominent: false)
            closeConfiguration.image = GitIcon.image(GitIcon.Name.close, pointSize: 14)
            closeConfiguration.cornerStyle = .capsule
            let close = UIButton(configuration: closeConfiguration)
            close.accessibilityLabel = String(localized: "Close")
            close.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
            header.addArrangedSubview(label)
            header.addArrangedSubview(close)
            close.snp.makeConstraints { make in make.size.equalTo(32) }
            stack.addArrangedSubview(header)
            stack.setCustomSpacing(GitTheme.Space.md, after: header)
        }
        if let contentView {
            stack.addArrangedSubview(contentView)
            stack.setCustomSpacing(GitTheme.Space.sm, after: contentView)
        }
        for row in rows {
            stack.addArrangedSubview(makeRow(row))
        }

        view.addSubview(scroll)
        scroll.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide).offset(GitTheme.Space.sm)
            make.leading.trailing.equalTo(view)
            make.bottom.equalTo(view.safeAreaLayoutGuide)
        }
        stack.snp.makeConstraints { make in
            make.edges.equalTo(scroll.contentLayoutGuide)
            make.width.equalTo(scroll.frameLayoutGuide)
        }
    }

    private func makeRow(_ row: Row) -> UIView {
        let button = GitGlassButton.make(
            title: row.title, symbol: row.symbol, destructive: row.destructive,
        )
        button.contentHorizontalAlignment = .leading
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.dismiss(animated: true) { row.handler() }
        }, for: .touchUpInside)
        return button
    }
}

// MARK: - Text field

/// The outlined field the reference app uses: a label on the border once the
/// field is active or filled, a rounded outline around it.
final class GitTextField: UIView, UITextFieldDelegate {
    let field = UITextField()
    private let label = UILabel()
    private let border = UIView()
    private var floating = false
    private var restingCenter: Constraint?
    private var floatingCenter: Constraint?

    var text: String {
        get { field.text ?? "" }
        set {
            field.text = newValue
            updateFloating(animated: false)
        }
    }

    init(label title: String, placeholder: String? = nil, secure: Bool = false) {
        super.init(frame: .zero)
        border.backgroundColor = .clear
        border.layer.borderWidth = 1
        border.layer.borderColor = GitTheme.outline.cgColor
        border.layer.cornerRadius = GitTheme.Radius.mdLarge
        border.layer.cornerCurve = .continuous
        border.isUserInteractionEnabled = false

        label.text = title
        label.font = GitTheme.labelSmall
        label.adjustsFontForContentSizeCategory = true
        label.textColor = GitTheme.onSurfaceVariant
        label.backgroundColor = GitTheme.cardSurface
        label.isUserInteractionEnabled = false

        field.font = GitTheme.bodyMedium
        field.adjustsFontForContentSizeCategory = true
        field.textColor = GitTheme.onSurface
        field.tintColor = GitTheme.primary
        field.placeholder = placeholder
        field.isSecureTextEntry = secure
        field.delegate = self
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.addTarget(self, action: #selector(editingChanged), for: .editingChanged)
        field.addTarget(self, action: #selector(beganEditing), for: .editingDidBegin)
        field.addTarget(self, action: #selector(endedEditing), for: .editingDidEnd)

        addSubview(border)
        addSubview(field)
        addSubview(label)
        border.snp.makeConstraints { make in make.edges.equalToSuperview() }
        field.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(GitTheme.Space.md + 4)
            make.top.equalToSuperview().offset(8)
            make.bottom.equalToSuperview().offset(-8)
            make.height.greaterThanOrEqualTo(24)
        }
        label.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(GitTheme.Space.md)
            make.height.equalTo(14)
            restingCenter = make.centerY.equalToSuperview().constraint
            floatingCenter = make.centerY.equalTo(border.snp.top).constraint
        }
        floatingCenter?.deactivate()
        snp.makeConstraints { make in make.height.equalTo(56) }
        let tap = UITapGestureRecognizer(target: self, action: #selector(focus))
        addGestureRecognizer(tap)
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        border.layer.borderColor = (floating ? GitTheme.primary : GitTheme.outline).cgColor
        label.backgroundColor = GitTheme.cardSurface
    }

    @objc private func focus() {
        field.becomeFirstResponder()
    }

    @objc private func beganEditing() {
        updateFloating(animated: true)
    }

    @objc private func endedEditing() {
        updateFloating(animated: true)
    }

    @objc private func editingChanged() {
        updateFloating(animated: true)
    }

    private func updateFloating(animated: Bool) {
        let shouldFloat = field.isFirstResponder || !(field.text ?? "").isEmpty
        guard shouldFloat != floating else { return }
        floating = shouldFloat
        restingCenter?.isActive = !shouldFloat
        floatingCenter?.isActive = shouldFloat
        border.layer.borderColor = (shouldFloat ? GitTheme.primary : GitTheme.outline).cgColor
        label.backgroundColor = GitTheme.cardSurface
        if animated {
            UIView.animate(withDuration: 0.16) { self.layoutIfNeeded() }
        }
    }
}

// MARK: - Toggle row

/// A word and a switch, the pair every sheet here uses for an option.
final class GitSwitchRow: UIView {
    let toggle = UISwitch()

    init(title: String, isOn: Bool = false) {
        super.init(frame: .zero)
        let label = UILabel().then {
            $0.text = title
            $0.font = GitTheme.bodySmall
            $0.adjustsFontForContentSizeCategory = true
            $0.textColor = GitTheme.onSurfaceVariant
            $0.numberOfLines = 0
        }
        toggle.isOn = isOn
        toggle.onTintColor = GitTheme.primary
        addSubview(label)
        addSubview(toggle)
        label.snp.makeConstraints { make in
            make.leading.top.bottom.equalToSuperview()
            make.trailing.lessThanOrEqualTo(toggle.snp.leading).offset(-12)
        }
        toggle.snp.makeConstraints { make in
            make.trailing.equalToSuperview()
            make.centerY.equalToSuperview()
        }
        snp.makeConstraints { make in make.height.greaterThanOrEqualTo(36) }
        isAccessibilityElement = false
        accessibilityElements = [label, toggle]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - Buttons

/// A copy button that confirms on itself.
final class GitCopyButton: UIButton {
    private let restingTitle: String
    private let run: () -> Void
    private var restoreWorkItem: DispatchWorkItem?

    init(title: String, action: @escaping () -> Void) {
        restingTitle = title
        run = action
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.baseForegroundColor = GitTheme.primary
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
        configuration.titleTextAttributesTransformer = .git(GitTheme.labelMedium)
        super.init(frame: .zero)
        self.configuration = configuration
        addAction(UIAction { [weak self] _ in self?.tapped() }, for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func tapped() {
        run()
        swap(to: String(localized: "Copied") + " ✅")
        restoreWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.swap(to: nil) }
        restoreWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// `nil` puts the resting word back. The word changes the way a count
    /// does: the old one fades out and the new one in, in place.
    private func swap(to text: String?) {
        var configuration = self.configuration
        configuration?.title = text ?? restingTitle
        UIView.transition(
            with: self,
            duration: 0.18,
            options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState],
        ) {
            self.configuration = configuration
        }
    }
}

enum GitButtons {
    /// The page's main button: filled, 46 pt, 12 pt corners.
    static func primary(title: String, symbol: String? = nil) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.image = symbol.flatMap { GitIcon.image($0, pointSize: 17) }
        configuration.imagePadding = GitTheme.Space.xs
        configuration.baseBackgroundColor = GitTheme.primary
        configuration.baseForegroundColor = GitTheme.onPrimary
        configuration.background.cornerRadius = 12
        configuration.cornerStyle = .fixed
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
        configuration.titleTextAttributesTransformer = .git(GitTheme.labelLarge)
        let button = UIButton(configuration: configuration)
        button.snp.makeConstraints { make in make.height.equalTo(46) }
        return button
    }

    /// A secondary action, a soft card-coloured button.
    static func action(title: String, symbol: String) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.image = GitIcon.image(symbol, pointSize: 15)
        configuration.imagePadding = GitTheme.Space.xs
        configuration.baseBackgroundColor = GitTheme.buttonMutedBackground
        configuration.baseForegroundColor = GitTheme.onSurface
        configuration.background.cornerRadius = 12
        configuration.cornerStyle = .fixed
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
        configuration.titleTextAttributesTransformer = .git(GitTheme.labelMedium)
        let button = UIButton(configuration: configuration)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.8
        button.snp.makeConstraints { make in make.height.equalTo(40) }
        return button
    }

    /// A tonal button: a light container, the accent's ink.
    static func tonal(title: String, symbol: String? = nil, height: CGFloat = 40) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.image = symbol.flatMap { GitIcon.image($0, pointSize: 16) }
        configuration.imagePadding = GitTheme.Space.xs
        configuration.baseBackgroundColor = GitTheme.secondaryContainer
        configuration.baseForegroundColor = GitTheme.onSecondaryContainer
        configuration.background.cornerRadius = 12
        configuration.cornerStyle = .fixed
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
        configuration.titleTextAttributesTransformer = .git(GitTheme.labelLarge)
        let button = UIButton(configuration: configuration)
        button.snp.makeConstraints { make in make.height.equalTo(height) }
        return button
    }

    /// An outlined button on the page background.
    static func outlined(title: String, symbol: String? = nil) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.image = symbol.flatMap { GitIcon.image($0, pointSize: 18) }
        configuration.imagePadding = GitTheme.Space.xs
        configuration.baseForegroundColor = GitTheme.primary
        configuration.background.cornerRadius = 12
        configuration.background.strokeColor = GitTheme.outline
        configuration.background.strokeWidth = 1
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        configuration.titleTextAttributesTransformer = .git(GitTheme.labelLarge)
        let button = UIButton(configuration: configuration)
        return button
    }

    /// A word that copies something: tapped, it says it copied, then goes
    /// back to what it was a second later — the button itself is the answer,
    /// so nothing is put over the page.
    static func copy(title: String, action: @escaping () -> Void) -> UIButton {
        let button = GitCopyButton(title: title, action: action)
        return button
    }

    /// A word at the end of a group's header.
    static func text(title: String) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.baseForegroundColor = GitTheme.primary
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
        configuration.titleTextAttributesTransformer = .git(GitTheme.labelMedium)
        let button = UIButton(configuration: configuration)
        return button
    }
}

// MARK: - Small views

/// The 32×20 badge in front of a changed path.
final class GitStatusChip: UIView {
    init(code: String) {
        super.init(frame: .zero)
        let colors = GitTheme.statusColors(code)
        backgroundColor = colors.background
        layer.cornerRadius = 10
        let label = UILabel().then {
            $0.text = String(code.prefix(2))
            $0.font = GitTheme.mono(11, .medium)
            $0.adjustsFontForContentSizeCategory = true
            $0.textColor = colors.foreground
            $0.textAlignment = .center
        }
        addSubview(label)
        label.snp.makeConstraints { make in make.edges.equalToSuperview() }
        snp.makeConstraints { make in
            make.width.equalTo(32)
            make.height.equalTo(20)
        }
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// A group's quiet heading.
final class GitSectionHeaderView: UIView {
    private let label = UILabel()

    init(title: String) {
        super.init(frame: .zero)
        label.text = title
        label.font = GitTheme.font(13, .regular)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = GitTheme.subtleText
        label.numberOfLines = 1
        addSubview(label)
        label.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(GitTheme.Space.lg)
            make.trailing.equalToSuperview().offset(-GitTheme.Space.lg)
            make.top.equalToSuperview().offset(GitTheme.Space.lg)
            make.bottom.equalToSuperview().offset(-GitTheme.Space.xs)
        }
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityTraits = .header
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

extension UIViewController {
    /// Presents a dialog over whatever is on screen, whichever sheet it is.
    func presentGitDialog(
        title: String,
        message: String? = nil,
        content: UIView? = nil,
        actions: [GitDialogAction],
    ) {
        guard let content else {
            presentGitAlert(title: title, message: message, actions: actions)
            return
        }
        let sheet = GitFormSheetController(title: title, message: message, content: content, actions: actions)
        topPresenter.present(sheet, animated: true)
    }

    /// A question with nothing to fill in: the app's own alert, drawn like every
    /// other question it asks. The buttons keep the page's order with the last
    /// one filled, and a delete is painted in the delete colour.
    private func presentGitAlert(title: String, message: String?, actions: [GitDialogAction]) {
        let accent = AlertControllerConfiguration.accentColor
        let accentForeground = AlertControllerConfiguration.accentForegroundColor
        if actions.contains(where: \.destructive) {
            AlertControllerConfiguration.accentColor = .systemRed
            AlertControllerConfiguration.accentForegroundColor = .white
        }
        let alert = AlertViewController(
            title: String.LocalizationValue(title),
            message: String.LocalizationValue(message ?? ""),
        ) { context in
            for (index, action) in actions.enumerated() {
                let button = String.LocalizationValue(action.title)
                if index == actions.count - 1 {
                    context.addAction(title: button, attribute: .accent) {
                        context.dispose { action.handler() }
                    }
                } else {
                    context.addAction(title: button) {
                        context.dispose { action.handler() }
                    }
                }
            }
        }
        topPresenter.present(alert, animated: true) {
            AlertControllerConfiguration.accentColor = accent
            AlertControllerConfiguration.accentForegroundColor = accentForeground
        }
    }

    func presentGitSheet(
        title: String? = nil,
        content: UIView? = nil,
        rows: [GitBottomSheetController.Row] = [],
    ) {
        let sheet = GitBottomSheetController(title: title, content: content, rows: rows)
        topPresenter.present(sheet, animated: true)
    }

    /// The controller a dialog or sheet should come from: presented sheets
    /// have their own presenter, and presenting from underneath them drops it.
    private var topPresenter: UIViewController {
        var top: UIViewController = self
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            if let navigation = presented as? UINavigationController, let last = navigation.viewControllers.last {
                top = last
            } else {
                top = presented
            }
        }
        return top
    }
}
