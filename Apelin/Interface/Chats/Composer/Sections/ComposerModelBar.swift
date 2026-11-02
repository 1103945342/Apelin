import ApelinProtocol
import UIKit

/// The row under the draft: what the run may do, which model answers it, how
/// hard that model thinks, and how full the context is — all on the left, in
/// reading order; what goes out, on the right.
///
/// The left four are icons rather than words, because the row is read at a
/// glance between typing and sending: a mark says whose model it is faster than
/// its name does, and the pill is the only one that needs a word.
final class ComposerModelBar: ComposerSectionView {
    /// What this run may do, first on the row: it is the setting read before
    /// a message is sent, and the others are read for it.
    let modePill = ComposerModePill()

    /// The provider's own mark, tapped to choose a model. No name beside it:
    /// the row's room belongs to the draft above.
    let modelButton = ComposerIconButton(symbolName: "cpu", label: String(localized: "Select Model"))

    /// The lightning and the level it is set to, tapped to change it.
    private let effortButton = ComposerIconButton(symbolName: "bolt", label: String(localized: "Reasoning Effort"))
    private let effortLabel = UILabel()

    /// How full the context is, tapped to open or fold the panel that says by
    /// how much. The ring is the only control here whose state is a figure.
    let usageButton = ContextUsageButton()

    /// Attachments: the plus that opens the camera, photos, files and the web.
    let addButton = ComposerIconButton(symbolName: "plus", label: String(localized: "Add Attachment"))

    /// The send, and the stop it becomes while a run is going.
    let sendButton = ComposerIconButton(iconName: "ComposerSend", label: String(localized: "Send"))

    var onEffortChanged: ((AgentReasoningEffort) -> Void)?
    var onModeChanged: ((ComposerMode) -> Void)?
    /// The ring was tapped: open the context panel, or fold it again.
    var onContextTapped: (() -> Void)?
    var onAddTapped: (() -> Void)?
    var onSendTapped: (() -> Void)?
    var onStopTapped: (() -> Void)?

    /// The efforts this model offers, kept so a tap can redraw the menu against
    /// the level it took.
    private var efforts: [AgentReasoningEffort] = []
    private var selectedEffort: AgentReasoningEffort?
    /// The run is going: with nothing typed the send becomes a stop.
    private var isBusy = false
    private var hasContent = false
    private var sendIsStop = false

    override func initializeViews() {
        super.initializeViews()

        for control in [modePill, modelButton, effortButton, usageButton, addButton, sendButton] {
            addSubview(control)
        }
        effortLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        effortLabel.adjustsFontSizeToFitWidth = true
        effortLabel.minimumScaleFactor = 0.8
        effortLabel.isUserInteractionEnabled = false
        effortLabel.textAlignment = .center
        addSubview(effortLabel)

        modePill.onChange = { [weak self] mode in self?.onModeChanged?(mode) }
        usageButton.tapAction = { [weak self] in self?.onContextTapped?() }
        modelButton.tapAction = { [weak self] in self?.onModelTapped?() }
        addButton.tapAction = { [weak self] in self?.onAddTapped?() }
        sendButton.tapAction = { [weak self] in self?.tapSend() }
        effortButton.showsMenuAsPrimaryAction = true

        sendButton.iconInset = 8
        sendButton.fillColor = ComposerPalette.inert
        sendButton.iconView.tintColor = .secondaryLabel

        setEfforts([], selected: nil)
        setVisible(true)
    }

    // MARK: - State

    /// The mark of the provider that will answer: its own artwork, and a plain
    /// symbol for one the bundle has none for.
    func setProvider(_ provider: AgentProvider?) {
        updateControls { [self] in
            let image = provider?.icon ?? UIImage(systemName: "cpu")
            modelButton.iconView.image = image?.withRenderingMode(.alwaysTemplate)
            modelButton.accessibilityLabel = String(localized: "Select Model")
            modelButton.accessibilityValue = provider?.displayName
        }
    }

    /// The import panel takes this row's place, so the row hands over to it.
    func setVisible(_ visible: Bool) {
        handOver(visible: visible)
        updateControls { [self] in
            isUserInteractionEnabled = visible
            accessibilityElementsHidden = !visible
            heightPublisher.send(visible ? preferredHeight : 0)
        }
    }

    func setEfforts(_ efforts: [AgentReasoningEffort], selected: AgentReasoningEffort?) {
        self.efforts = efforts
        selectedEffort = selected
        updateControls { [self] in
            let shown = !efforts.isEmpty
            effortButton.alpha = shown ? 1 : 0
            effortButton.isUserInteractionEnabled = shown
            effortButton.accessibilityElementsHidden = !shown
            effortLabel.alpha = shown ? 1 : 0
            effortLabel.text = Self.shortTitle(for: selected ?? .high)
            effortButton.accessibilityValue = Self.title(for: selected ?? .high)
        }
        // The menu is the button's action, rebuilt with the levels it took so a
        // tick follows the choice that was made.
        effortButton.menu = UIMenu(children: efforts.map { effort in
            UIAction(title: Self.title(for: effort), state: effort == selected ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.setEfforts(self.efforts, selected: effort)
                self.onEffortChanged?(effort)
            }
        })
    }

