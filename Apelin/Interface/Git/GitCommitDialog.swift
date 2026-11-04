import SnapKit
import Then
import UIKit

/// The commit dialog: a title row with the generate button at its end, the
/// conventional-type chips, the message field and the amend row, closed by
/// Cancel and Commit as the reference app closes it.
final class GitCommitDialogController: UIViewController {
    private let staged: [GitFileItem]
    private let hasIdentity: Bool
    private let onCommit: (String, Bool) -> Void

    private let chips = UIScrollView()
    private let chipRow = UIStackView()
    private let field = UITextView()
    private let placeholder = UILabel()
    private let amendSwitch = UISwitch()
    private let generateButton = UIButton(type: .system)
    private var generating = false {
        didSet { updateGenerateButton() }
    }

    private let commitButton = GitGlassButton.make(
        title: String(localized: "Commit"), prominent: true
    )
    private let types = ["feat", "fix", "refactor", "chore", "docs", "style", "perf", "test"]

    init(staged: [GitFileItem], hasIdentity: Bool, onCommit: @escaping (String, Bool) -> Void) {
        self.staged = staged
        self.hasIdentity = hasIdentity
        self.onCommit = onCommit
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
        }

        let title = UILabel().then {
            $0.text = String(localized: "Commit Changes")
            $0.font = GitTheme.font(24, .semibold)
            $0.textColor = GitTheme.onSurface
            $0.accessibilityTraits = .header
        }

