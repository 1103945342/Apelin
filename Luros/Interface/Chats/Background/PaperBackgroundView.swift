import UIKit

/// One of the papers Luros draws behind the chat: a warm ground, an edge that
/// darkens, and the fibre of real paper — all painted from code, with no
/// picture shipped for it.
final class PaperBackgroundView: UIView {
    /// Which paper to draw.
    var paper: ChatBackground.Paper = .rice {
        didSet {
            applyStyle()
            setNeedsLayout()
        }
    }

    /// Spacing of the drawn rules and dots, relative to a full page: a row's
    /// 44 pt preview draws them closer together so more than one shows.
    var scale: CGFloat = 1 {
        didSet { setNeedsLayout() }
    }

    private let base = CAGradientLayer()
    private let vignette = CAGradientLayer()
    private let pattern = CAShapeLayer()
    private let grain = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear

        // The ground: three stops, lit from the top left and sinking to the
        // bottom right, as a sheet under a window does.
        base.startPoint = CGPoint(x: 0.10, y: 0)
        base.endPoint = CGPoint(x: 0.85, y: 1)
        base.locations = [0, 0.48, 1]
        layer.addSublayer(base)

        // The drawn rules, above the ground and under the edge.
        pattern.fillColor = UIColor.clear.cgColor
        layer.addSublayer(pattern)

        // The edge: clear in the middle, ink at the rim.
        vignette.type = .radial
        vignette.colors = [UIColor.clear.cgColor, UIColor.clear.cgColor, UIColor.clear.cgColor]
        vignette.locations = [0.28, 0.70, 1]
        vignette.startPoint = CGPoint(x: 0.5, y: 0.44)
        vignette.endPoint = CGPoint(x: 1.05, y: 1.05)
        layer.addSublayer(vignette)

