import UIKit

/// The composer's measures, in one place: what the bands space themselves by,
/// how round their corners are, and the colours a control takes in each of its
/// states.
///
/// The numbers are a scale, not a copy: they carry the same ratios and the same
/// intent from one platform's design, read as points on this one and drawn with
/// the system's own materials. Nothing here is a magic number chosen per view.
enum ComposerMetrics {
    /// Space between one thing and the next, smallest first.
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    /// Corner radii: the ground, the panels above it, and the rows inside them.
    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
        static let xl: CGFloat = 16
        static let ground: CGFloat = 20
    }

    /// The text band: two lines at rest, seven before it scrolls inside itself.
    enum Input {
        static let minHeight: CGFloat = 60
        static let maxHeight: CGFloat = 168
        /// The room the text keeps around it, inside the band's own inset.
        static let contentPadding: CGFloat = 4
        static let iconSize: CGFloat = 32
        static let iconSpacing: CGFloat = 10
        // The text band and the row beneath it sit in one card: the band's
        // own inset is the text's breathing room, and the row takes its own,
        // so the card's height is the text plus one row, not text plus two
        // insets' worth of air.
        static let inset = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
    }

    /// The send button, and the stop it becomes: one control, two jobs.
    enum Send {
        static let diameter: CGFloat = 44
        static let iconSize: CGFloat = 22
        static let inset: CGFloat = 4
    }

    /// A panel that opens above the composer: how tall before it scrolls.
    enum Panel {
        static let maxBodyHeight: CGFloat = 200
        static let maxQueueHeight: CGFloat = 160
        static let maxContextBodyHeight: CGFloat = 160
    }

    /// How a panel arrives and leaves: it grows into place, and leaves faster
    /// than it came, so a dismissal never feels held up.
    enum Animation {
        static let enterDuration: TimeInterval = 0.22
        static let exitDuration: TimeInterval = 0.18
    }
}

/// The colours a composer control takes, resolved per trait collection so a
/// change of appearance repaints without the view asking again.
///
/// The status four are the only colours that carry meaning beyond the system's
/// own: an idle send, a run that can be stopped, a message that will wait its
/// turn, and the ring as it fills toward its threshold.
enum ComposerPalette {
    /// Idle, with something to send.
    static let send = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.29, green: 0.82, blue: 0.49, alpha: 1)
            : UIColor(red: 0.13, green: 0.77, blue: 0.37, alpha: 1)
    }

    /// What the send button shows while a run is going and nothing is typed:
    /// a stop, in the colour of stopping.
    static let stop = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.97, green: 0.44, blue: 0.44, alpha: 1)
            : UIColor(red: 0.86, green: 0.15, blue: 0.15, alpha: 1)
    }

    /// Sent during a run: shown at once, its turn taken later.
    static let queued = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.96, green: 0.62, blue: 0.04, alpha: 1)
            : UIColor(red: 0.96, green: 0.49, blue: 0, alpha: 1)
    }

    /// Nothing to send, or a send that cannot be taken right now.
    static let inert = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.12)
            : UIColor(white: 0, alpha: 0.06)
    }

    /// A label on a filled control: dark on the light fills, white on the rest.
    static func label(on fill: UIColor) -> UIColor {
        fill.luminance() > 0.6 ? UIColor(white: 0.11, alpha: 1) : .white
    }

    /// The context ring's arc: quiet until the room runs short.
    static func contextLevel(_ fraction: Double) -> UIColor {
        if fraction >= 0.9 { return .systemRed }
        if fraction >= 0.75 { return .systemOrange }
        return .secondaryLabel
    }

    /// The mode pill, by what the run is allowed to do.
    static func mode(for mode: ComposerMode) -> (fill: UIColor, label: UIColor) {
        switch mode {
        case .plan: (UIColor.systemBlue.withAlphaComponent(0.18), .systemBlue)
        case .build: (UIColor.systemGreen.withAlphaComponent(0.18), .systemGreen)
        case .auto: (UIColor.systemRed.withAlphaComponent(0.18), .systemRed)
        }
    }
}

extension UIColor {
    /// The fill's own brightness, as the eye reads it: what decides which way a
    /// label on it has to go.
    func luminance() -> CGFloat {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return 0 }
        return 0.299 * red + 0.587 * green + 0.114 * blue
    }
}
