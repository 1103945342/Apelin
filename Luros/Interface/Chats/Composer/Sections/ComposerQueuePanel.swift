import UIKit

/// One bounded, scrollable queue shared by every waiting message. The host
/// owns its contents; actions request a mutation and its next snapshot wins.
final class ComposerQueuePanel: ComposerPanel, UITableViewDataSource, UITableViewDelegate {
    private let table = UITableView(frame: .zero, style: .plain)
    private let resumeButton = UIButton(type: .system)
    private var messages: [ChatMessage] = []
    private var held: Set<UUID> = []
    @objc dynamic private var paused = false
    @objc dynamic private var canSteer = false
    @objc dynamic var onResume: (() -> Void)?
    var onSteer: ((ChatMessage) -> Void)?
    var onEdit: ((ChatMessage) -> Void)?
    var onRemove: ((ChatMessage) -> Void)?
    @objc dynamic var onReorder: (([UUID]) -> Void)?

    @objc dynamic private var queueRowHeight: CGFloat {
        max(44, UIFont.preferredFont(forTextStyle: .footnote).lineHeight + 16)
    }

    override dynamic func initializeViews() {
        super.initializeViews()
        table.backgroundColor = .clear
        table.separatorInset = .zero
        table.dataSource = self
        table.delegate = self
        table.allowsSelection = false
        table.setEditing(true, animated: false)
        table.register(QueueRow.self, forCellReuseIdentifier: "queue")
        body.addSubview(table)
        resumeButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        resumeButton.accessibilityLabel = String(localized: "Resume Queue")
        resumeButton.addAction(UIAction { [weak self] _ in self?.onResume?() }, for: .touchUpInside)
        addSubview(resumeButton)
        resumeButton.isHidden = true
        setCollapsible(true)
        collapseAction = { [weak self] in self?.setExpanded(false) }
        updateQueueTitle()
    }

    func show(_ queued: [ChatMessage], paused: Bool = false, held: Set<UUID> = [], canSteer: Bool = false) {
        guard queued != messages || paused != self.paused || held != self.held || canSteer != self.canSteer else { return }
        let wasEmpty = messages.isEmpty
        messages = queued
        self.paused = paused
        self.held = held
        self.canSteer = canSteer
        resumeButton.isHidden = !paused || queued.isEmpty
        table.reloadData()
        updateQueueTitle()
        if wasEmpty && !queued.isEmpty { setExpanded(true) }
        publishHeight()
        setNeedsLayout()
    }

    @objc dynamic private func updateQueueTitle() {
        let count = messages.count
        setTitle(count == 1 ? String(localized: "1 Message Waiting") : String(localized: "\(count) Messages Waiting"))
        header.accessibilityValue = paused ? String(localized: "Paused") : nil
    }

    override dynamic var foldedHeight: CGFloat {
        messages.isEmpty ? 0 : headerHeight + ComposerMetrics.Spacing.sm * 2
    }

    override dynamic var preferredHeight: CGFloat {
        guard !messages.isEmpty else { return 0 }
        return foldedHeight + min(CGFloat(messages.count) * queueRowHeight, ComposerMetrics.Panel.maxQueueHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        table.frame = body.bounds
        table.rowHeight = queueRowHeight
        if !resumeButton.isHidden {
            let inset = ComposerMetrics.Spacing.md
            let width = max(0, bounds.width - inset * 2 - 44)
            header.frame = directionalFrame(CGRect(x: inset, y: header.frame.minY, width: width, height: headerHeight))
            titleLabel.frame.size.width = max(0, titleLabel.frame.width - 44)
            chevron.frame = header.directionalFrame(CGRect(x: width - chevron.bounds.width, y: chevron.frame.minY,
                                                         width: chevron.bounds.width, height: chevron.bounds.height))
            resumeButton.frame = directionalFrame(CGRect(x: bounds.width - inset - 44, y: 0, width: 44, height: foldedHeight))
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { messages.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = tableView.dequeueReusableCell(withIdentifier: "queue", for: indexPath) as! QueueRow
        let message = messages[indexPath.row]
        row.show(message, number: indexPath.row + 1)
        row.setQueueActionsEnabled(canSteer: canSteer && !held.contains(message.id), canEdit: true)
        row.onSteer = { [weak self] in self?.onSteer?(message) }
        row.onEdit = { [weak self] in self?.onEdit?(message) }
        row.onRemove = { [weak self] in self?.onRemove?(message) }
        row.showsReorderControl = true
        return row
    }

    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool { messages.count > 1 }
    func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle { .none }
    func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool { false }
    func tableView(_ tableView: UITableView, moveRowAt source: IndexPath, to destination: IndexPath) {
        let message = messages.remove(at: source.row)
        messages.insert(message, at: destination.row)
        onReorder?(messages.map(\.id))
        // Let UIKit finish its interactive move before rebuilding the numbers.
        DispatchQueue.main.async { [weak self] in self?.table.reloadData() }
    }
}

private final class QueueRow: UITableViewCell {
    private let preview = UILabel()
    private let steerButton = UIButton(type: .system)
    private let editButton = UIButton(type: .system)
    private let removeButton = UIButton(type: .system)
    @objc dynamic var onSteer: (() -> Void)?
    @objc dynamic var onEdit: (() -> Void)?
    @objc dynamic var onRemove: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        preview.font = .preferredFont(forTextStyle: .footnote)
        preview.adjustsFontForContentSizeCategory = true
        preview.textColor = .secondaryLabel
        preview.numberOfLines = 1
        preview.lineBreakMode = .byTruncatingTail
        contentView.addSubview(preview)
        configure(steerButton, symbol: "arrow.up.to.line", label: String(localized: "Send Now")) { [weak self] in self?.onSteer?() }
        configure(editButton, symbol: "pencil", label: String(localized: "Edit Message")) { [weak self] in self?.onEdit?() }
        configure(removeButton, symbol: "trash", label: String(localized: "Delete")) { [weak self] in self?.onRemove?() }
        removeButton.tintColor = .systemRed
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(style:reuseIdentifier:)") }

    @objc dynamic private func configure(_ button: UIButton, symbol: String, label: String, action: @escaping () -> Void) {
        button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14)), for: .normal)
        button.accessibilityLabel = label
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        contentView.addSubview(button)
    }

    @objc dynamic func setQueueActionsEnabled(canSteer: Bool, canEdit: Bool) {
        steerButton.isEnabled = canSteer
        editButton.isEnabled = canEdit
    }

    func show(_ message: ChatMessage, number: Int) {
        let files = message.attachments.map(\.name).joined(separator: ", ")
        let mode = message.queueDelivery == "steer" ? String(localized: "Send Now") : ""
        let text = [message.sender ?? "", mode, message.text, files.isEmpty ? "" : "📎 " + files].filter { !$0.isEmpty }.joined(separator: " · ")
        preview.text = "\(number). \(text)"
        preview.accessibilityLabel = String(localized: "Waiting message \(number): \(text)")
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = contentView.bounds.width
        let buttonWidth: CGFloat = 44
        let actionWidth = buttonWidth * 3
        preview.frame = contentView.directionalFrame(CGRect(x: 0, y: 0, width: max(0, width - actionWidth), height: contentView.bounds.height))
        for (index, button) in [steerButton, editButton, removeButton].enumerated() {
            button.frame = contentView.directionalFrame(CGRect(x: max(0, width - actionWidth) + CGFloat(index) * buttonWidth, y: 0, width: buttonWidth, height: contentView.bounds.height))
        }
    }
}
