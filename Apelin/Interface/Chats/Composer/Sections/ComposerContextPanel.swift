import UIKit

/// How full the conversation's context is, opened from the ring beside the model
/// row: a bar with the compaction threshold marked on it, what is used against
/// what the model holds, and a button to compact now.
///
/// The figure is the last request's own input token count, the one the provider
/// reported, not a total for the conversation: a total grows without ever
/// falling when a compaction happens, and says nothing about the room left.
final class ComposerContextPanel: ComposerPanel {
    private let usageBar = UIView()
    private let usageFill = UIView()
    private let usedLabel = UILabel()
    private let limitLabel = UILabel()
    private let thresholdLabel = UILabel()
    private let compactButton = UIButton(type: .system)

    private var usedTokens = 0
    private var limitTokens = 0

    /// Asked for when the button is tapped.
    var onCompact: (() -> Void)?

    override func initializeViews() {
        super.initializeViews()

        setTitle(String(localized: "Context"))
        setCollapsible(false)

        usageBar.backgroundColor = UIColor.tertiarySystemFill
        usageBar.layer.cornerRadius = 4
        usageBar.layer.cornerCurve = .continuous
        usageBar.clipsToBounds = true
        body.addSubview(usageBar)
        usageFill.layer.cornerRadius = 4
        usageFill.layer.cornerCurve = .continuous
        usageBar.addSubview(usageFill)

        usedLabel.font = .preferredFont(forTextStyle: .footnote)
        usedLabel.textColor = .label
        usedLabel.adjustsFontForContentSizeCategory = true
        usedLabel.numberOfLines = 0
        body.addSubview(usedLabel)

        for label in [limitLabel, thresholdLabel] {
            label.font = .preferredFont(forTextStyle: .caption2)
            label.textColor = .secondaryLabel
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
            body.addSubview(label)
        }

        compactButton.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
        compactButton.titleLabel?.adjustsFontForContentSizeCategory = true
        compactButton.layer.cornerRadius = ComposerMetrics.Radius.sm
        compactButton.layer.cornerCurve = .continuous
        compactButton.addTarget(self, action: #selector(compactTapped), for: .primaryActionTriggered)
        body.addSubview(compactButton)

        updateText()
    }

    override var preferredHeight: CGFloat {
        // Measured against the body's own width once it has one; a panel that
        // has not been laid out yet falls back to the composer's full width,
        // which is what it is about to get.
        let width = body.bounds.width > 0 ? body.bounds.width : UIScreen.main.bounds.width - ComposerMetrics.Spacing.lg * 2
        let used = usedLabel.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude),
        ).height
        let limit = limitLabel.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude),
        ).height
        let threshold = thresholdLabel.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude),
        ).height
        let buttonHeight = max(28, compactButton.titleLabel?.font.lineHeight ?? 0)
        let texts = used + limit + threshold + ComposerMetrics.Spacing.xs * 2
        let rowHeight = max(texts, buttonHeight)
        return ComposerMetrics.Spacing.sm
            + 8
            + ComposerMetrics.Spacing.sm
            + rowHeight
            + ComposerMetrics.Spacing.sm
    }

    func set(
        usedTokens: Int,
        limitTokens: Int,
        compactEnabled: Bool,
    ) {
        self.usedTokens = usedTokens
        self.limitTokens = limitTokens
        compactButton.isEnabled = compactEnabled
        updateText()
        setNeedsLayout()
        // A folded panel publishes nothing. The composer lays out whatever has
        // a height, so a figure arriving while it is folded must not put the
        // card back over a body it is not showing.
        heightPublisher.send(isExpanded ? preferredHeight : 0)
    }

    private var fraction: Double? {
        guard limitTokens > 0 else { return nil }
        return min(1, max(0, Double(usedTokens) / Double(limitTokens)))
    }

    private func updateText() {
        let ratio = fraction
        usedLabel.text = String(
            localized: "\(Self.tokenText(usedTokens)) used",
        )
        if let ratio {
            limitLabel.text = String(
                localized: "of \(Self.tokenText(limitTokens)) tokens · \((Int(ratio * 100)))%",
            )
        } else {
            limitLabel.text = String(localized: "Context limit unknown for this model")
        }
        thresholdLabel.text = String(localized: "The agent compacts near the limit")

        let fill = ratio.map { $0 >= 0.9 ? UIColor.systemRed : ($0 >= 0.75 ? .systemOrange : .secondaryLabel) }
            ?? UIColor.tertiaryLabel
        usageFill.backgroundColor = fill

        compactButton.setTitle(String(localized: "Compact Now"), for: .normal)
        compactButton.accessibilityLabel = String(localized: "Compact This Conversation Now")
        let enabled = compactButton.isEnabled
        compactButton.backgroundColor = enabled
            ? tintColor
            : UIColor.tertiarySystemFill
        compactButton.setTitleColor(
            enabled ? .white : .secondaryLabel,
            for: .normal,
        )
    }

    private static func tokenText(_ tokens: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: tokens)) ?? String(tokens)
    }

    @objc private func compactTapped() {
        guard compactButton.isEnabled else { return }
        onCompact?()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let width = body.bounds.width
        let ratio = fraction ?? 0

        usageBar.frame = CGRect(x: 0, y: 0, width: width, height: 8)
        usageFill.frame = CGRect(x: 0, y: 0, width: width * ratio, height: 8)

        let buttonWidth = min(
            width * 0.42,
            compactButton.titleLabel?.intrinsicContentSize.width ?? 0
                + ComposerMetrics.Spacing.md * 2,
        )
        let buttonHeight = max(28, compactButton.titleLabel?.font.lineHeight ?? 0)
        let textWidth = width - buttonWidth - ComposerMetrics.Spacing.sm

        var y = usageBar.frame.maxY + ComposerMetrics.Spacing.sm
        usedLabel.frame = CGRect(
            x: 0,
            y: y,
            width: textWidth,
            height: usedLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height,
        )
        y = usedLabel.frame.maxY
        limitLabel.frame = CGRect(
            x: 0,
            y: y,
            width: textWidth,
            height: limitLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height,
        )
        y = limitLabel.frame.maxY
        thresholdLabel.frame = CGRect(
            x: 0,
            y: y,
            width: textWidth,
            height: thresholdLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height,
        )

        compactButton.frame = directionalFrame(CGRect(
            x: width - buttonWidth,
            y: usageBar.frame.maxY + ComposerMetrics.Spacing.sm,
            width: buttonWidth,
            height: buttonHeight,
        ))
    }
}
