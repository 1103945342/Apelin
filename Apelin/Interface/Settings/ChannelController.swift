import ApelinCore
import ApelinProtocol
import CoreImage.CIFilterBuiltins
import UIKit

/// Settings ▸ Plugins ▸ WeChat: the ClawBot channel's sign-in, the code to
/// scan, where its conversations run, and the switch that turns it off.
///
/// The page reads the channel from the session host every second while it is
/// on screen — the sign-in is a code the host polls, not a flow this page
/// runs — and every change it makes is saved as it is made: there is nothing
/// to confirm, and a page that asked for a Save button would leave the
/// channel half-configured.
final class ChannelController: TableController {
    private enum Section: Hashable, CaseIterable {
        case weChat
        case conversations
    }

    private enum Row: Hashable {
        case status
        case scan
        case code
        case signIn
        case signOut
        case project
        case approvalMode
    }

    private struct RowContent: Equatable {
        let row: Row
        let detail: String?
        /// The code a `scan` row draws; a new code makes the row redraw.
        let qr: String?
    }

    private lazy var dataSource = TableDataSource<Section, Row, RowContent>(
        tableView: tableView,
        identifier: { $0.row }
    ) { [weak self] table, _, row in
        self?.cell(in: table, content: row)
    }

    private var state: ChannelState?
    private var poll: Task<Void, Never>?
    private lazy var qrView: UIImageView = {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isAccessibilityElement = true
        view.accessibilityLabel = String(localized: "WeChat sign-in code")
        return view
    }()
    private lazy var qrCell: UITableViewCell = {
        let cell = UITableViewCell(style: .default, reuseIdentifier: "qr")
        cell.selectionStyle = .none
        cell.contentView.addSubview(qrView)
        let margins = cell.contentView.layoutMarginsGuide
        // The code is drawn at a size that fits the page, whatever version
        // the code itself is: a phone scans 240 points across as well as it
        // scans a larger one, and a page that grew to 600 pushed the rows
        // it explains off the screen.
        let preferred = qrView.heightAnchor.constraint(equalToConstant: 240)
        preferred.priority = .defaultHigh
        NSLayoutConstraint.activate([
            qrView.centerXAnchor.constraint(equalTo: margins.centerXAnchor),
            qrView.topAnchor.constraint(equalTo: margins.topAnchor),
            qrView.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
            qrView.widthAnchor.constraint(equalTo: qrView.heightAnchor),
            qrView.heightAnchor.constraint(lessThanOrEqualToConstant: 240),
            qrView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            qrView.widthAnchor.constraint(lessThanOrEqualTo: margins.widthAnchor),
            preferred,
        ])
        return cell
    }()

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "WeChat")
        navigationItem.backButtonDisplayMode = .minimal
        dataSource.headerTitle = { section in
            section == .conversations ? String(localized: "Conversations") : nil
        }
        dataSource.footerTitle = { section in
            guard section == .conversations else { return nil }
            return String(localized: """
            A message from WeChat runs as a conversation in the project you choose, and what that turn writes is \
            answered in WeChat. An approval it needs reaches WeChat too; only a command as root is the exception, \
            and that one is approved here with your passcode.
            """)
        }
        refresh()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        dataSource.beginLoad()
        refresh()
        startPolling()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        poll?.cancel()
        poll = nil
    }

    // MARK: Reading the channel

    private func startPolling() {
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.load()
            }
        }
    }

    private func refresh() {
        Task { [weak self] in
            await self?.load()
        }
    }

    private func load() async {
        do {
            apply(try await ApelinService.app.channelStatus())
        } catch {
            // The background service is not there yet (or was restarted);
            // the next second tries again.
        }
    }

    private func apply(_ state: ChannelState) {
        // Nothing changed: the rows stay as they are, and a page left open
        // does not redraw itself every second.
        guard state != self.state else { return }
        self.state = state
        dataSource.update(Section.allCases.map { section in
            (section, rows(in: section).map { row in
                RowContent(row: row, detail: detail(of: row, state: state), qr: row == .scan ? state.qrContent : nil)
            })
        }, reconfigure: true)
    }

    private func rows(in section: Section) -> [Row] {
        switch section {
        case .weChat:
            guard let state else { return [.status] }
            var rows: [Row] = [.status]
            if state.qrContent != nil {
                rows.append(.scan)
            }
            if state.phase == .needsCode {
                rows.append(.code)
            }
            rows.append(state.phase == .signedIn || state.phase == .failed ? .signOut : .signIn)
            return rows
        case .conversations:
            guard state != nil else { return [] }
            return [.project, .approvalMode]
        }
    }

    private func detail(of row: Row, state: ChannelState) -> String? {
        switch row {
        case .status:
            if state.listening {
                return String(localized: "Listening for messages")
            }
            if let message = state.message {
                return message
            }
            switch state.phase {
            case .off: return String(localized: "Off")
            case .starting: return String(localized: "Starting…")
            case .waitingForScan, .scanned: return String(localized: "Waiting for a scan")
            case .needsCode: return String(localized: "Needs a number")
            case .signedIn: return String(localized: "Signed in")
            case .failed: return String(localized: "Sign-in failed")
            }
        case .scan:
            return state.account.map { String(localized: "Signed in as \($0)") }
        case .code, .signIn, .signOut:
            return nil
        case .project:
            return state.projectName ?? String(localized: "General Chat")
        case .approvalMode:
            return AgentPermissions.title(for: state.approvalMode)
        }
    }

    // MARK: Cells

    private func cell(in tableView: UITableView, content: RowContent) -> UITableViewCell {
        switch content.row {
        case .scan:
            qrView.image = content.qr.flatMap(Self.qrImage)
            return qrCell
        case .status, .code, .project, .approvalMode, .signIn, .signOut:
            let cell = tableView.dequeueReusableCell(withIdentifier: "row")
                ?? UITableViewCell(style: .value1, reuseIdentifier: "row")
            var configuration = UIListContentConfiguration.valueCell()
            configuration.text = title(of: content.row)
            configuration.secondaryText = content.detail
            if content.row == .signOut {
                configuration.textProperties.color = .systemRed
            }
            if content.row == .signIn || content.row == .signOut {
                configuration.textProperties.alignment = .center
            }
            cell.contentConfiguration = configuration
            cell.accessoryType = content.row == .signIn || content.row == .signOut ? .none : .disclosureIndicator
            cell.selectionStyle = .default
            return cell
        }
    }

    private func title(of row: Row) -> String {
        switch row {
        case .status: String(localized: "Status")
        case .scan: String(localized: "Scan this code with WeChat")
        case .code: String(localized: "Enter the number WeChat shows")
        case .signIn: String(localized: "Sign In")
        case .signOut: String(localized: "Sign Out")
        case .project: String(localized: "Project")
        case .approvalMode: String(localized: "Approval Mode")
        }
    }

    /// The code drawn as a QR code, sharp at any size: the filter's own
    /// output is a few pixels across.
    private static func qrImage(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // One size whatever the code's version: a longer code is denser, not
        // wider, so the page keeps the rows that explain it and a phone still
        // scans it from the screen.
        let side: CGFloat = 600
        let scale = side / max(output.extent.width, output.extent.height)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // The white margin a scanner needs around the code.
        let margin = side * 0.08
        let canvas = CGRect(x: 0, y: 0, width: side + margin * 2, height: side + margin * 2)
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: canvas)
        let placed = scaled.transformed(by: CGAffineTransform(
            translationX: margin - scaled.extent.origin.x,
            y: margin - scaled.extent.origin.y
        ))
        guard let cgImage = CIContext().createCGImage(placed.composited(over: white), from: canvas) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    // MARK: What a row does

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let content = dataSource.value(at: indexPath) else { return }
        switch content.row {
        case .scan:
            // Tapping the code shows it as large as the screen allows: a
            // second phone scanning a 240-point code off this one is easier
            // the bigger it is drawn.
            if let qr = content.qr, let image = Self.qrImage(qr) {
                present(UINavigationController(rootViewController: QRCodeController(image: image)), animated: true)
            }
        case .status:
            break
        case .code:
            askForNumber()
        case .signIn:
            run { try await ApelinService.app.channelSignIn() }
        case .signOut:
            run { try await ApelinService.app.channelSignOut() }
        case .project:
            chooseProject()
        case .approvalMode:
            chooseApprovalMode()
        }
    }

    /// Runs one change, then shows what the channel is now.
    private func run(_ change: @escaping @Sendable () async throws -> ChannelState) {
        Task { [weak self] in
            do {
                let state = try await change()
                self?.apply(state)
            } catch {
                self?.show(error)
            }
        }
    }

    private func askForNumber() {
        let alert = UIAlertController(
            title: String(localized: "Enter the number WeChat shows"),
            message: nil,
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.keyboardType = .numberPad
            field.accessibilityLabel = String(localized: "Number")
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Done"), style: .default) { [weak self, weak alert] _ in
            guard let code = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespaces), !code.isEmpty else {
                return
            }
            self?.run { try await ApelinService.app.channelVerifyCode(code) }
        })
        present(alert, animated: true)
    }

    private func chooseProject() {
        let sheet = UIAlertController(title: String(localized: "Project"), message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: String(localized: "General Chat"), style: .default) { [weak self] _ in
            self?.run { try await ApelinService.app.channelConfigure(clearsProject: true) }
        })
        for name in Self.projectNames() {
            sheet.addAction(UIAlertAction(title: name, style: .default) { [weak self] _ in
                self?.run { try await ApelinService.app.channelConfigure(projectName: name) }
            })
        }
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        present(sheet, animated: true)
    }

    private func chooseApprovalMode() {
        let sheet = UIAlertController(title: String(localized: "Approval Mode"), message: nil, preferredStyle: .actionSheet)
        for mode in [ApprovalMode.relaxed, .confirm, .full] {
            sheet.addAction(UIAlertAction(title: AgentPermissions.title(for: mode), style: .default) { [weak self] _ in
                self?.run { try await ApelinService.app.channelConfigure(approvalMode: mode) }
            })
        }
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        present(sheet, animated: true)
    }

    /// The projects on this device, by the folders `Projects/` holds: a
    /// name the host resolves the same way.
    private static func projectNames() -> [String] {
        let folder = DataFolder.app.projects
        let names = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        return names.compactMap { url in
            let directory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard directory else { return nil }
            let name = url.lastPathComponent
            return ProjectName.validate(name) == nil ? name : nil
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func show(_ error: any Error) {
        let alert = UIAlertController(
            title: String(localized: "Could Not Connect"),
            message: (error as? ApelinError)?.message ?? String(describing: error),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "Done"), style: .default))
        present(alert, animated: true)
    }
}

/// The sign-in code alone, as large as the screen allows and zoomable: what
/// a second phone photographs or scans when the page's own row is too small.
/// Nothing here signs anything in — the code is the host's, and this page
/// only draws it.
final class QRCodeController: UIViewController, UIScrollViewDelegate {
    private let image: UIImage
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()

    init(image: UIImage) {
        self.image = image
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "WeChat sign-in code")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "Done"),
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(image:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        view.addSubview(scrollView)
        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = String(localized: "WeChat sign-in code")
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)
        let visible = scrollView.frameLayoutGuide
        let content = scrollView.contentLayoutGuide
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: content.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            imageView.widthAnchor.constraint(equalTo: visible.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: visible.heightAnchor),
        ])
    }

    @objc dynamic func viewForZooming(in _: UIScrollView) -> UIView? {
        imageView
    }
}
