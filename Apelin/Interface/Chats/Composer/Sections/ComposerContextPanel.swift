import UIKit

/// How full the conversation's context is, opened from the ring beside the model
/// row: the bar the agent's own compaction threshold is marked on, what is used
/// against what the model holds, and a button to compact now.
///
/// The layout is aimini's `ContextInfoPanel`, read as points: no title band, a
/// capsule bar with the threshold ticked on it, three lines at the left and one
/// capsule action at the right. The figure is the last request's own input token
/// count, the one the provider reported, not a total for the conversation: a
/// total grows without ever falling when a compaction happens, and says nothing
/// about the room left.
final class ComposerContextPanel: ComposerPanel {
    /// Where the agent compacts on its own: kwwk's `AgentAutoCompactOptions`
    /// default, which Apelin does not override. The tick on the bar and the
    /// sentence under it both read this one figure.
    /// What the reader set in Settings ▸ Chat: the share at which a
    /// conversation compacts itself, shown here as a percentage.
    static var compactionThresholdPercent: Int {
        Int((Preferences.compressionThreshold * 100).rounded())
    }

    private static let barHeight: CGFloat = 8

    private let track = UIView()
    private let fill = UIView()
    private let thresholdTick = UIView()
    private let usedLabel = UILabel()
    private let limitLabel = UILabel()
    private let thresholdLabel = UILabel()
    private let compactButton = UIButton(type: .system)

    private var usedTokens = 0
    private var limitTokens = 0
    private var compactEnabled = true
    private var isCompacting = false

    /// The height last handed to the composer, so a body measured against a
    /// width it did not have yet is corrected once, not on every pass.
    private var publishedHeight: CGFloat = 0

    /// Asked for when the button is tapped.
    var onCompact: (() -> Void)?

