import ApelinProtocol
import UIKit

/// The row under the draft: what the run may do, which model answers it, how
/// hard that model thinks, and how full the context is — all on the left, in
/// reading order; the plus and the send on the right.
///
/// The left controls are icons rather than words, because the row is read at a
/// glance between typing and sending: a mark says whose model it is faster than
/// its name does, and the pill is the only one that needs a word.
final class ComposerModelBar: ComposerSectionView {
    /// What this run may do, first on the row: it is the setting read before
    /// a message is sent, and the others are read for it.
    let modePill = ComposerModePill()

    /// The provider's own mark, tapped to choose a model. No name beside it:
    /// the row's room belongs to the draft above.
    let modelButton = ComposerIconButton(symbolName: "cpu", label: String(localized: "Select Model"))

    /// The reasoning effort, as a brain in the colour of the level it is set
    /// to, tapped to change it. The level is drawn, never written: the row has
    /// no room for a word, and the colour says which of the settings is on.
    private let effortButton = ComposerIconButton(symbolName: "sparkles", label: String(localized: "Reasoning Effort"))

    /// The speed the model answers at, for the ones that offer a faster tier
    /// than standard: the letters say which, a tap changes it. Absent for a
    /// model with one tier, as most have.
    private let tierButton = ComposerIconButton(symbolName: "hare", label: String(localized: "Speed"))

    /// How full the context is, tapped to open or fold the panel that says by
    /// how much. The ring is the only control here whose state is a figure.
    let usageButton = ContextUsageButton()

    /// Attachments: the plus that opens the camera, photos, files and the web,
    /// and closes them again.
    let addButton = ComposerIconButton(symbolName: "plus", label: String(localized: "Add Attachment"))

    /// The send, and the stop it becomes while a run is going.
    let sendButton = ComposerIconButton(iconName: "ComposerSend", label: String(localized: "Send"))

    var onEffortChanged: ((AgentReasoningEffort) -> Void)?
    var onModeChanged: ((ComposerMode) -> Void)?
    var onTierChanged: ((AgentServiceTier?) -> Void)?
    /// The mark was tapped: the owner opens its model picker, which reads the
    /// accounts live. This row only reports the tap.
    var onModelTapped: (() -> Void)?
    /// The ring was tapped: open the context panel, or fold it again.
    var onContextTapped: (() -> Void)?
    var onAddTapped: (() -> Void)?
    var onSendTapped: (() -> Void)?
    var onStopTapped: (() -> Void)?
    /// The wand was tapped, with the draft as it stands: the owner asks for
    /// the rewrite and reports back with `setRewriting`.
    var onRewriteRequested: ((String) -> Void)?
    /// The stop was tapped while a rewrite ran.
    var onRewriteCancelled: (() -> Void)?

    /// The efforts this model offers, kept so a tap can redraw the menu against
    /// the level it took.
    private var efforts: [AgentReasoningEffort] = []
    /// The tiers this model offers, the standard one being none of them.
    private var tiers: [AgentServiceTier] = []
    /// Which tier the next message is sent at.
    private var selectedTier: AgentServiceTier?
    /// The run is going: with nothing typed the send becomes a stop.
    private var sendIsStop = false

    override func initializeViews() {
        super.initializeViews()

        for control in [modePill, modelButton, effortButton, tierButton, usageButton, addButton, sendButton] {
            addSubview(control)
        }

        modePill.onChange = { [weak self] mode in
            self?.onModeChanged?(mode)
            // The pill's own word changes with it, and the row's left side
            // starts at the pill's width: relaid out at once, or the mark
            // behind it stays where the old word left it.
            self?.setNeedsLayout()
        }
        usageButton.tapAction = { [weak self] in self?.onContextTapped?() }
        modelButton.tapAction = { [weak self] in self?.onModelTapped?() }
        addButton.tapAction = { [weak self] in self?.onAddTapped?() }
        sendButton.tapAction = { [weak self] in self?.tapSend() }
        effortButton.showsMenuAsPrimaryAction = true
        tierButton.showsMenuAsPrimaryAction = true

        // The disc is the reach and the mark is what is drawn on it: both
        // follow the one measure, so a smaller row keeps them apart.
        sendButton.iconInset = (ComposerMetrics.Send.diameter - ComposerMetrics.Send.iconSize) / 2
        addButton.iconInset = sendButton.iconInset
        sendButton.fillColor = ComposerPalette.inert
        sendButton.iconView.tintColor = .secondaryLabel

        // A brain's folds turn to mud at a row's size; a pair of sparks keeps
        // its shape at any of them, and the colour says the level anyway.
        effortButton.iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 23,
            weight: .medium
        )

