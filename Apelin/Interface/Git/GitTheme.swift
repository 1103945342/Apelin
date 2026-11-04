import SnapKit
import Then
import UIKit

/// The Git screen's colours, type and spacing, taken from the reference app
/// so the page is the page and not an interpretation of it. Its palette is
/// the light and dark pairs that app ships; a colour is resolved for the
/// trait collection it is drawn in.
enum GitTheme {
    // MARK: - Colour

    static let primary = pair(light: 0x2563EB, dark: 0x60A5FA)
    static let onPrimary = pair(light: 0xFFFFFF, dark: 0x082F49)
    static let primaryContainer = pair(light: 0xDBEAFE, dark: 0x0F3A63)
    static let onPrimaryContainer = pair(light: 0x0B3B76, dark: 0xDBEAFE)

    static let secondary = pair(light: 0x0284C7, dark: 0x7DD3FC)
    static let secondaryContainer = pair(light: 0xE0F2FE, dark: 0x0C4A6E)
    static let onSecondaryContainer = pair(light: 0x075985, dark: 0xBAE6FD)

    static let tertiary = pair(light: 0x16A34A, dark: 0x22C55E)
    static let tertiaryContainer = pair(light: 0xDCFCE7, dark: 0x14532D)
    static let onTertiaryContainer = pair(light: 0x15803D, dark: 0xBBF7D0)

    static let pageBackground = pair(light: 0xF8F8F8, dark: 0x07111F)
    static let cardSurface = pair(light: 0xFFFFFF, dark: 0x0D1B2E)
    static let mutedSurface = pair(light: 0xF2F2F7, dark: 0x13273F)
    static let buttonMutedBackground = pair(light: 0xF0F2F5, dark: 0x1E293B)

    static let onSurface = pair(light: 0x0F172A, dark: 0xEAF2FF)
    static let onSurfaceVariant = pair(light: 0x475569, dark: 0xB8C7DA)
    static let surfaceVariant = pair(light: 0xEAF4FF, dark: 0x13273F)
    static let subtleText = pair(light: 0x8E8E93, dark: 0x94A3B8)
    static let subtleBorder = pair(light: 0xE5E5EA, dark: 0x2A3F56)
    static let outline = pair(light: 0xD1D1D6, dark: 0x64748B)
    static let outlineVariant = pair(light: 0xE5E5EA, dark: 0x334155)

    static let success = pair(light: 0x22C55E, dark: 0x4ADE80)
    static let warning = pair(light: 0xF59E0B, dark: 0xFBBF24)
    static let error = pair(light: 0xDC2626, dark: 0xF87171)
    static let diffAdd = pair(light: 0x22C55E, dark: 0x4ADE80)
    static let diffRemove = pair(light: 0xEF4444, dark: 0xF87171)

    static let scrim = UIColor.black.withAlphaComponent(0.32)

    /// The eight lanes' colours, cycled.
    static let lanes: [UIColor] = [
        0x2563EB, 0x16A34A, 0xF59E0B, 0x8B5CF6, 0x06B6D4, 0xEF4444, 0xEC4899, 0xEAB308,
    ].map { UIColor(rgb: $0) }

    static func laneColor(_ lane: Int) -> UIColor {
        lanes[((lane % lanes.count) + lanes.count) % lanes.count]
    }

    /// A path's badge: the colour of what happened to it, and the ink that
    /// stays readable on it.
    static func statusColors(_ code: String) -> (background: UIColor, foreground: UIColor) {
        let background: UIColor = switch code.first {
        case "A": UIColor(rgb: 0x16A34A)
        case "M": UIColor(rgb: 0xD97706)
        case "D": UIColor(rgb: 0xDC2626)
        case "R", "C": UIColor(rgb: 0x2563EB)
        case "?": UIColor(rgb: 0x94A3B8)
        case "U": UIColor(rgb: 0x9333EA)
        case "T": UIColor(rgb: 0x0891B2)
        default: UIColor(rgb: 0x64748B)
        }
        return (background, background.isLight ? UIColor(rgb: 0x0F172A) : .white)
    }

    // MARK: - Type