        var generateConfiguration = UIButton.Configuration.plain()
        generateConfiguration.image = GitIcon.image(GitIcon.Name.zap, pointSize: 13)
        generateConfiguration.imagePadding = 4
        generateConfiguration.title = String(localized: "AI Generate")
        generateConfiguration.baseForegroundColor = GitTheme.primary
        generateConfiguration.background.backgroundColor = GitTheme.primaryContainer.withAlphaComponent(0.65)
        generateConfiguration.background.cornerRadius = 12
        generateConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 8, bottom: 5, trailing: 10)
        generateButton.configuration = generateConfiguration
        generateButton.titleLabel?.font = GitTheme.labelSmall
        generateButton.addAction(UIAction { [weak self] _ in self?.generate() }, for: .touchUpInside)
        generateButton.accessibilityLabel = String(localized: "AI Generate")

        let titleRow = UIStackView(arrangedSubviews: [title, generateButton]).then {
            $0.axis = .horizontal
            $0.alignment = .center
            $0.spacing = 8
        }

        // The chips: one conventional prefix each, scrolled sideways.
        chipRow.axis = .horizontal
        chipRow.spacing = GitTheme.Space.xs
        for type in types {
            var configuration = UIButton.Configuration.plain()
            configuration.title = type
            configuration.baseForegroundColor = GitTheme.onSurfaceVariant
            configuration.background.backgroundColor = GitTheme.surfaceVariant.withAlphaComponent(0.35)
            configuration.background.strokeColor = GitTheme.outlineVariant.withAlphaComponent(0.35)
            configuration.background.strokeWidth = 1
            configuration.background.cornerRadius = 10
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10)
            let chip = UIButton(configuration: configuration)
            chip.titleLabel?.font = GitTheme.mono(11)
            chip.addAction(UIAction { [weak self] _ in self?.apply(type: type) }, for: .touchUpInside)
            chipRow.addArrangedSubview(chip)
        }
        chips.addSubview(chipRow)
        chipRow.snp.makeConstraints { make in
            make.edges.equalTo(chips.contentLayoutGuide)
            make.height.equalTo(chips.frameLayoutGuide)
        }
        chips.showsHorizontalScrollIndicator = false
        chips.snp.makeConstraints { make in make.height.equalTo(32) }

        let fieldBorder = UIView().then {
            $0.layer.borderWidth = 1
            $0.layer.borderColor = GitTheme.outline.cgColor
            $0.layer.cornerRadius = GitTheme.Radius.mdLarge
            $0.layer.cornerCurve = .continuous
        }
        field.font = GitTheme.bodyMedium
        field.textColor = GitTheme.onSurface
        field.tintColor = GitTheme.primary
        field.backgroundColor = .clear
        field.textContainerInset = UIEdgeInsets(top: 14, left: 10, bottom: 10, right: 10)
        field.isScrollEnabled = true
        field.autocorrectionType = .no
        field.delegate = self
        placeholder.text = String(localized: "Commit message")
        placeholder.font = GitTheme.bodyMedium
        placeholder.textColor = GitTheme.onSurfaceVariant
        fieldBorder.addSubview(field)
        fieldBorder.addSubview(placeholder)
        field.snp.makeConstraints { make in make.edges.equalToSuperview() }
        placeholder.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(14)
            make.top.equalToSuperview().offset(14)
        }
        fieldBorder.snp.makeConstraints { make in make.height.equalTo(96) }

        let amendLabel = UILabel().then {
            $0.text = String(localized: "Amend last commit (--amend)")
            $0.font = GitTheme.bodySmall
            $0.textColor = GitTheme.onSurface
        }
        let amendRow = UIView().then {
            $0.backgroundColor = GitTheme.mutedSurface
            $0.layer.cornerRadius = GitTheme.Radius.md
            $0.layer.cornerCurve = .continuous
        }
        amendSwitch.onTintColor = GitTheme.primary
        amendRow.addSubview(amendLabel)
        amendRow.addSubview(amendSwitch)
        amendLabel.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(GitTheme.Space.md)
            make.top.bottom.equalToSuperview().inset(GitTheme.Space.sm)
            make.trailing.lessThanOrEqualTo(amendSwitch.snp.leading).offset(-8)
        }
        amendSwitch.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-GitTheme.Space.md)
            make.centerY.equalToSuperview()
        }

        let messageBox = UIView()
        messageBox.addSubview(fieldBorder)
        fieldBorder.snp.makeConstraints { make in make.edges.equalToSuperview() }

        let cancel = GitGlassButton.make(title: String(localized: "Cancel"))
        cancel.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        commitButton.addAction(UIAction { [weak self] _ in self?.commit() }, for: .touchUpInside)
        let buttons = UIStackView(arrangedSubviews: [cancel, commitButton]).then {
            $0.axis = .horizontal
            $0.spacing = GitTheme.Space.sm
            $0.alignment = .fill
            $0.distribution = .fillEqually
        }

        let stack = UIStackView(arrangedSubviews: [
            titleRow, chips, messageBox, amendRow, buttons
        ]).then {
            $0.axis = .vertical
            $0.spacing = 16
        }
        stack.setCustomSpacing(14, after: titleRow)
        stack.setCustomSpacing(12, after: chips)
        view.addSubview(stack)
        stack.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide).offset(GitTheme.Space.md)
            make.leading.trailing.equalToSuperview().inset(GitTheme.Space.lg)
        }
        updateCommit()
    }

    @objc private func dismissSelf() {
        dismiss(animated: true)
    }

    private func messageText() -> String {
        field.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func apply(type: String) {
        let current = field.text ?? ""
        let prefix = "\(type): "
        if let range = current.range(of: ": ") {
            field.text = prefix + current[range.upperBound...]
        } else {
            field.text = prefix + current
        }
        textChanged()
    }

    private func generate() {
        guard !generating, hasIdentity else { return }
        generating = true
        // A local suggestion from what is staged. The reference app asks its
        // model with the staged diff; Apelin's app has no model of its own,
        // so the button composes the message the diff already names.
        let names = staged.map { ($0.entry.path as NSString).lastPathComponent }
        let type: String
        if staged.contains(where: { $0.code == "A" || $0.code == "?" }) {
            type = "feat"
        } else if staged.contains(where: { $0.code == "D" }) {
            type = "chore"
        } else {
            type = "fix"
        }
        let spoken: String
        if names.count == 1, let first = names.first {
            spoken = "update \(first)"
        } else {
            spoken = "update \(names.count) files"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self else { return }
            self.field.text = "\(type): \(spoken)"
            self.generating = false
            self.textChanged()
        }
    }

    private func updateGenerateButton() {
        var configuration = generateButton.configuration
        configuration?.title = generating
            ? String(localized: "Generating…")
            : String(localized: "AI Generate")
        configuration?.baseBackgroundColor = generating
            ? GitTheme.primary.withAlphaComponent(0.12)
            : GitTheme.primaryContainer.withAlphaComponent(0.65)
        configuration?.image = generating ? nil : GitIcon.image(GitIcon.Name.zap, pointSize: 13)
        generateButton.configuration = configuration
        generateButton.isEnabled = !generating
        updateCommit()
    }

    private func updateCommit() {
        commitButton.isEnabled = !messageText().isEmpty && !generating
    }

    private func textChanged() {
        placeholder.isHidden = !(field.text ?? "").isEmpty
        updateCommit()
    }

    private func commit() {
        let message = messageText()
        guard !message.isEmpty else { return }
        dismiss(animated: true) { [onCommit] in
            onCommit(message, self.amendSwitch.isOn)
        }
    }
}