        // The fibre: a one-pixel noise tile, repeated over the whole page.
        grain.backgroundColor = UIColor(patternImage: Self.grainTexture)
        grain.isUserInteractionEnabled = false
        grain.isAccessibilityElement = false
        addSubview(grain)

        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        base.frame = bounds
        vignette.frame = bounds
        pattern.frame = bounds
        grain.frame = bounds
        pattern.path = drawnPattern()
        CATransaction.commit()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            applyStyle()
        }
    }

    /// The colour a paper is printed on, for whatever has to fade into it —
    /// the bar's frost above the conversation.
    static func base(_ paper: ChatBackground.Paper, traits: UITraitCollection) -> UIColor {
        paper.design(dark: traits.userInterfaceStyle == .dark).base[1]
    }

    private func applyStyle() {
        let design = paper.design(dark: traitCollection.userInterfaceStyle == .dark)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        base.colors = design.base.map(\.cgColor)
        vignette.colors = design.edge.map(\.cgColor)
        grain.alpha = design.grain
        if paper.pattern == .dots {
            pattern.fillColor = design.ink.cgColor
            pattern.strokeColor = UIColor.clear.cgColor
        } else {
            pattern.fillColor = UIColor.clear.cgColor
            pattern.strokeColor = design.ink.cgColor
            pattern.lineWidth = 1 / max(traitCollection.displayScale, 1)
        }
        CATransaction.commit()
    }

    private func drawnPattern() -> CGPath? {
        let path = CGMutablePath()
        switch paper.pattern {
        case .none:
            return nil
        case .ruled:
            let spacing = 30 * scale
            var y = spacing
            while y < bounds.maxY {
                path.move(to: CGPoint(x: bounds.minX, y: y))
                path.addLine(to: CGPoint(x: bounds.maxX, y: y))
                y += spacing
            }
        case .grid:
            let spacing = 24 * scale
            var x = spacing
            while x < bounds.maxX {
                path.move(to: CGPoint(x: x, y: bounds.minY))
                path.addLine(to: CGPoint(x: x, y: bounds.maxY))
                x += spacing
            }
            var y = spacing
            while y < bounds.maxY {
                path.move(to: CGPoint(x: bounds.minX, y: y))
                path.addLine(to: CGPoint(x: bounds.maxX, y: y))
                y += spacing
            }
        case .dots:
            let spacing = 18 * scale
            let radius = max(1.2 * scale, 0.7)
            var y = spacing
            while y < bounds.maxY {
                var x = spacing
                while x < bounds.maxX {
                    path.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                    x += spacing
                }
                y += spacing
            }
        }
        return path
    }

    /// One tile, drawn once: one-pixel specks at scale 1, so a 3× screen shows
    /// them as fibre rather than as grain.
    private static let grainTexture: UIImage = {
        let side = 96
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        format.scale = 1
        return UIGraphicsImageRenderer(
            size: CGSize(width: side, height: side),
            format: format,
        ).image { context in
            let cg = context.cgContext
            var random = SplitMix64(seed: 0x7061_7065_7200_0001)
            for y in 0 ..< side {
                for x in 0 ..< side {
                    let value = CGFloat(random.next() % 1_000) / 1_000
                    cg.setFillColor(UIColor(white: value, alpha: 1).cgColor)
                    cg.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
    }()
}

// MARK: - What each paper is made of

extension ChatBackground.Paper {
    /// The rules a paper draws over its ground, if any.
    enum Pattern {
        case none
        case ruled
        case grid
        case dots
    }

    var pattern: Pattern {
        switch self {
        case .rice, .ivory, .kraft, .slate: .none
        case .ruled: .ruled
        case .grid: .grid
        case .dots: .dots
        }
    }

    /// The ground, the edge and the fibre of one paper in one appearance.
    /// Papers are their own colours in the dark, not the light ones dimmed:
    /// the conversation's text is white there.
    struct Design {
        let base: [UIColor]
        let edge: [UIColor]
        let ink: UIColor
        let grain: CGFloat
    }

    func design(dark: Bool) -> Design {
        let ink = Self.ink
        switch self {
        case .rice:
            return Design(
                base: dark
                    ? [Self.rgb(0x1C1B18), Self.rgb(0x171613), Self.rgb(0x201E1A)]
                    : [Self.rgb(0xF6F1E7), Self.rgb(0xEDE5D7), Self.rgb(0xF8F4EC)],
                edge: dark
                    ? [.clear, UIColor(white: 0, alpha: 0.12), UIColor(white: 0, alpha: 0.36)]
                    : [.clear, Self.rgb(0x1A1917, alpha: 0.05), Self.rgb(0x1A1917, alpha: 0.13)],
                ink: ink,
                grain: dark ? 0.05 : 0.075,
            )
        case .ivory:
            return Design(
                base: dark
                    ? [Self.rgb(0x1A1A1C), Self.rgb(0x151517), Self.rgb(0x1E1E21)]
                    : [Self.rgb(0xFBFAF6), Self.rgb(0xF2F0E9), Self.rgb(0xFDFCFA)],
                edge: dark
                    ? [.clear, UIColor(white: 0, alpha: 0.12), UIColor(white: 0, alpha: 0.34)]
                    : [.clear, Self.rgb(0x14161A, alpha: 0.04), Self.rgb(0x14161A, alpha: 0.10)],
                ink: ink,
                grain: dark ? 0.04 : 0.05,
            )
        case .kraft:
            return Design(
                base: dark
                    ? [Self.rgb(0x2A241C), Self.rgb(0x221D16), Self.rgb(0x2E2820)]
                    : [Self.rgb(0xE7D8BE), Self.rgb(0xD9C6A6), Self.rgb(0xEEDFC8)],
                edge: dark
                    ? [.clear, UIColor(white: 0, alpha: 0.14), UIColor(white: 0, alpha: 0.40)]
                    : [.clear, Self.rgb(0x3A2C1A, alpha: 0.06), Self.rgb(0x3A2C1A, alpha: 0.16)],
                ink: ink,
                grain: dark ? 0.09 : 0.13,
            )
        case .slate:
            return Design(
                base: dark
                    ? [Self.rgb(0x191C20), Self.rgb(0x14171A), Self.rgb(0x1D2126)]
                    : [Self.rgb(0xE9EDF0), Self.rgb(0xDCE3E8), Self.rgb(0xEEF2F5)],
                edge: dark
                    ? [.clear, UIColor(white: 0, alpha: 0.12), UIColor(white: 0, alpha: 0.36)]
                    : [.clear, Self.rgb(0x1B2530, alpha: 0.04), Self.rgb(0x1B2530, alpha: 0.11)],
                ink: ink,
                grain: dark ? 0.04 : 0.05,
            )
        case .ruled, .grid, .dots:
            var design = ChatBackground.Paper.rice.design(dark: dark)
            design = Design(
                base: design.base,
                edge: design.edge,
                ink: dark ? UIColor(white: 1, alpha: 0.10) : Self.rgb(0x1A1917, alpha: 0.10),
                grain: design.grain,
            )
            return design
        }
    }

    private static var ink: UIColor { rgb(0x1A1917) }

    private static func rgb(_ value: UInt32, alpha: CGFloat = 1) -> UIColor {
        UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: alpha,
        )
    }
}

/// A fixed sequence: the fibre is the same on every launch, so the page never
/// shifts under what the reader is reading.
struct SplitMix64 {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
