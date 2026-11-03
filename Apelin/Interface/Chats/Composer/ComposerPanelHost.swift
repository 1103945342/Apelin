import Combine
import UIKit

/// One panel that opens above the composer: a card that holds a header and a
/// body, grows into place, and gets out of the way when something else opens.
///
/// The bands belong to the composer, so a panel takes its room from the row it
/// sits in rather than from a window of its own.
class ComposerPanel: UIView {
    /// How tall the panel wants to be, header and body together. Zero keeps it
    /// out of the layout entirely.
    let heightPublisher: CurrentValueSubject<CGFloat, Never> = .init(0)
    var cancellables: Set<AnyCancellable> = .init()

    /// What a caller tells a panel to do when another one opens.
    var collapseAction: (() -> Void)?

    /// A panel opens only when something asks it to. It starts folded, with
    /// the height it publishes at zero, so the first tap on the control that
    /// opens it does what it says rather than folding what was never there.
    private(set) var isExpanded = false {
        didSet { updateExpansion() }
    }

    /// Set by the host when the composer is covered by something else: the
    /// panel stays built, and draws nothing.
    var isSuppressed = false {
        didSet { updateExpansion() }
    }

    let header = UIControl()
    let titleLabel = UILabel()
    let chevron = UIImageView()
    let body = UIView()

    private var wasExpandedBeforeSuppressing = true

    required init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        clipsToBounds = false

        backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = ComposerMetrics.Radius.lg
        layer.cornerCurve = .continuous
        layer.borderWidth = 1 / UIScreen.main.scale
        layer.borderColor = UIColor.separator.cgColor

        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.textColor = .secondaryLabel
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 1

        chevron.image = UIImage(systemName: "chevron.down")
        chevron.tintColor = .tertiaryLabel
        chevron.contentMode = .scaleAspectFit
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(scale: .small)

        header.isAccessibilityElement = true
        header.accessibilityTraits = .button
        header.addTarget(self, action: #selector(toggled), for: .primaryActionTriggered)

        for view in [header, body] {
            addSubview(view)
        }
        header.addSubview(titleLabel)
        header.addSubview(chevron)

        initializeViews()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    /// Builds what the body holds. Overrides call `super` first.
    func initializeViews() {}

    /// The header's sentence, drawn and read.
    func setTitle(_ text: String) {
        titleLabel.text = text
        header.accessibilityLabel = text
    }

    /// Whether a tap can fold it: a panel with nothing to hide says no.
    func setCollapsible(_ collapsible: Bool) {
        header.isUserInteractionEnabled = collapsible
        header.accessibilityTraits = collapsible ? .button : .staticText
        chevron.isHidden = !collapsible
    }

    func setExpanded(_ expanded: Bool) {
        guard isExpanded != expanded else { return }
        isExpanded = expanded
    }

    @objc private func toggled() {
        // Inside an open panel that is shutting, a tap lands on nothing.
        guard !isSuppressed else { return }
        isExpanded.toggle()
    }

    /// A host closing every panel before one opens elsewhere.
    func collapse() {
        collapseAction?()
    }

    private func updateExpansion() {
        let shown = isExpanded && !isSuppressed
        let height = shown ? preferredHeight : 0
        chevron.transform = CGAffineTransform(rotationAngle: shown ? 0 : -.pi / 2)
        body.isHidden = !shown
        heightPublisher.send(height)
        setNeedsLayout()
    }

    /// What the panel measures once it is built. A subclass overrides it when
    /// its body has a fixed height of its own.
    var preferredHeight: CGFloat {
        ComposerMetrics.Spacing.sm
            + headerHeight
            + (body.isHidden ? 0 : maxBodyHeight)
            + ComposerMetrics.Spacing.sm
    }

    /// The header's own height: what a subclass measures its body against.
    var headerHeight: CGFloat {
        max(titleLabel.font.lineHeight, chevron.intrinsicContentSize.height) + ComposerMetrics.Spacing.sm
    }

    /// How tall the body may grow before it scrolls.
    var maxBodyHeight: CGFloat { ComposerMetrics.Panel.maxBodyHeight }

    override func layoutSubviews() {
        super.layoutSubviews()

        let inset = ComposerMetrics.Spacing.md
        let chevronSize = chevron.isHidden ? 0 : chevron.intrinsicContentSize.width
        let chevronRoom = chevron.isHidden ? 0 : chevronSize + ComposerMetrics.Spacing.sm

        header.frame = CGRect(
            x: inset,
            y: ComposerMetrics.Spacing.sm,
            width: bounds.width - inset * 2,
            height: headerHeight,
        )
        titleLabel.frame = CGRect(
            x: 0,
            y: (header.bounds.height - titleLabel.font.lineHeight) / 2,
            width: max(0, header.bounds.width - chevronRoom),
            height: titleLabel.font.lineHeight,
        )
        chevron.frame = directionalFrame(CGRect(
            x: header.bounds.width - chevronSize,
            y: (header.bounds.height - chevron.intrinsicContentSize.height) / 2,
            width: chevronSize,
            height: chevron.intrinsicContentSize.height,
        ))

        body.frame = CGRect(
            x: inset,
            y: header.frame.maxY,
            width: bounds.width - inset * 2,
            height: max(0, bounds.height - header.frame.maxY - ComposerMetrics.Spacing.sm),
        )
    }
}

/// The panels above a composer, and the rule that only one is open at a time:
/// opening one closes the rest, and something covering the composer closes all.
final class ComposerPanelHost {
    private(set) var panels: [ComposerPanel] = []
    private var cancellables: Set<AnyCancellable> = .init()

    /// Told when any panel's height changes, so the composer lays out again.
    var onHeightChanged: (() -> Void)?

    /// Whether anything is open, which a caller asks before it decides to cover
    /// the composer.
    var isAnyExpanded: Bool {
        panels.contains { $0.isExpanded && !$0.isSuppressed }
    }

    func add(_ panel: ComposerPanel) {
        panels.append(panel)
        // A panel that folds its own way keeps the way; one that does not
        // folds to nothing.
        if panel.collapseAction == nil {
            panel.collapseAction = { [weak panel] in
                panel?.setExpanded(false)
            }
        }
        panel.heightPublisher
            .removeDuplicates()
            .ensureMainThread()
            .sink { [weak self] _ in self?.onHeightChanged?() }
            .store(in: &cancellables)
    }

    /// Everything out of the way: a sheet, an approval, a keyboard on a small
    /// screen.
    func suppressAll(_ suppressed: Bool) {
        for panel in panels {
            panel.isSuppressed = suppressed
        }
    }

    /// Close every panel, for a tap on the page or a send.
    func collapseAll() {
        for panel in panels where panel.isExpanded {
            panel.setExpanded(false)
        }
    }
}
