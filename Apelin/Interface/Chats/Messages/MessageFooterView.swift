import UIKit

/// The line under a message: under the reader's, when it was sent, Copy,
/// Checkpoint & Rewind and More; under a turn's last reply, what the turn
/// cost (tokens in and out, the share read from the provider's cache behind
/// a cylinder, the time it took behind a clock), Copy and More, as aimini's
/// message footer has it. The reply of a turn still running has neither
/// Copy nor More until it ends.
///
/// Laid out left to right and mirrored right to left, item by item, as the
/// bubble above it is. Each label and button is an element of its own; an
/// icon is drawn only, its label saying what it stands for.
final class MessageFooterView: UIView {
    static let buttonSize: CGFloat = 28
    private static let labelSpacing: CGFloat = 8
    private static let iconSpacing: CGFloat = 2
    private static let buttonSpacing: CGFloat = 2

    /// The line's height, the same for every message.
    static var height: CGFloat {
        max(buttonSize, ceil(font.lineHeight) + 6)
    }

    private static var font: UIFont {
        .preferredFont(forTextStyle: .caption1)
    }

    var onCopy: (() -> Void)?
    var onRewind: (() -> Void)?
    var onMore: (() -> Void)?

    private let timeLabel = UILabel()
    private let tokensLabel = UILabel()
    private let cacheIcon = MessageFooterView.icon("cylinder")
    private let cacheLabel = UILabel()
    private let durationIcon = MessageFooterView.icon("clock")
    private let durationLabel = UILabel()
    private let copyButton = UIButton(type: .system)
    private let rewindButton = UIButton(type: .system)
    private let moreButton = UIButton(type: .system)
    private var copiedMessage: UUID?
    private var shownMessage: UUID?
    private var copyReset: DispatchWorkItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        for label in [timeLabel, tokensLabel, cacheLabel, durationLabel] {
            label.font = Self.font
            label.adjustsFontForContentSizeCategory = true
            label.textColor = .secondaryLabel
            label.isHidden = true
            addSubview(label)
        }
        for icon in [cacheIcon, durationIcon] {
            icon.isHidden = true
            addSubview(icon)
        }
        Self.style(copyButton, symbol: "doc.on.doc")
        copyButton.accessibilityLabel = String(localized: "Copy")
        copyButton.addAction(UIAction { [weak self] _ in self?.onCopy?() }, for: .touchUpInside)
        Self.style(rewindButton, symbol: "arrow.uturn.backward")
        rewindButton.accessibilityLabel = String(localized: "Checkpoint & Rewind")
        rewindButton.addAction(UIAction { [weak self] _ in self?.onRewind?() }, for: .touchUpInside)
        Self.style(moreButton, symbol: "ellipsis")
        moreButton.accessibilityLabel = String(localized: "More")
        moreButton.addAction(UIAction { [weak self] _ in self?.onMore?() }, for: .touchUpInside)
        for button in [copyButton, rewindButton, moreButton] {
            button.isHidden = true
            addSubview(button)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    private static func style(_ button: UIButton, symbol: String) {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol)
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            textStyle: .caption1,
            scale: .medium,
        )
        configuration.baseForegroundColor = .secondaryLabel
        configuration.contentInsets = .zero
        button.configuration = configuration
    }

    /// A symbol drawn before a figure, in the figures' colour and at their
    /// size. Not an element: the figure's label names what it is.
    private static func icon(_ symbol: String) -> UIImageView {
        let view = UIImageView(image: UIImage(systemName: symbol))
        view.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1, scale: .small)
        view.adjustsImageSizeForAccessibilityContentSizeCategory = true
        view.tintColor = .secondaryLabel
        view.contentMode = .center
        view.isAccessibilityElement = false
        return view
    }

    /// Whether `message` has a line under it at all.
    static func shows(_ message: ChatMessage) -> Bool {
        switch message.role {
        case .user:
            !message.isQueued && message.sentAt != nil
        case .assistant:
            message.isReply && (message.offersActions || message.turnStats != nil)
        default:
            false
        }
    }

    func show(_ message: ChatMessage) {
        if shownMessage != message.id {
            shownMessage = message.id
            copiedMessage = nil
            copyReset?.cancel()
        }
        let user = message.role == .user
        let hasText = !message.text.isEmpty
        if user, let sent = message.sentAt {
            let time = Calendar.current.isDateInToday(sent)
                ? sent.formatted(date: .omitted, time: .shortened)
                : sent.formatted(date: .abbreviated, time: .shortened)
            timeLabel.text = time
            timeLabel.accessibilityLabel = String(localized: "Sent at \(time)")
        }
        timeLabel.isHidden = !user || message.sentAt == nil

        let stats = user ? nil : message.turnStats
        if let stats, stats.hasTokens {
            let input = stats.promptTokens.formatted(.number.notation(.compactName))
            let output = stats.outputTokens.formatted(.number.notation(.compactName))
            tokensLabel.text = "↑\(input) ↓\(output)"
            let inputCount = stats.promptTokens.formatted()
            let outputCount = stats.outputTokens.formatted()
            tokensLabel.accessibilityLabel = String(localized: "\(inputCount) input tokens, \(outputCount) output tokens")
        }
        tokensLabel.isHidden = stats?.hasTokens != true
        if let rate = stats?.cacheHitRate {
            let percent = rate.formatted(.percent.precision(.fractionLength(0)))
            cacheLabel.text = percent
            cacheLabel.accessibilityLabel = String(localized: "\(percent) of input read from the cache")
        }
        cacheLabel.isHidden = stats?.cacheHitRate == nil
        cacheIcon.isHidden = cacheLabel.isHidden
        if let seconds = stats?.seconds {
            durationLabel.text = Self.duration(seconds)
            let spoken = Self.spokenDuration(seconds) ?? Self.duration(seconds)
            durationLabel.accessibilityLabel = String(localized: "Took \(spoken)")
        }
        durationLabel.isHidden = stats?.seconds == nil
        durationIcon.isHidden = durationLabel.isHidden

        let acts = user ? message.turnMessageID != nil : message.offersActions
        copyButton.isHidden = !(hasText && (user || message.offersActions))
        rewindButton.isHidden = !(user && message.turnMessageID != nil)
        moreButton.isHidden = !acts
        showCopyState(copiedMessage == message.id)
        setNeedsLayout()
    }

    /// Copy said Copied for a moment: the tick, and its name with it.
    func showCopied() {
        copiedMessage = shownMessage
        showCopyState(true)
        copyReset?.cancel()
        let reset = DispatchWorkItem { [weak self] in
            self?.copiedMessage = nil
            self?.showCopyState(false)
        }
        copyReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: reset)
    }

    private func showCopyState(_ copied: Bool) {
        copyButton.configuration?.image = UIImage(systemName: copied ? "checkmark" : "doc.on.doc")
        copyButton.accessibilityLabel = copied ? String(localized: "Copied") : String(localized: "Copy")
    }

    func reset() {
        copyReset?.cancel()
        copyReset = nil
        copiedMessage = nil
        shownMessage = nil
        onCopy = nil
        onRewind = nil
        onMore = nil
    }

    /// aimini's `formatTaskDuration`: "12s" under a minute, "2:05" under an
    /// hour, "1:02:05" beyond, never under a second.
    private static func duration(_ seconds: Int) -> String {
        let total = max(1, seconds)
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let rest = total % 60
        if hours > 0 {
            return String(format: "%ld:%02ld:%02ld", hours, minutes, rest)
        }
        if minutes > 0 {
            return String(format: "%ld:%02ld", minutes, rest)
        }
        return "\(rest)s"
    }

    /// The same time as VoiceOver says it, "2 minutes, 5 seconds", in the
    /// reader's language: "2:05" read aloud is a time of day.
    private static func spokenDuration(_ seconds: Int) -> String? {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: TimeInterval(max(1, seconds)))
    }

    /// The items shown, in reading order.
    private var items: [UIView] {
        [
            timeLabel, tokensLabel, cacheIcon, cacheLabel, durationIcon, durationLabel,
            copyButton, rewindButton, moreButton,
        ].filter { !$0.isHidden }
    }

    /// The width the items take.
    var contentWidth: CGFloat {
        var width: CGFloat = 0
        var previous: UIView?
        for item in items {
            if let previous {
                width += spacing(between: previous, and: item)
            }
            width += size(of: item).width
            previous = item
        }
        return ceil(width)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        var x: CGFloat = 0
        var previous: UIView?
        for item in items {
            if let previous {
                x += spacing(between: previous, and: item)
            }
            let size = size(of: item)
            item.frame = directionalFrame(CGRect(
                x: x,
                y: ((bounds.height - size.height) / 2).rounded(),
                width: size.width,
                height: size.height,
            ))
            x += size.width
            previous = item
        }
    }

    private func size(of item: UIView) -> CGSize {
        if item is UIButton {
            return CGSize(width: Self.buttonSize, height: Self.buttonSize)
        }
        if item is UIImageView {
            let fitted = item.intrinsicContentSize
            return CGSize(width: ceil(max(0, fitted.width)), height: ceil(max(0, fitted.height)))
        }
        let fitted = item.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: bounds.height))
        return CGSize(width: ceil(fitted.width), height: ceil(fitted.height))
    }

    private func spacing(between first: UIView, and second: UIView) -> CGFloat {
        if first is UIImageView {
            return Self.iconSpacing
        }
        return first is UIButton && second is UIButton ? Self.buttonSpacing : Self.labelSpacing
    }
}
