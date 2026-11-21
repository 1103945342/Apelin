import UIKit

/// The sheet the chat is written on: a paper Luros draws, the reader's own
/// picture faded to `opacity`, or nothing at all, leaving the app's own
/// background.
///
/// It never takes a touch: everything above it — the message list, the
/// composer — keeps working as if it were the app's background.
final class ChatBackgroundView: UIView {
    /// What to draw.
    var background: ChatBackground = .none {
        didSet { apply() }
    }

    /// How much of a picture shows. Papers ignore it.
    var opacity: Double = 1 {
        didSet { imageView.alpha = opacity }
    }

    private let paperView = PaperBackgroundView()
    private let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
        paperView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(paperView)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.isAccessibilityElement = false
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(imageView)
        apply()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        paperView.frame = bounds
        imageView.frame = bounds
    }

    private func apply() {
        switch background {
        case .none:
            paperView.isHidden = true
            imageView.image = nil
            imageView.isHidden = true
        case let .paper(paper):
            paperView.paper = paper
            paperView.isHidden = false
            imageView.image = nil
            imageView.isHidden = true
        case .image:
            paperView.isHidden = true
            imageView.image = Self.picture()
            imageView.isHidden = imageView.image == nil
            imageView.alpha = opacity
        }
    }

    // MARK: - The picture

    /// The reader's picture, read once per file: the chat asks for it every
    /// time it comes back on screen.
    private static var cachedPicture: UIImage?
    private static var cachedStamp: Date?

    private static func picture() -> UIImage? {
        let url = ChatBackground.imageURL
        let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if let stamp, stamp == cachedStamp, let cachedPicture {
            return cachedPicture
        }
        let loaded = UIImage(contentsOfFile: url.path)
        cachedPicture = loaded
        cachedStamp = stamp
        return loaded
    }

    /// A small picture of a paper, as a settings row shows it.
    static func preview(_ paper: ChatBackground.Paper, size: CGSize, traits: UITraitCollection? = nil) -> UIImage {
        let view = PaperBackgroundView(frame: CGRect(origin: .zero, size: size))
        view.overrideUserInterfaceStyle = traits?.userInterfaceStyle ?? .unspecified
        view.paper = paper
        view.scale = 0.4
        view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            view.layer.render(in: context.cgContext)
        }
    }

    /// The reader's picture as a small rounded square, for the row that names it.
    static func picturePreview(size: CGSize) -> UIImage? {
        guard let image = picture(),
              let scaled = image.preparingThumbnail(of: size)
        else { return nil }
        let format = UIGraphicsImageRendererFormat.preferred()
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let path = UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4)
            path.addClip()
            scaled.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// The colour a paper is printed on: the bar's frost fades into it.
    static func base(_ paper: ChatBackground.Paper, traits: UITraitCollection) -> UIColor {
        PaperBackgroundView.base(paper, traits: traits)
    }
}
