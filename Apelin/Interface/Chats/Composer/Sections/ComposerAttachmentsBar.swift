// Lakr233's Inhouse Code, from FlowDown.
// I CAN DO WHAT THE FUCK I WANT.

import UIKit

/// FlowDown's horizontal image and document previews, with removable draft items.
final class ComposerAttachmentsBar: ComposerSectionView, UICollectionViewDataSource,
    UICollectionViewDelegateFlowLayout
{
    var onRemove: ((UUID) -> Void)?
    var onPreview: ((ComposerAttachment) -> Void)?
    private let inset = UIEdgeInsets(top: 10, left: 10, bottom: 0, right: 10)

    private var items: [ComposerAttachment] = []
    private let collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())

    override func initializeViews() {
        super.initializeViews()
        clipsToBounds = true
        let layout = collectionView.collectionViewLayout as! UICollectionViewFlowLayout
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 10
        layout.sectionInset = UIEdgeInsets(top: 0, left: inset.left, bottom: 0, right: inset.right)
        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.alwaysBounceHorizontal = true
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(AttachmentCell.self, forCellWithReuseIdentifier: "attachment")
        addSubview(collectionView)
    }

    func show(_ attachments: [ComposerAttachment]) {
        items = attachments
        collectionView.reloadData()
        heightPublisher.send(items.isEmpty ? 0 : 80 + inset.top + inset.bottom)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        collectionView.frame = CGRect(x: 0, y: inset.top, width: bounds.width, height: 80)
    }

    func collectionView(_: UICollectionView, numberOfItemsInSection _: Int) -> Int {
        items.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath,
    ) -> UICollectionViewCell {
        let item = items[indexPath.item]
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: "attachment",
            for: indexPath,
        ) as! AttachmentCell
        cell.show(item)
        cell.remove = { [weak self] in self?.onRemove?(item.id) }
        return cell
    }

    func collectionView(_: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        onPreview?(items[indexPath.item])
    }

    func collectionView(
        _: UICollectionView,
        layout _: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath,
    ) -> CGSize {
        CGSize(width: items[indexPath.item].isImage ? 80 : 240, height: 80)
    }
}

private final class AttachmentCell: UICollectionViewCell {
    private let imageView = UIImageView()
    private let nameLabel = UILabel()
    private let textLabel = UILabel()
    private let deleteButton = UIButton(type: .system)
    var remove: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .gray.withAlphaComponent(0.1)
        contentView.layer.cornerRadius = 10
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true
        imageView.contentMode = .scaleAspectFill
        nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        textLabel.font = .systemFont(ofSize: 12)
        textLabel.textColor = .secondaryLabel
        nameLabel.lineBreakMode = .byTruncatingTail
        textLabel.numberOfLines = 0
        textLabel.lineBreakMode = .byTruncatingTail
        for view in [imageView, nameLabel, textLabel, deleteButton] {
            contentView.addSubview(view)
        }
        deleteButton.setImage(UIImage(systemName: "xmark")?.withRenderingMode(.alwaysTemplate), for: .normal)
        // The disc and the glyph carry their own colours: the button sits on
        // top of a photograph, and the app's tint is not guaranteed to stand
        // out against one.
        deleteButton.tintColor = .white
        deleteButton.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        deleteButton.layer.cornerRadius = 11
        deleteButton.layer.cornerCurve = .continuous
        deleteButton.layer.borderWidth = 1 / UIScreen.main.scale
        deleteButton.layer.borderColor = UIColor.white.withAlphaComponent(0.65).cgColor
        deleteButton.accessibilityLabel = String(localized: "Remove Attachment")
        deleteButton.addAction(UIAction { [weak self] _ in self?.remove?() }, for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    func show(_ item: ComposerAttachment) {
        imageView.image = item.isImage ? UIImage(data: item.data) : nil
        nameLabel.text = item.isImage ? nil : item.name
        textLabel.text = item.isImage
            ? nil
            : item.text.map { String($0.replacingOccurrences(of: "\n", with: " ").prefix(500)) }
            ?? ByteCountFormatter.string(fromByteCount: Int64(item.data.count), countStyle: .file)
        accessibilityLabel = item.name
        accessibilityHint = String(localized: "Opens the attachment preview.")
        accessibilityCustomActions = [UIAccessibilityCustomAction(
            name: String(localized: "Remove Attachment"),
        ) { [weak self] _ in
            self?.remove?()
            return true
        }]
        setNeedsLayout()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageView.image = nil
        remove = nil
        accessibilityCustomActions = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = contentView.bounds
        // the remove button at the trailing corner, the name before it
        deleteButton.frame = contentView.directionalFrame(CGRect(x: bounds.width - 26, y: 4, width: 22, height: 22))
        nameLabel.frame = contentView.directionalFrame(CGRect(x: 4, y: 4, width: bounds.width - 34, height: 20))
        textLabel.frame = CGRect(x: 4, y: 28, width: bounds.width - 8, height: bounds.height - 32)
    }
}