        setEfforts([], selected: nil)
        setVisible(true)
    }

    // MARK: - State

    /// The mark of the provider that will answer: its own artwork, and a plain
    /// symbol for one the bundle has none for.
    func setProvider(_ provider: AgentProvider?) {
        updateControls { [self] in
            // A provider's own mark keeps the colours it was drawn with: as a
            // template it would be one flat silhouette, and a black one in
            // light mode. Only the fallback symbol follows the label's colour.
            if let icon = provider?.icon {
                modelButton.iconView.image = icon.withRenderingMode(.alwaysOriginal)
            } else {
                modelButton.iconView.image = UIImage(systemName: "cpu")?.withRenderingMode(.alwaysTemplate)
            }
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
        updateControls { [self] in
            let shown = !efforts.isEmpty
            effortButton.alpha = shown ? 1 : 0
            effortButton.isUserInteractionEnabled = shown
            effortButton.accessibilityElementsHidden = !shown
            // The colour is the level; the spoken value is the word for it.
            effortButton.iconView.tintColor = ComposerPalette.effort(selected ?? .high)
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

    /// The tiers the model offers: none of them is the standard one, so an
    /// empty list hides the control.
    func setTiers(_ tiers: [AgentServiceTier], selected: AgentServiceTier?) {
        self.tiers = tiers
        selectedTier = selected
        updateControls { [self] in
            let shown = !tiers.isEmpty
            tierButton.alpha = shown ? 1 : 0
            tierButton.isUserInteractionEnabled = shown
            tierButton.accessibilityElementsHidden = !shown
            tierButton.accessibilityValue = Self.title(for: selected)
        }
        // Rebuilt with the level it took, so the tick follows the choice.
        tierButton.menu = UIMenu(children: ([nil] + tiers).map { tier in
            UIAction(title: Self.title(for: tier), state: tier == selected ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.setTiers(self.tiers, selected: tier)
                self.onTierChanged?(tier)
            }
        })
    }

    /// Nothing to send: the disc greys; a run going and nothing typed: it is
    /// the stop.
    func setSendState(isBusy: Bool, hasContent: Bool) {
        // Sent while the state is unchanged too: the disc is drawn here, and the
        // first call after the row is built is the one that decides its colour.
        let stop = isBusy && !hasContent
        sendIsStop = stop
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

    /// The import panel is open: the plus draws as a close, so the same tap
    /// that opened it folds it away.
    func setPanelOpen(_ open: Bool) {
        updateControls { [self] in
            addButton.change(symbolName: open ? "xmark" : "plus")
            addButton.accessibilityLabel = open
                ? String(localized: "Close")
                : String(localized: "Add Attachment")
        }
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

    /// The speed's name; nil is the standard tier, which every model has.
    private static func title(for tier: AgentServiceTier?) -> String {
        switch tier {
        case nil: String(localized: "Standard")
        case .priority: String(localized: "Fast")
        case .ultrafast: String(localized: "Ultrafast")
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = preferredHeight
        let mid = (bounds.height - height) / 2
        let spacing = ComposerMetrics.Spacing.xs

        // The right pair keeps the row's end: the plus, then the send, in the
        // order they are pressed — a draft is finished before it leaves.
        let sendSize = ComposerMetrics.Send.diameter
        let sendFrame = CGRect(
            x: bounds.width - sendSize,
            y: (bounds.height - sendSize) / 2,
            width: sendSize,
            height: sendSize
        )
        sendButton.frame = directionalFrame(sendFrame)
        addButton.frame = directionalFrame(CGRect(
            x: sendFrame.minX - spacing - sendSize,
            y: sendFrame.minY,
            width: sendSize,
            height: sendSize
        ))

        // The left side reads in the order it is decided in: what the run may
        // do, which model answers, how hard it thinks, how full the context is.
        var x: CGFloat = 0
        let pillSize = modePill.intrinsicContentSize
        modePill.frame = directionalFrame(CGRect(
            x: x,
            y: (bounds.height - pillSize.height) / 2,
            width: pillSize.width,
            height: pillSize.height
        ))
        x += pillSize.width + ComposerMetrics.Spacing.sm

        let iconSize = sendSize
        let markSize = ComposerMetrics.Send.iconSize + 6
        modelButton.iconInset = (iconSize - markSize) / 2
        modelButton.frame = directionalFrame(CGRect(
            x: x, y: mid, width: iconSize, height: iconSize
        ))
        x += iconSize + spacing

        // The lightning is one control again: its colour says which level is
        // set, so it takes a slot of its own and no room for a word. The brain
        // is the one mark here a reader looks for by shape, so it fills that
        // slot rather than floating small inside it.
        let lightning = iconSize * 0.75
        effortButton.iconInset = 0
        effortButton.frame = directionalFrame(CGRect(
            x: x, y: (bounds.height - lightning) / 2, width: lightning, height: lightning
        ))
        x += lightning + spacing

        // The speed, where the model offers one, sits between the effort and
        // the ring; hidden, it takes no room.
        if tierButton.alpha > 0 {
            tierButton.frame = directionalFrame(CGRect(
                x: x, y: mid, width: iconSize, height: iconSize
            ))
            x += iconSize + spacing
        }

        let ringSize = ContextUsageButton.size
        usageButton.frame = directionalFrame(CGRect(
            x: x,
            y: (bounds.height - ringSize) / 2,
            width: ringSize,
            height: ringSize
        ))
    }
}