    static let titleLarge = font(22, .semibold)
    static let titleMedium = font(16, .semibold)
    static let titleSmall = font(14, .semibold)
    static let bodyLarge = font(16, .regular)
    static let bodyMedium = font(14, .regular)
    static let bodySmall = font(12, .regular)
    static let labelLarge = font(14, .medium)
    static let labelMedium = font(12, .medium)
    static let labelSmall = font(11, .medium)

    static func font(_ size: CGFloat, _ weight: UIFont.Weight) -> UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: size, weight: weight))
    }

    static func mono(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: size, weight: weight))
    }

    static let titleLargeMono = mono(20, .semibold)

    // MARK: - Metrics

    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 10
        static let mdLarge: CGFloat = 12
        static let lg: CGFloat = 14
        static let xl: CGFloat = 16
        static let pill: CGFloat = 999
    }

    // MARK: - Private

    private static func pair(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light)
        }
    }
}

extension UIColor {
    convenience init(rgb: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: alpha,
        )
    }

    /// Whether black ink reads better on this colour than white.
    var isLight: Bool {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        return luminance > 0.45
    }
}

enum GitIcon {
    static func image(_ name: String, pointSize: CGFloat = 17, weight: UIImage.SymbolWeight = .regular) -> UIImage? {
        UIImage(
            systemName: name,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight),
        )
    }

    /// The reference app's Feather set, in the nearest SF Symbols.
    enum Name {
        static let back = "chevron.left"
        static let close = "xmark"
        static let key = "key"
        static let refresh = "arrow.clockwise"
        static let chevronDown = "chevron.down"
        static let chevronRight = "chevron.right"
        static let activity = "waveform.path.ecg"
        static let branch = "arrow.triangle.branch"
        static let commit = "record.circle"
        static let check = "checkmark"
        static let plus = "plus"
        static let minus = "minus"
        static let archive = "archivebox"
        static let downloadCloud = "icloud.and.arrow.down"
        static let uploadCloud = "icloud.and.arrow.up"
        static let download = "arrow.down.circle"
        static let folder = "folder"
        static let copy = "doc.on.doc"
        static let eyeOff = "eye.slash"
        static let fileText = "doc.text"
        static let rotate = "arrow.counterclockwise"
        static let trash = "trash"
        static let merge = "arrow.triangle.merge"
        static let edit = "pencil"
        static let cloud = "cloud"
        static let tag = "tag"
        static let search = "magnifyingglass"
        static let zap = "bolt.fill"
        static let file = "doc"
        static let editSquare = "square.and.pencil"
        static let wrap = "arrow.turn.down.left"
        static let gear = "gearshape"
        static let error = "exclamationmark.triangle"
    }
}

/// A hairline that keeps its width at every scale.
final class GitHairlineView: UIView {
    init(color: UIColor = GitTheme.subtleBorder) {
        super.init(frame: .zero)
        backgroundColor = color
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// One labelled figure in an overview card: the number in its colour, the
/// word under it.
final class GitMetricView: UIView {
    private let countLabel = UILabel().then {
        $0.font = GitTheme.mono(16, .medium)
        $0.adjustsFontForContentSizeCategory = true
        $0.numberOfLines = 1
    }

    private let titleLabel = UILabel().then {
        $0.font = GitTheme.labelSmall
        $0.textColor = GitTheme.onSurfaceVariant
        $0.adjustsFontForContentSizeCategory = true
        $0.numberOfLines = 1
    }

    init(title: String, count: Int, color: UIColor) {
        super.init(frame: .zero)
        backgroundColor = GitTheme.mutedSurface
        layer.cornerRadius = GitTheme.Radius.md
        layer.cornerCurve = .continuous
        countLabel.textColor = color
        countLabel.text = "\(count)"
        titleLabel.text = title
        let stack = UIStackView(arrangedSubviews: [countLabel, titleLabel]).then {
            $0.axis = .vertical
            $0.spacing = 0
        }
        addSubview(stack)
        stack.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(GitTheme.Space.sm)
        }
        isAccessibilityElement = true
        accessibilityLabel = "\(title) \(count)"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