    override func initializeViews() {
        super.initializeViews()

        setHeaderless()

        track.layer.cornerRadius = Self.barHeight / 2
        track.layer.cornerCurve = .continuous
        track.backgroundColor = UIColor.separator.withAlphaComponent(0.4)
        track.clipsToBounds = true
        body.addSubview(track)

        fill.layer.cornerRadius = Self.barHeight / 2
        fill.layer.cornerCurve = .continuous
        track.addSubview(fill)

        // The threshold, as a hairline standing on the bar rather than a
        // sentence about it: how close the fill is to compacting is read at a
        // glance, which is the reason to open this at all.
        thresholdTick.backgroundColor = UIColor.label.withAlphaComponent(0.55)
        track.addSubview(thresholdTick)

        usedLabel.font = Self.font(.footnote, weight: .semibold)
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

        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .capsule
        configuration.image = Self.boltImage
        configuration.imagePadding = ComposerMetrics.Spacing.xs
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 6,
            leading: ComposerMetrics.Spacing.md,
            bottom: 6,
            trailing: ComposerMetrics.Spacing.md,
        )
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = ComposerContextPanel.font(.caption1, weight: .semibold)
            return outgoing
        }
        compactButton.configuration = configuration
        compactButton.addTarget(self, action: #selector(compactTapped), for: .primaryActionTriggered)
        body.addSubview(compactButton)

        updateText()
    }

    override var preferredHeight: CGFloat {
        // Measured against the body's own width once it has one; the composer
        // hands the panel its width right after the height it asks for, and
        // `layoutSubviews` corrects the answer when the guess was wrong.
        ComposerMetrics.Spacing.sm
            + Self.barHeight
            + ComposerMetrics.Spacing.sm
            + rowHeight(for: measuredWidth)
            + ComposerMetrics.Spacing.sm
    }

    func set(
        usedTokens: Int,
        limitTokens: Int,
        compactable: Bool,
        compacting: Bool,
    ) {
        self.usedTokens = usedTokens
        self.limitTokens = limitTokens
        compactEnabled = compactable
        isCompacting = compacting
        updateText()
        setNeedsLayout()
        // A folded panel publishes nothing. The composer lays out whatever has
        // a height, so a figure arriving while it is folded must not put the
        // card back over a body it is not showing.
        if isExpanded, !isSuppressed {
            publishedHeight = preferredHeight
            heightPublisher.send(publishedHeight)
        }
    }

    private var fraction: Double? {
        guard limitTokens > 0 else { return nil }
        return min(1, max(0, Double(usedTokens) / Double(limitTokens)))
    }

    /// The width the body will have: its own once the composer has placed the
    /// panel, and before that the screen's less the panel's own insets.
    private var measuredWidth: CGFloat {
        if body.bounds.width > 0 { return body.bounds.width }
        return max(0, UIScreen.main.bounds.width - ComposerMetrics.Spacing.md * 4)
    }

    private func rowHeight(for width: CGFloat) -> CGFloat {
        let button = compactButton.intrinsicContentSize
        let text = textColumnHeight(for: width - button.width - ComposerMetrics.Spacing.sm)
        return max(button.height, text)
    }

    private func textColumnHeight(for width: CGFloat) -> CGFloat {
        [usedLabel, limitLabel, thresholdLabel].reduce(0) { total, label in
            total + label.sizeThatFits(
                CGSize(width: max(0, width), height: .greatestFiniteMagnitude),
            ).height
        }
    }

    private func updateText() {
        let ratio = fraction
        let threshold = Double(Self.compactionThresholdPercent) / 100

        usedLabel.text = String(localized: "\(Self.tokenText(usedTokens)) tokens used")
        if let ratio {
            limitLabel.text = String(
                localized: "Limit \(Self.tokenText(limitTokens)) (\(Int((ratio * 100).rounded()))%)",
            )
        } else {
            limitLabel.text = String(localized: "Context limit unknown")
        }
        thresholdLabel.text = String(localized: "Auto-compacts at \(Self.compactionThresholdPercent)%")

        let level: UIColor = if ratio == nil {
            .tertiaryLabel
        } else if let ratio, ratio >= 1 {
            .systemRed
        } else if let ratio, ratio >= threshold {
            .systemOrange
        } else {
            .systemGreen
        }
        fill.backgroundColor = level

        updateButton()
    }

    /// The action's three states: ready, busy, and not this conversation's to
    /// take — the same shape each time, so the panel does not jump.
    private func updateButton() {
        guard var configuration = compactButton.configuration else { return }
        let enabled = compactEnabled && !isCompacting

        configuration.showsActivityIndicator = isCompacting
        configuration.image = isCompacting ? nil : Self.boltImage
        configuration.title = isCompacting
            ? String(localized: "Compressing context")
            : String(localized: "Compact Now")
        // The fill is the window's tint, which on a monochrome accent is the
        // text's own colour: white in the dark. So is the title, unless it
        // asks the accent what sits on it.
        configuration.baseBackgroundColor = enabled ? .tintColor : UIColor.tertiarySystemFill
        configuration.baseForegroundColor = enabled ? AppAccent.foreground(glass: .white) : .secondaryLabel
        compactButton.configuration = configuration
        compactButton.isUserInteractionEnabled = enabled
        compactButton.accessibilityLabel = isCompacting
            ? String(localized: "Compressing context")
            : String(localized: "Compact This Conversation Now")
        compactButton.accessibilityTraits = enabled ? .button : [.button, .notEnabled]
    }

    private static var boltImage: UIImage? {
        UIImage(
            systemName: "bolt.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold),
        )
    }

    /// A text style's own size and scaling, at another weight: the system has
    /// no one-call answer for this, and a descriptor keeps Dynamic Type.
    private static func font(_ style: UIFont.TextStyle, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.preferredFont(forTextStyle: style)
        let descriptor = base.fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight],
        ])
        return UIFont(descriptor: descriptor, size: 0)
    }

    private static func tokenText(_ tokens: Int) -> String {
        // aimini's `formatTokenCount`: one decimal in the thousands and above,
        // so a window reads "200.0k" rather than seven digits.
        switch tokens {
        case 1_000_000_000...:
            String(format: "%.1fB", Double(tokens) / 1_000_000_000)
        case 1_000_000...:
            String(format: "%.1fM", Double(tokens) / 1_000_000)
        case 1_000...:
            String(format: "%.1fk", Double(tokens) / 1_000)
        default:
            String(tokens)
        }
    }

    @objc private func compactTapped() {
        guard compactEnabled, !isCompacting else { return }
        onCompact?()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let width = body.bounds.width
        let ratio = fraction ?? 0
        let threshold = CGFloat(Self.compactionThresholdPercent) / 100

        track.frame = CGRect(x: 0, y: 0, width: width, height: Self.barHeight)
        fill.frame = CGRect(x: 0, y: 0, width: width * ratio, height: Self.barHeight)
        thresholdTick.frame = directionalFrame(CGRect(
            x: min(max(0, width - 2), width * threshold - 1),
            y: 0,
            width: 2,
            height: Self.barHeight,
        ))

        let buttonSize = compactButton.intrinsicContentSize
        let row = max(buttonSize.height, textColumnHeight(for: width - buttonSize.width - ComposerMetrics.Spacing.sm))
        let rowTop = track.frame.maxY + ComposerMetrics.Spacing.sm

        var y = rowTop
        let textWidth = max(0, width - buttonSize.width - ComposerMetrics.Spacing.sm)
        for label in [usedLabel, limitLabel, thresholdLabel] {
            let height = label.sizeThatFits(
                CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            ).height
            label.frame = CGRect(x: 0, y: y, width: textWidth, height: height)
            y = label.frame.maxY
        }

        compactButton.frame = directionalFrame(CGRect(
            x: width - buttonSize.width,
            y: rowTop + (row - buttonSize.height) / 2,
            width: buttonSize.width,
            height: buttonSize.height,
        ))

        // The height published at the moment the panel opened was measured
        // against a width the body did not have yet. Now that it has one, hand
        // the composer the real figure — once.
        let height = rowTop + row + ComposerMetrics.Spacing.sm
        if isExpanded, !isSuppressed, abs(publishedHeight - height) > 0.5 {
            publishedHeight = height
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isExpanded, !self.isSuppressed else { return }
                self.heightPublisher.send(self.preferredHeight)
            }
        }
    }
}
