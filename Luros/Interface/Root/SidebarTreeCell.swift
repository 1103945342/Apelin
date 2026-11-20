import UIKit

/// A row is one accessible element; its disclosure has a matching custom
/// action, so grouping the labels never hides the ability to expand it.
final class SidebarTreeCell: UITableViewCell {
    private let nameLabel = UILabel()
    private let numberLabel = UILabel()
    private let disclosure = UIButton(type: .system)
    private let statusView = ChatRowStatusView()
    private let guidesLayer = CAShapeLayer()
    private var row: SidebarTree.Row?
    @objc dynamic var onToggle: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        isAccessibilityElement = true
        nameLabel.numberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.adjustsFontForContentSizeCategory = true
        numberLabel.adjustsFontForContentSizeCategory = true
        contentView.layer.addSublayer(guidesLayer)
        for view in [nameLabel, numberLabel, disclosure, statusView] { contentView.addSubview(view) }
        disclosure.addTarget(self, action: #selector(toggleTree), for: .touchUpInside)
        disclosure.isAccessibilityElement = false
        guidesLayer.fillColor = UIColor.clear.cgColor
        guidesLayer.lineWidth = 1 / UIScreen.main.scale
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(row: SidebarTree.Row, summary: ChatSummary?, title: String) {
        self.row = row
        nameLabel.text = title
        let isGroup = row.item.chatID == nil
        nameLabel.font = .preferredFont(forTextStyle: isGroup ? .subheadline : .body)
        nameLabel.textColor = isGroup ? .secondaryLabel : .label
        let number = summary?.relationship == .branch ? summary?.branchNumber : nil
        numberLabel.text = number.map(String.init)
        numberLabel.font = .preferredFont(forTextStyle: .caption2)
        numberLabel.textColor = .secondaryLabel
        disclosure.isHidden = !row.expandable
        disclosure.setImage(UIImage(systemName: row.expanded ? "chevron.down" : "chevron.right"), for: .normal)
        disclosure.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold), forImageIn: .normal)
        let actionName = row.expanded ? String(localized: "Collapse") : String(localized: "Expand")
        disclosure.accessibilityLabel = actionName
        statusView.show(row.working ? .working : row.unread ? .unread : nil)
        statusView.isHidden = !row.working && !row.unread
        accessibilityLabel = title
        var values: [String] = []
        if let number { values.append(String(localized: "Branch \(number)")) }
        if row.expandable { values.append(row.expanded ? String(localized: "Expanded") : String(localized: "Collapsed")) }
        if summary?.isPinned == true { values.append(String(localized: "Pinned")) }
        if row.working { values.append(String(localized: "Working")) }
        else if row.unread { values.append(String(localized: "Unread")) }
        accessibilityValue = values.joined(separator: ", ")
        accessibilityTraits = isGroup ? [.button, .header] : [.button]
        accessibilityCustomActions = row.expandable ? [UIAccessibilityCustomAction(name: actionName, target: self, selector: #selector(toggleTreeAccessibility))] : nil
        setNeedsLayout()
    }

    @objc dynamic private func toggleTree() { onToggle?() }

    @objc dynamic private func toggleTreeAccessibility() -> Bool {
        onToggle?()
        return true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let row else { return }
        let width = contentView.bounds.width
        let height = contentView.bounds.height
        // Deep trees compress the guides, not the remaining title to zero.
        let step = min(CGFloat(12), max(0, (width - 160) / CGFloat(max(1, row.layoutDepth))))
        let indent = CGFloat(row.depth) * step
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        func frame(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: rtl ? width - x - w : x, y: y, width: max(0, w), height: h)
        }
        disclosure.frame = frame(4 + indent, 0, 36, height)
        let start = 40 + indent
        let trailing: CGFloat = statusView.isHidden ? 12 : 34
        let badgeSize = numberLabel.sizeThatFits(CGSize(width: width, height: height))
        let badgeWidth = numberLabel.text == nil ? 0 : badgeSize.width + 4
        let available = max(0, width - start - trailing - badgeWidth)
        let titleWidth = min(available, nameLabel.sizeThatFits(CGSize(width: .greatestFiniteMagnitude, height: height)).width)
        nameLabel.frame = frame(start, 0, titleWidth, height)
        numberLabel.frame = frame(start + titleWidth + 3, max(2, height / 2 - nameLabel.font.lineHeight / 2 - 2), badgeWidth, badgeSize.height)
        statusView.frame = frame(width - 30, (height - 20) / 2, 20, 20)
        let path = UIBezierPath()
        func line(_ x: CGFloat, _ top: CGFloat, _ bottom: CGFloat) {
            let x = rtl ? width - x : x
            path.move(to: CGPoint(x: x, y: top))
            path.addLine(to: CGPoint(x: x, y: bottom))
        }
        for (level, continues) in row.guides.enumerated() where continues {
            line(22 + CGFloat(level - 1) * step, 0, height)
        }
        if row.depth > 0 {
            let x = 22 + CGFloat(row.depth - 1) * step
            line(x, 0, row.isLast ? height / 2 : height)
            path.move(to: CGPoint(x: rtl ? width - x : x, y: height / 2))
            let end = 10 + indent
            path.addLine(to: CGPoint(x: rtl ? width - end : end, y: height / 2))
        }
        if row.expanded {
            // Continue from the disclosure to the first child's incoming guide.
            line(22 + CGFloat(row.depth) * step, height / 2 + 9, height)
        }
        guidesLayer.frame = contentView.bounds
        guidesLayer.strokeColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
        guidesLayer.path = path.cgPath
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onToggle = nil
        row = nil
        accessibilityCustomActions = nil
    }
}
