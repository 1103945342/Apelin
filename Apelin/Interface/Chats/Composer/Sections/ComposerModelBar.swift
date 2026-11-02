// Lakr233's Inhouse Code, from FlowDown.
// I CAN DO WHAT THE FUCK I WANT.

import ApelinProtocol
import UIKit

/// FlowDown's model control below the text band, hidden while imports are open.
final class ComposerModelBar: ComposerSectionView {
    let button = ComposerBlockButton(text: String(localized: "Select Model"), image: UIImage(named: "ComposerModel"))
    private let effortButton = ComposerBlockButton(text: String(localized: "High"), image: UIImage(systemName: "brain"))
    private let tierButton = ComposerBlockButton(text: String(localized: "Standard"), image: UIImage(systemName: "bolt"))
    private let stopButton = ComposerBlockButton(
        text: String(localized: "Stop"),
        image: UIImage(systemName: "stop.fill"),
    )
    /// What this run may do, first on the row: it is the setting read before
    /// a message is sent, and the others are read for it.
    let modePill = ComposerModePill()
    /// How full the context is, at the row's end; a tap asks about compacting.
    let usageButton = ContextUsageButton()
    var onEffortChanged: ((AgentReasoningEffort) -> Void)?
    var onTierChanged: ((AgentServiceTier?) -> Void)?
    /// The pill was tapped: the answer is the mode it took.
    var onModeChanged: ((ComposerMode) -> Void)?
    /// The ring was tapped: open the context panel.
    var onContextTapped: (() -> Void)?
    private var cancelOutput: (() -> Void)?

    override func initializeViews() {
        super.initializeViews()
        for control in [modePill, button, effortButton, tierButton, stopButton] {
            addSubview(control)
        }
        addSubview(usageButton)
        modePill.onChange = { [weak self] mode in self?.onModeChanged?(mode) }
        usageButton.tapAction = { [weak self] in self?.onContextTapped?() }
        effortButton.showsMenuAsPrimaryAction = true
        setControl(effortButton, visible: false)
        tierButton.showsMenuAsPrimaryAction = true
        setControl(tierButton, visible: false)
        stopButton.tintColor = .systemRed
        stopButton.borderColor = .systemRed.withAlphaComponent(0.5)
        stopButton.accessibilityLabel = String(localized: "Stop Generating")
        setControl(stopButton, visible: false)
        stopButton.addAction(UIAction { [weak self] _ in self?.cancelOutput?() }, for: .touchUpInside)
        setModelName(nil)
        setVisible(true)
    }

    func setModelName(_ name: String?) {
        updateControls { [self] in
            button.setText(name ?? String(localized: "Select Model"))
            button.accessibilityLabel = String(localized: "Select Model")
            button.accessibilityValue = name
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
        updateControls { [self] in
            setControl(effortButton, visible: !efforts.isEmpty)
            effortButton.setText(Self.title(for: selected ?? .high))
            effortButton.accessibilityLabel = String(localized: "Reasoning Effort")
            effortButton.accessibilityValue = Self.title(for: selected ?? .high)
        }
        effortButton.menu = UIMenu(children: efforts.map { effort in
            UIAction(title: Self.title(for: effort), state: effort == selected ? .on : .off) { [weak self] _ in
                self?.setEfforts(efforts, selected: effort)
                self?.onEffortChanged?(effort)
            }
        })
    }

    /// The standard tier first, then the faster ones the model offers;
    /// hidden for a model that offers none.
    func setTiers(_ tiers: [AgentServiceTier], selected: AgentServiceTier?) {
        updateControls { [self] in
            setControl(tierButton, visible: !tiers.isEmpty)
            tierButton.setText(Self.title(for: selected))
            tierButton.accessibilityLabel = String(localized: "Speed")
            tierButton.accessibilityValue = Self.title(for: selected)
        }
        tierButton.menu = UIMenu(children: ([nil] + tiers).map { tier in
            UIAction(title: Self.title(for: tier), state: tier == selected ? .on : .off) { [weak self] _ in
                self?.setTiers(tiers, selected: tier)
                self?.onTierChanged?(tier)
            }
        })
    }

    /// The owner supplies its live run's cancellation; absent means no output to stop.
    func setOutputCancellation(_ cancel: (() -> Void)?) {
        cancelOutput = cancel
        updateControls { [self] in setControl(stopButton, visible: cancel != nil) }
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

    /// As tall as the tallest thing on the row: the chips, or the ring.
    private var preferredHeight: CGFloat {
        max(
            max(
                max(button.intrinsicContentSize.height, modePill.intrinsicContentSize.height),
                usageButton.isHidden ? 0 : ContextUsageButton.size,
            ),
            26,
        )
    }

    private func setControl(_ control: UIButton, visible: Bool) {
        control.alpha = visible ? 1 : 0
        control.isUserInteractionEnabled = visible
        control.accessibilityElementsHidden = !visible
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

    private static func title(for tier: AgentServiceTier?) -> String {
        switch tier {
        case nil: String(localized: "Standard")
        case .priority: String(localized: "Fast")
        case .ultrafast: String(localized: "Ultrafast")
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let spacing: CGFloat = 10
        let height = preferredHeight
        // The ring keeps the row's end for itself; the chips centre in what
        // is left, as they did before it was there.
        let ringWidth = usageButton.isHidden ? 0 : ContextUsageButton.size
        let ringRoom = ringWidth > 0 ? ringWidth + spacing : 0
        let controls = [button, effortButton, tierButton, stopButton].filter(\.isUserInteractionEnabled)
        let otherWidth = controls.dropFirst().reduce(CGFloat.zero) { $0 + $1.intrinsicContentSize.width + spacing }
        let pillWidth = modePill.intrinsicContentSize.width
        let room = max(0, bounds.width - ringRoom - pillWidth - spacing)
        let modelWidth = min(button.intrinsicContentSize.width, max(44, room - otherWidth))
        var x = max(0, (room - modelWidth - otherWidth) / 2) + pillWidth + spacing
        // model, effort, speed, Stop in reading order: right to left, from the right
        for control in [button, effortButton, tierButton, stopButton] {
            let width = control === button ? modelWidth : control.intrinsicContentSize.width
            control.frame = directionalFrame(
                CGRect(x: x, y: (height - control.intrinsicContentSize.height) / 2, width: width, height: control.intrinsicContentSize.height),
            )
            if control.isUserInteractionEnabled {
                x += width + spacing
            }
        }
        modePill.frame = directionalFrame(CGRect(
            x: 0,
            y: (height - modePill.intrinsicContentSize.height) / 2,
            width: pillWidth,
            height: modePill.intrinsicContentSize.height,
        ))
        usageButton.frame = directionalFrame(
            CGRect(x: bounds.width - ringWidth, y: (height - ringWidth) / 2, width: ringWidth, height: ringWidth),
        )
    }
}