extension GitCommitDialogController: UITextViewDelegate {
    func textViewDidChange(_: UITextView) {
        textChanged()
    }
}

/// The stash sheet's content: saving a stash, and the list of the ones there
/// are, each with Pop, Apply and Drop.
final class GitStashSheetContent: UIView {
    private let stashes: [GitStash]
    private let hasChanges: Bool
    private let busy: Bool
    private let onSave: (String?, Bool) -> Void
    private let onPop: (GitStash) -> Void
    private let onApply: (GitStash) -> Void
    private let onDrop: (GitStash) -> Void
    private let onClear: () -> Void

    private let saveButton = GitButtons.tonal(title: String(localized: "Stash Changes"), symbol: GitIcon.Name.archive, height: 40)
    private let messageField = GitTextField(label: String(localized: "Stash message (optional)"))
    private let includeUntracked = GitSwitchRow(title: String(localized: "Include untracked files (-u)"))

    init(
        stashes: [GitStash],
        hasChanges: Bool,
        busy: Bool,
        onSave: @escaping (String?, Bool) -> Void,
        onPop: @escaping (GitStash) -> Void,
        onApply: @escaping (GitStash) -> Void,
        onDrop: @escaping (GitStash) -> Void,
        onClear: @escaping () -> Void
    ) {
        self.stashes = stashes
        self.hasChanges = hasChanges
        self.busy = busy
        self.onSave = onSave
        self.onPop = onPop
        self.onApply = onApply
        self.onDrop = onDrop
        self.onClear = onClear
        super.init(frame: .zero)

        let header = UIView()
        let title = UILabel().then {
            $0.text = String(localized: "Stashes")
            $0.font = GitTheme.titleMedium
            $0.textColor = GitTheme.onSurface
            $0.accessibilityTraits = .header
        }
        header.addSubview(title)
        if !stashes.isEmpty {
            let clear = GitButtons.text(title: String(localized: "Clear All"))
            clear.tintColor = GitTheme.error
            var configuration = clear.configuration
            configuration?.baseForegroundColor = GitTheme.error
            clear.configuration = configuration
            clear.addAction(UIAction { [weak self] _ in self?.onClear() }, for: .touchUpInside)
            header.addSubview(clear)
            clear.snp.makeConstraints { make in
                make.trailing.centerY.equalToSuperview()
            }
            title.snp.makeConstraints { make in
                make.leading.centerY.equalToSuperview()
                make.trailing.lessThanOrEqualTo(clear.snp.leading).offset(-8)
            }
        } else {
            title.snp.makeConstraints { make in
                make.leading.centerY.equalToSuperview()
            }
        }
        header.snp.makeConstraints { make in make.height.equalTo(36) }

        let saveCard = UIView().then {
            $0.backgroundColor = GitTheme.mutedSurface
            $0.layer.cornerRadius = GitTheme.Radius.mdLarge
            $0.layer.cornerCurve = .continuous
        }
        saveCard.addSubview(messageField)
        saveCard.addSubview(includeUntracked)
        saveCard.addSubview(saveButton)
        messageField.snp.makeConstraints { make in
            make.leading.trailing.top.equalToSuperview().inset(GitTheme.Space.md)
        }
        includeUntracked.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(GitTheme.Space.md)
            make.top.equalTo(messageField.snp.bottom).offset(GitTheme.Space.sm)
        }
        saveButton.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(GitTheme.Space.md)
            make.top.equalTo(includeUntracked.snp.bottom).offset(GitTheme.Space.sm)
            make.bottom.equalToSuperview().offset(-GitTheme.Space.md)
        }
        saveButton.isEnabled = !busy && hasChanges
        saveButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let message = self.messageField.text.trimmingCharacters(in: .whitespacesAndNewlines)
            self.onSave(message.isEmpty ? nil : message, self.includeUntracked.toggle.isOn)
        }, for: .touchUpInside)

        let list = UIStackView().then {
            $0.axis = .vertical
            $0.spacing = GitTheme.Space.xs
        }
        if stashes.isEmpty {
            let empty = UILabel().then {
                $0.text = String(localized: "No stashes found")
                $0.font = GitTheme.bodyMedium
                $0.textColor = GitTheme.onSurfaceVariant
                $0.textAlignment = .center
            }
            let wrapper = UIView()
            wrapper.addSubview(empty)
            empty.snp.makeConstraints { make in
                make.centerX.equalToSuperview()
                make.top.bottom.equalToSuperview().inset(GitTheme.Space.xl)
            }
            list.addArrangedSubview(wrapper)
        } else {
            for stash in stashes {
                list.addArrangedSubview(makeStashRow(stash))
            }
        }

        let stack = UIStackView(arrangedSubviews: [header, saveCard, list]).then {
            $0.axis = .vertical
            $0.spacing = GitTheme.Space.md
        }
        addSubview(stack)
        stack.snp.makeConstraints { make in
            make.edges.equalToSuperview()
            make.width.equalToSuperview()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func makeStashRow(_ stash: GitStash) -> UIView {
        let card = UIView().then {
            $0.backgroundColor = GitTheme.surfaceVariant.withAlphaComponent(0.35)
            $0.layer.cornerRadius = GitTheme.Radius.md
            $0.layer.cornerCurve = .continuous
        }
        let message = UILabel().then {
            $0.text = stash.message.isEmpty ? "stash@{\(stash.index)}" : stash.message
            $0.font = GitTheme.font(14, .medium)
            $0.textColor = GitTheme.onSurface
            $0.numberOfLines = 1
            $0.lineBreakMode = .byTruncatingTail
        }
        let trailing = UILabel().then {
            $0.text = stash.branch.isEmpty ? String(stash.commit.prefix(7)) : stash.branch
            $0.font = GitTheme.labelSmall
            $0.textColor = GitTheme.onSurfaceVariant
            $0.numberOfLines = 1
        }
        let index = UILabel().then {
            $0.text = "stash@{\(stash.index)}"
            $0.font = GitTheme.mono(11)
            $0.textColor = GitTheme.onSurfaceVariant
        }
        let pop = GitButtons.text(title: String(localized: "Pop"))
        let apply = GitButtons.text(title: String(localized: "Apply"))
        let drop = UIButton(type: .system)
        drop.setImage(GitIcon.image(GitIcon.Name.trash, pointSize: 15), for: .normal)
        drop.tintColor = GitTheme.error
        drop.accessibilityLabel = String(localized: "Drop")
        pop.addAction(UIAction { [weak self] _ in self?.onPop(stash) }, for: .touchUpInside)
        apply.addAction(UIAction { [weak self] _ in self?.onApply(stash) }, for: .touchUpInside)
        drop.addAction(UIAction { [weak self] _ in self?.onDrop(stash) }, for: .touchUpInside)

        let top = UIStackView(arrangedSubviews: [message, trailing]).then {
            $0.axis = .horizontal
            $0.spacing = 8
            $0.alignment = .center
        }
        let bottom = UIStackView(arrangedSubviews: [index, pop, apply, drop]).then {
            $0.axis = .horizontal
            $0.spacing = 2
            $0.alignment = .center
        }
        let stack = UIStackView(arrangedSubviews: [top, bottom]).then {
            $0.axis = .vertical
            $0.spacing = GitTheme.Space.xs
        }
        card.addSubview(stack)
        stack.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(GitTheme.Space.sm)
        }
        for control in [pop, apply, drop] {
            control.isEnabled = !busy
        }
        return card
    }
}