    /// Nothing to send: the disc greys; a run going and nothing typed: it is
    /// the stop.
    func setSendState(isBusy: Bool, hasContent: Bool) {
        let stop = isBusy && !hasContent
        guard stop != sendIsStop || hasContent != self.hasContent || isBusy != self.isBusy else { return }
        self.isBusy = isBusy
        self.hasContent = hasContent
        sendIsStop = stop
        updateControls { [self] in
            let able = stop || hasContent
            sendButton.iconView.image = UIImage(systemName: stop ? "stop.fill" : "arrow.up")?
                .withRenderingMode(.alwaysTemplate)
            sendButton.fillColor = stop
                ? ComposerPalette.stop
                : (hasContent ? (isBusy ? ComposerPalette.queued : ComposerPalette.send) : ComposerPalette.inert)
            sendButton.iconView.tintColor = able
                ? ComposerPalette.label(on: sendButton.fillColor ?? ComposerPalette.inert)
                : .secondaryLabel
            sendButton.isUserInteractionEnabled = able
            sendButton.accessibilityLabel = stop
                ? String(localized: "Stop Generating")
                : String(localized: "Send")
        }
    }

    /// The context's fill, from the agent's last record of it; nothing to
    /// show until it has recorded one. Tappable only between runs.
    func setContextUsage(_ usage: ChatContextUsage?, compactable: Bool) {
        usageButton.isAvailable = compactable
        guard usageButton.usage != usage else { return }
        updateControls { [self] in
            usageButton.set(usage)
            heightPublisher.send(isUserInteractionEnabled ? preferredHeight : 0)
        }
    }

    /// The panel under the row is open: the ring says so, and says a tap folds
    /// it again.
    func setContextExpanded(_ expanded: Bool) {
        usageButton.setExpanded(expanded)
    }

    // MARK: - Picking

    private func tapSend() {
        if sendIsStop {
            onStopTapped?()
        } else {
            onSendTapped?()
        }
    }

    // MARK: - Layout

    /// As tall as the tallest thing on the row.
    private var preferredHeight: CGFloat {
        max(modePill.intrinsicContentSize.height, ComposerMetrics.Send.diameter)
    }

    private func updateControls(_ changes: @escaping () -> Void) {
        let update = { [self] in
            changes()
            setNeedsLayout()
            layoutIfNeeded()
        }
        if window != nil, !UIAccessibility.isReduceMotionEnabled {
            doWithAnimation(update)
        } else {
            UIView.performWithoutAnimation(update)
        }
    }

    private static func title(for effort: AgentReasoningEffort) -> String {
        switch effort {
        case .off: String(localized: "Off")
        case .minimal: String(localized: "Minimal")
        case .low: String(localized: "Low")
        case .medium: String(localized: "Medium")
        case .high: String(localized: "High")
        case .xhigh: String(localized: "Extra High")
        case .max: String(localized: "Maximum")
        }
    }

    /// The one or two letters the row has room for; the full word is what
    /// VoiceOver reads.
    private static func shortTitle(for effort: AgentReasoningEffort) -> String {
        switch effort {
        case .off: "—"
        case .minimal: "MIN"
        case .low: "LOW"
        case .medium: "MED"
        case .high: "HIGH"
        case .xhigh: "XH"
        case .max: "MAX"
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = preferredHeight
        let mid = (bounds.height - height) / 2
        let spacing = ComposerMetrics.Spacing.sm

        // The right pair keeps the row's end: what leaves the composer is read
        // there, away from what decides it.
        let sendSize = ComposerMetrics.Send.diameter
        let sendFrame = CGRect(
            x: bounds.width - sendSize,
            y: (bounds.height - sendSize) / 2,
            width: sendSize,
            height: sendSize,
        )
        sendButton.frame = directionalFrame(sendFrame)
        addButton.frame = directionalFrame(CGRect(
            x: sendFrame.minX - spacing - sendSize,
            y: sendFrame.minY,
            width: sendSize,
            height: sendSize,
        ))
        addButton.iconInset = 8

        // The left four read in the order they are decided in: what the run may
        // do, which model answers, how hard it thinks, how full the context is.
        var x: CGFloat = 0
        let pillSize = modePill.intrinsicContentSize
        modePill.frame = directionalFrame(CGRect(
            x: x,
            y: (bounds.height - pillSize.height) / 2,
            width: pillSize.width,
            height: pillSize.height,
        ))
        x += pillSize.width + spacing

        let iconSize = sendSize
        let markSize = ComposerMetrics.Send.iconSize + 6
        modelButton.iconInset = (iconSize - markSize) / 2
        modelButton.frame = directionalFrame(CGRect(
            x: x, y: mid, width: iconSize, height: iconSize,
        ))
        x += iconSize + spacing * 0.5

        // The lightning and its level sit together as one control: the symbol
        // says what the setting is, the letters say where it is set.
        let lightning = iconSize * 0.8
        effortButton.iconInset = (lightning - ComposerMetrics.Send.iconSize) / 2
        effortButton.iconView.tintColor = effortLabel.alpha > 0 ? .secondaryLabel : .tertiaryLabel
        effortButton.frame = directionalFrame(CGRect(
            x: x, y: (bounds.height - lightning) / 2, width: lightning, height: lightning,
        ))
        let labelWidth = min(effortLabel.intrinsicContentSize.width, 34)
        effortLabel.frame = directionalFrame(CGRect(
            x: x + lightning - 2,
            y: (bounds.height - effortLabel.font.lineHeight) / 2,
            width: labelWidth,
            height: effortLabel.font.lineHeight,
        ))
        x += lightning + labelWidth + spacing * 0.25

        let ringSize = ContextUsageButton.size
        usageButton.frame = directionalFrame(CGRect(
            x: x + spacing * 0.5,
            y: (bounds.height - ringSize) / 2,
            width: ringSize,
            height: ringSize,
        ))
    }
}
