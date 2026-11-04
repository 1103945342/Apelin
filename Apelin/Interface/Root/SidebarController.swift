import SnapKit
import Then
import UIKit

/// The sidebar, laid out as aimini's drawer is: three pages side by side —
/// Workspaces, Sessions, Files — above one group at the foot that opens
/// Settings.
///
/// It owns what all three read: the projects in `Projects/`, the one open,
/// and the conversations' runtime. A page is a child controller that reads
/// nothing else, so one can be rebuilt without the other two noticing.
final class SidebarController: UIViewController {
    /// The pages, in the order the tabs show them: the workspace first, then
    /// the conversations it holds, then its files.
    enum Page: Int, CaseIterable {
        case workspaces
        case sessions
        case files

        var title: String.LocalizationValue {
            switch self {
            case .workspaces: "Workspaces"
            case .sessions: "Sessions"
            case .files: "Files"
            }
        }
    }

    /// The conversation to show, as it is picked, made or deleted: nil when
    /// none is left picked. `picked` when the reader chose it, by its row or
    /// New Chat, which puts a drawer away; a conversation that follows a
    /// workspace switch, a deletion or the launch changes behind it.
    var onSelect: ((ChatSummary?, _ picked: Bool) -> Void)?
    var onProjectsLoaded: (() -> Void)?
    /// A message to send in the conversation just picked, as if typed.
    var onSendPrompt: ((String) -> Void)?
    private(set) var hasLoadedProjects = false

    var runtime: ChatRuntime! {
        didSet { sessions.runtime = runtime }
    }

    private let workspacesPage = SidebarWorkspacesController()
    private let sessions = SidebarSessionsController()
    private let filesPage = SidebarFilesController()

    /// The page on screen. Sessions first: the launch opens a conversation,
    /// and the reader is looking at it.
    private var page: Page = .sessions {
        didSet {
            guard page != oldValue else { return }
            applyPage()
        }
    }

    /// The projects in `Projects/`, once the host lists them; none until then.
    private var projects: [ProjectSummary] = []
    private let projectMonitor = ProjectCatalogMonitor()

    /// The open workspace. Nil is General Chat, the conversations no project
    /// holds — aimini has no such workspace, Apelin keeps them reachable.
    private var project: ProjectSummary? {
        didSet {
            UserDefaults.standard.set(project?.name, forKey: "chat.selectedProject")
            guard oldValue?.name != project?.name else {
                workspacesPage.update(projects: projects, current: project, chats: runtime?.summaries ?? [])
                filesPage.update(project: project)
                return
            }
            sessions.switchProject(to: project?.name)
            workspacesPage.update(projects: projects, current: project, chats: runtime?.summaries ?? [])
            filesPage.update(project: project)
        }
    }

    /// The picked conversation, kept here because the sessions page rebuilds
    /// its list and would otherwise forget what the reader left on.
    private var selectedID: UUID?

    private lazy var tabs: UISegmentedControl = {
        let control = UISegmentedControl(items: Page.allCases.map { String(localized: $0.title) })
        control.selectedSegmentIndex = Page.sessions.rawValue
        control.addAction(
            UIAction { [weak self, weak control] _ in
                guard let self, let control else { return }
                page = Page(rawValue: control.selectedSegmentIndex) ?? .sessions
            },
            for: .valueChanged
        )
        return control
    }()

    /// Where a page is put; the other two stay loaded behind it, keeping
    /// their scroll position and what is expanded.
    private let content = UIView()

    private lazy var settingsRow = SidebarFooterRow(
        symbol: "gearshape",
        title: String(localized: "Settings")
    ) { [weak self] in
        guard let self else { return }
        presentPageAsFormSheet(SettingsViewController())
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The sidebar is a material, not a panel: the page behind it stays
        // legible through the glass, as the system's own sidebars do.
        view.backgroundColor = .clear
        let glass = GlassSurfaceView()
        view.addSubview(glass)
        glass.snp.makeConstraints { x in x.edges.equalToSuperview() }

        addChild(workspacesPage)
        addChild(sessions)
        addChild(filesPage)
        for page in [workspacesPage as UIViewController, sessions, filesPage] {
            content.addSubview(page.view)
            page.view.snp.makeConstraints { x in x.edges.equalToSuperview() }
            page.didMove(toParent: self)
        }

        view.addSubview(tabs)
        view.addSubview(content)
        view.addSubview(settingsRow)

        tabs.snp.makeConstraints { x in
            x.top.equalTo(view.safeAreaLayoutGuide).offset(10)
            x.leading.trailing.equalTo(view).inset(16)
            x.height.equalTo(42)
        }
        settingsRow.snp.makeConstraints { x in
            x.leading.trailing.equalTo(view).inset(16)
            x.bottom.equalTo(view.safeAreaLayoutGuide).inset(10)
        }
        content.snp.makeConstraints { x in
            x.top.equalTo(tabs.snp.bottom).offset(12)
            x.leading.trailing.equalTo(view)
            x.bottom.equalTo(settingsRow.snp.top).offset(-10)
        }

        workspacesPage.onPick = { [weak self] summary in
            guard let self else { return }
            switchWorkspace(to: summary)
            // aimini goes back to the conversations once a workspace is
            // picked: the files and the list are about to change under the
            // reader, and the conversations are what they came for.
            page = .sessions
        }
        workspacesPage.onCreate = { [weak self] in self?.openNewProject() }
        workspacesPage.onRename = { [weak self] summary in
            guard let self else { return }
            ProjectActions.rename(summary.name, from: self)
        }
        workspacesPage.onDelete = { [weak self] summary in
            self?.confirmDeleteWorkspace(summary)
        }

        sessions.onSelect = { [weak self] summary, picked in
            guard let self else { return }
            selectedID = summary?.id
            onSelect?(summary, picked)
        }
        sessions.onSendPrompt = { [weak self] text in self?.onSendPrompt?(text) }

        filesPage.onPresent = { [weak self] page in
            guard let self else { return }
            presentPageAsFormSheet(page, openedAt: nil)
        }

        projectMonitor.start()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(projectsChanged),
            name: .apelinProjectsChanged,
            object: nil
        )
        applyPage()
        Task { await refreshProjects() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The pages carry their own headers; a bar above them would repeat
        // the workspace's name the workspaces page already shows.
        navigationController?.setNavigationBarHidden(true, animated: animated)
        // The navigation controller's own ground would be a second, opaque
        // layer over the glass at the edges.
        navigationController?.view.backgroundColor = .clear
    }

