import ImageIO
import LurosCore
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// Settings ▸ Preferences ▸ Chat Background: the app's own background, one of
/// the papers Luros draws, or a picture of the reader's that the chat shows
/// through by the opacity they pick.
///
/// A paper is drawn, so it is shown in full and has no opacity of its own;
/// only the reader's picture can be faded, which is the whole point of a
/// picture — the app's colours show behind it.
final class ChatBackgroundController: TableController {
    private enum Section: Hashable {
        case plain
        case papers
        case picture
    }

    private enum Row: Hashable {
        case none
        case paper(ChatBackground.Paper)
        case choose
        case opacity
        case remove
    }

    private struct RowContent: Equatable {
        let row: Row
        let title: String
        let detail: String?
        let selected: Bool
        let preview: UIImage?
    }

    /// The whole of the picture, down in steps a reader can tell apart.
    private static let opacityChoices: [Double] = [1, 0.85, 0.7, 0.55, 0.4, 0.25]

    private lazy var dataSource = TableDataSource<Section, Row, RowContent>(
        tableView: tableView,
        identifier: { $0.row },
    ) { [weak self] table, _, row in
        self?.cell(in: table, content: row)
    }

    init() {
        super.init(style: .insetGrouped)
        title = String(localized: "Chat Background")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.backButtonDisplayMode = .minimal
        dataSource.headerTitle = { section in
            section == .papers ? String(localized: "Papers") : nil
        }
        dataSource.footerTitle = { section in
            switch section {
            case .plain:
                return nil
            case .papers:
                return String(localized: "A paper is drawn by Luros and fills the chat as it is; only a picture of your own can be made see-through.")
            case .picture:
                return ChatBackground.hasImage
                    ? String(localized: "Opacity lets the app's colours show through the picture. The picture is copied into Luros's folder and scaled down when it is very large, so it stays after the photo app's temporary file is gone.")
                    : String(localized: "Choose a picture from your photo library. It is copied into Luros's folder and scaled down when it is very large, so it stays after the photo app's temporary file is gone.")
            }
        }
        updateRows()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateRows()
    }

    private func updateRows() {
        let current = ChatBackground.current
        let chosen: ChatBackground.Paper? = {
            if case let .paper(paper) = current { return paper }
            return nil
        }()
        var sections: [(Section, [RowContent])] = [
            (.plain, [
                RowContent(row: .none, title: String(localized: "None"), detail: nil, selected: current == .none, preview: nil),
            ]),
            (.papers, ChatBackground.Paper.allCases.map { paper in
                RowContent(
                    row: .paper(paper),
                    title: paper.title,
                    detail: nil,
                    selected: chosen == paper,
                    preview: ChatBackgroundView.preview(paper, size: CGSize(width: 44, height: 44), traits: traitCollection),
                )
            }),
        ]
        var picture: [RowContent] = [
            RowContent(
                row: .choose,
                title: ChatBackground.hasImage
                    ? String(localized: "Replace Image")
                    : String(localized: "Choose Image"),
                detail: nil,
                selected: false,
                preview: ChatBackground.hasImage
                    ? ChatBackgroundView.picturePreview(size: CGSize(width: 44, height: 44))
                    : nil,
            ),
        ]
        if ChatBackground.hasImage {
            picture.append(RowContent(
                row: .opacity,
                title: String(localized: "Opacity"),
                detail: Preferences.percentText(ChatBackground.opacity),
                selected: false,
                preview: nil,
            ))
            picture.append(RowContent(
                row: .remove,
                title: String(localized: "Remove Image"),
                detail: nil,
                selected: false,
                preview: nil,
            ))
        }
        sections.append((.picture, picture))
        dataSource.update(sections, reconfigure: true)
    }

    private func cell(in tableView: UITableView, content value: RowContent) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "background")
            ?? UITableViewCell(style: .value1, reuseIdentifier: "background")
        var content = UIListContentConfiguration.valueCell()
        content.text = value.title
        content.secondaryText = value.detail
        if let preview = value.preview {
            content.image = preview
            content.imageProperties.maximumSize = CGSize(width: 44, height: 44)
            content.imageProperties.cornerRadius = 4
        }
        cell.contentConfiguration = content
        switch value.row {
        case .none, .paper:
            cell.accessoryType = value.selected ? .checkmark : .none
            cell.selectionStyle = .default
            cell.accessibilityTraits = value.selected ? [.button, .selected] : [.button]
        case .choose, .opacity:
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
            cell.accessibilityTraits = [.button]
        case .remove:
            cell.accessoryType = .none
            cell.selectionStyle = .default
            cell.accessibilityTraits = [.button]
            content.textProperties.color = .systemRed
            cell.contentConfiguration = content
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.value(at: indexPath)?.row else { return }
        switch row {
        case .none:
            ChatBackground.current = .none
            updateRows()
        case let .paper(paper):
            ChatBackground.current = .paper(paper)
            updateRows()
        case .choose:
            choosePicture()
        case .opacity:
            let choices = Self.opacityChoices
            let current = ChatBackground.opacity
            push(SettingChoiceController(
                title: String(localized: "Opacity"),
                options: choices.map { Preferences.percentText($0) },
                selected: choices.enumerated().min { abs($0.element - current) < abs($1.element - current) }?.offset ?? 1,
            ) { index in
                ChatBackground.opacity = choices[index]
                self.updateRows()
            })
        case .remove:
            confirmRemoval()
        }
    }

    private func push(_ page: UIViewController) {
        navigationController?.pushViewController(page, animated: true)
    }

    // MARK: - The reader's own picture

    private func choosePicture() {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func confirmRemoval() {
        let alert = UIAlertController(
            title: String(localized: "Remove Image"),
            message: String(localized: "The picture is deleted from Luros's folder. The chat goes back to the app's own background."),
            preferredStyle: .alert,
        )
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Remove"), style: .destructive) { [weak self] _ in
            do {
                try ChatBackground.removeImage()
            } catch {
                self?.notice(String(localized: "The picture could not be removed."), detail: error.localizedDescription)
            }
            self?.updateRows()
        })
        present(alert, animated: true)
    }

    /// Scales the picture down to at most 3000 pixels on its longest side and
    /// writes it as a JPEG: a photo's file is otherwise tens of megabytes, and
    /// nothing draws it larger than a screen.
    private nonisolated static func storedJPEG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 3000,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil,
        ) else { return nil }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary,
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private nonisolated static func store(_ jpeg: Data) throws {
        let folder = ChatBackground.imageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try jpeg.write(to: ChatBackground.imageURL, options: .atomic)
    }

    private func notice(_ title: String, detail: String? = nil) {
        let alert = UIAlertController(
            title: title,
            message: detail,
            preferredStyle: .alert,
        )
        alert.addAction(UIAlertAction(title: String(localized: "Done"), style: .default))
        present(alert, animated: true)
    }
}

extension ChatBackgroundController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider,
              provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        else { return }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] data, error in
            Task { @MainActor in
                guard let self else { return }
                guard let data else {
                    self.notice(
                        String(localized: "That picture could not be read."),
                        detail: error?.localizedDescription,
                    )
                    return
                }
                let jpeg = await Task.detached(priority: .userInitiated) {
                    Self.storedJPEG(data)
                }.value
                guard let jpeg else {
                    self.notice(String(localized: "That picture could not be read."))
                    return
                }
                do {
                    try Self.store(jpeg)
                    ChatBackground.current = .image
                    self.updateRows()
                } catch {
                    self.notice(
                        String(localized: "The picture could not be saved."),
                        detail: error.localizedDescription,
                    )
                }
            }
        }
    }
}
