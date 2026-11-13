import UIKit

/// Rolls a label's one line through a list of tips: one every five seconds,
/// the line rising out of the band and the next coming up under it, so the box
/// reads as having more than one thing to say.
///
/// The clock is here and the order in `ComposerTipRotation`. Whether the label
/// is on screen at all stays with the view that owns it: it starts and stops
/// this with the text, and answers `isVisible` when a roll has to know before
/// it puts the label back.
@MainActor
final class ComposerTipRoller {
    /// How long a tip stays: long enough to read twice, short enough that the
    /// box never looks stuck on one line.
    static let interval: TimeInterval = 5
    /// How far the line travels as it rolls: less than the band's own height,
    /// so the move reads as a roll rather than a replacement.
    private static let travel: CGFloat = 6
    private static let outDuration: TimeInterval = 0.18
    private static let inDuration: TimeInterval = 0.24

    private weak var label: UILabel?
    private let tips: [String]
    private var rotation: ComposerTipRotation
    private var roll: Task<Void, Never>?

    /// Whether the label is to be seen now — the box is empty, its page is in
    /// front. A roll that ends while it is not leaves the label invisible.
    var isVisible: (() -> Bool)?
    /// Told which tip is showing, after each roll: the text field, for one,
    /// names itself after it.
    var onShow: ((String) -> Void)?

    init(label: UILabel, tips: [String]) {
        self.label = label
        self.tips = tips
        rotation = ComposerTipRotation(count: tips.count)
    }

    deinit {
        roll?.cancel()
    }

    var current: String {
        tips.isEmpty ? "" : tips[rotation.index]
    }

    var isRolling: Bool {
        roll != nil
    }

    /// Rolls while `active`, and rests on the tip it was showing when not: the
    /// box comes back to the same line it left.
    ///
    /// VoiceOver holds it still: a name that changes under a reader with no
    /// announcement reads as the field renaming itself, and the tip is not
    /// worth that.
    func setActive(_ active: Bool) {
        guard active else {
            stop()
            return
        }
        if label?.text != current {
            show(current, animated: false)
        }
        guard !UIAccessibility.isVoiceOverRunning else {
            stop()
            return
        }
        start()
    }

    /// Leads with the tip at `index`, now, and puts the clock back to zero:
    /// something just happened that this tip is about.
    func lead(_ index: Int) {
        guard !tips.isEmpty else { return }
        rotation.lead(index)
        show(current, animated: (label?.alpha ?? 0) > 0 && label?.window != nil)
        guard isRolling else { return }
        stop()
        start()
    }

    private func start() {
        guard roll == nil, tips.count > 1 else { return }
        roll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.interval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                rotation.advance()
                show(current, animated: true)
            }
        }
    }

    /// Stops the clock where it is: the view calls it as it goes away, and
    /// `setActive(false)` when the box fills with text. The tip it was on is
    /// the one it comes back to.
    func stop() {
        roll?.cancel()
        roll = nil
    }

    private func show(_ text: String, animated: Bool) {
        guard let label else { return }
        onShow?(text)
        // Reduce Motion, a label the box is not showing, or a page it is not
        // on: the line is replaced where it stands.
        guard animated, !UIAccessibility.isReduceMotionEnabled, label.alpha > 0, label.window != nil else {
            label.layer.removeAllAnimations()
            label.transform = .identity
            label.text = text
            label.alpha = (isVisible?() ?? true) ? 1 : 0
            return
        }
        UIView.animate(withDuration: Self.outDuration, delay: 0, options: [.curveEaseIn]) {
            label.alpha = 0
            label.transform = CGAffineTransform(translationX: 0, y: -Self.travel)
        } completion: { [weak self, weak label] _ in
            guard let label else { return }
            label.text = text
            label.transform = CGAffineTransform(translationX: 0, y: Self.travel)
            let visible = self?.isVisible?() ?? true
            UIView.animate(withDuration: Self.inDuration, delay: 0, options: [.curveEaseOut]) {
                label.alpha = visible ? 1 : 0
                label.transform = .identity
            }
        }
    }
}