    /// Shows the page. A file list and a conversation list both go stale
    /// behind the reader's back, so the one arriving reads its source again.
    private func applyPage() {
        tabs.selectedSegmentIndex = page.rawValue
        let shown: UIViewController = switch page {
        case .workspaces: workspacesPage
        case .sessions: sessions
        case .files: filesPage
        }
        for child in [workspacesPage as UIViewController, sessions, filesPage] {
            child.view.isHidden = child !== shown
        }
        if page == .files { filesPage.reload() }
        if page == .workspaces {
            workspacesPage.update(projects: projects, current: project, chats: runtime?.summaries ?? [])
        }
    }

    // MARK: - What the root asks for

    /// Shows `summary`'s workspace with that conversation picked.
    func select(_ summary: ChatSummary) {
        if project?.name != summary.projectName {
            project = summary.projectName.map { name in
                projects.first { $0.name == name } ?? ProjectSummary(name: name, kind: .workspace)
            }
        }
        selectedID = summary.id
        sessions.select(summary)
        page = .sessions
    }

    func refresh() {
        sessions.refresh()
        workspacesPage.update(projects: projects, current: project, chats: runtime?.summaries ?? [])
        if page == .files { filesPage.reload() }
    }

    /// An empty conversation at the top of today, picked and shown: the
    /// workspace's untouched one if it has one, so empty rows never pile up.
    func startNewChat(picked: Bool = true) {
        let chat = runtime.newChat(project: project?.name, preferring: selectedID)
        selectedID = chat.id
        sessions.refresh()
        sessions.select(chat)
        page = .sessions
        onSelect?(chat, picked)
    }

    func delete(_ id: UUID, from origin: ChatDeletion.Origin, presenter: UIViewController? = nil) {
        sessions.delete(id, from: origin, presenter: presenter ?? self) { [weak self] in
            guard let self, selectedID == id else { return }
            selectedID = nil
            onSelect?(nil, false)
        }
    }

    /// Opens a workspace just made on a new conversation, which sends
    /// `firstPrompt` when there is one.
    func openCreatedProject(_ project: ProjectSummary, firstPrompt: String? = nil) {
        projects.removeAll { $0.name == project.name }
        projects.append(project)
        self.project = project
        startNewChat()
        if let firstPrompt { onSendPrompt?(firstPrompt) }
    }

    // MARK: - The workspaces

    private func switchWorkspace(to summary: ProjectSummary?) {
        guard summary?.name != project?.name else { return }
        project = summary
        // The workspace is opened on its most recent conversation, as the
        // menu that used to switch them did.
        let newest = SidebarOrder.newest(sessions.summaries)
        selectedID = newest?.id
        if let newest { sessions.select(newest) }
        onSelect?(newest, false)
    }

    @objc private func projectsChanged() {
        Task { await refreshProjects() }
    }

    private func refreshProjects() async {
        do {
            projects = try await ProjectSummary.load()
            // A project whose folder went takes its conversations, and the
            // sidebar leaves it for General Chat, as Delete in All Projects
            // does.
            let deleted = await runtime.forgetDeletedProjects()
            if let name = project?.name, deleted.contains(name) {
                switchWorkspace(to: nil)
            } else if let name = project?.name, let resolved = projects.first(where: { $0.name == name }),
                      resolved != project
            {
                project = resolved
            } else if let name = UserDefaults.standard.string(forKey: "chat.selectedProject"),
                      let saved = projects.first(where: { $0.name == name }), project == nil
            {
                project = saved
            }
            workspacesPage.update(projects: projects, current: project, chats: runtime?.summaries ?? [])
            filesPage.update(project: project)
            if !hasLoadedProjects {
                hasLoadedProjects = true
                onProjectsLoaded?()
            }
        } catch { presentNotice(title: "Projects Unavailable", message: error.readableMessage) }
    }

    private func openNewProject() {
        let page = NewProjectController()
        page.onCreate = { [weak self] project, firstPrompt in
            self?.openCreatedProject(project, firstPrompt: firstPrompt)
        }
        presentPageAsFormSheet(page)
    }

    private func confirmDeleteWorkspace(_ summary: ProjectSummary) {
        presentConfirmation(
            title: "Delete Workspace?",
            message: "“\(summary.displayTitle)” and every conversation in it will be deleted. This cannot be undone.",
            confirmTitle: "Delete",
            destructive: true
        ) { [weak self] in
            guard let self else { return }
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await runtime.deleteProject(summary.name)
                    projects.removeAll { $0.name == summary.name }
                    if project?.name == summary.name { switchWorkspace(to: nil) }
                    workspacesPage.update(projects: projects, current: project, chats: runtime?.summaries ?? [])
                    NotificationCenter.default.post(name: .apelinProjectsChanged, object: nil)
                } catch {
                    presentNotice(title: "Unable to Delete Workspace", message: error.readableMessage)
                }
            }
        }
    }
}
