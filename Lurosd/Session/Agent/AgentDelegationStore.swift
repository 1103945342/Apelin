import ApelinCore
import ApelinProtocol
import Darwin
import Foundation

/// Host-private authority. No resolved project/bootstrap path is persisted.
/// Reads are deliberately uncached: corrupt or unreadable authority is never
/// replaced with an empty plan, and a failed write is never published in memory.
actor AgentDelegationStore {
    struct Record: Codable, Sendable {
        var version = 1
        var child: String
        var opener: String
        var projectID: String
        var plan: AgentDelegationPlan
    }
    let directory: URL
    private let write: @Sendable (Data, URL) throws -> Void

    init(directory: URL, write: @escaping @Sendable (Data, URL) throws -> Void = { data, url in
        try data.write(to: url, options: .atomic)
    }) {
        self.directory = directory
        self.write = write
    }

    func record(_ child: String) throws -> Record? {
        let file = try location(child)
        var info = stat()
        guard lstat(file.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw refusal("The saved brief cannot be read; no operation is authorised.")
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size <= 512 * 1024 else {
            throw refusal("The saved brief is not a bounded regular file; preserve it and stop.")
        }
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw refusal("The saved brief cannot be opened safely.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG,
              opened.st_size <= 512 * 1024 else {
            throw refusal("The opened brief is not a bounded regular file.")
        }
        let data = try handle.read(upToCount: 512 * 1024 + 1) ?? Data()
        guard data.count <= 512 * 1024 else { throw refusal("The saved brief exceeds its size limit.") }
        let saved: Record
        do { saved = try JSONDecoder().decode(Record.self, from: data) }
        catch { throw refusal("The saved brief is unreadable. Its bytes were preserved; repair it before continuing.") }
        guard saved.version == 1, saved.child == child,
              UUID(uuidString: saved.opener) != nil, !saved.projectID.isEmpty else {
            throw refusal("The saved brief identity is inconsistent; preserve it and stop.")
        }
        try saved.plan.validate()
        return saved
    }

    @discardableResult
    func register(child: String, opener: String, projectID: String,
                  brief: AgentDelegationBrief) throws -> AgentDelegationPlan {
        guard UUID(uuidString: opener) != nil, child != opener, !projectID.isEmpty else {
            throw refusal("Invalid delegation identity.")
        }
        guard try record(child) == nil else { throw refusal("This assignment already has a brief; revise it explicitly.") }
        let saved = Record(child: child, opener: opener, projectID: projectID,
                           plan: try AgentDelegationPlan(brief: brief))
        try persist(saved)
        return saved.plan
    }

    func apply(_ request: AgentDelegationRequest, caller: String) throws -> AgentDelegationResponse {
        guard var saved = try record(request.sessionID) else {
            if request.action == .read, request.sessionID == caller { return .init(plan: nil) }
            throw refusal("This conversation has no delegated brief.")
        }
        guard caller == saved.child || caller == saved.opener else {
            throw refusal("Only this assignment's child and authenticated opener may read its plan.", saved.plan)
        }
        if request.action == .read { return .init(plan: saved.plan) }
        guard let revision = request.expectedRevision else {
            throw refusal("Read the plan and supply expected_revision.", saved.plan)
        }
        switch request.action {
        case .read: break
        case .admit:
            guard caller == saved.child, let tool = request.tool else {
                throw refusal("Admission is for the calling child's own tool.", saved.plan)
            }
            try AgentDelegationToolPolicy.authorize(tool: tool, path: request.path,
                                                    plan: saved.plan, expectedRevision: revision)
            return .init(plan: saved.plan)
        case .blocked, .review, .check:
            guard caller == saved.child else {
                throw refusal("Only the child can report this step's status.", saved.plan)
            }
            switch request.action {
            case .blocked: saved.plan = try saved.plan.blocked(expectedRevision: revision)
            case .review: saved.plan = try saved.plan.requestReview(expectedRevision: revision)
            default:
                // No unconfined build or editable project script is passed off
                // as host evidence. Register an isolated adapter before enabling it.
                throw refusal("No isolated check adapter is installed for this step. It remains unverified; ask the opener to revise the brief, not to approve a command bypass.", saved.plan)
            }
        case .acceptAssignment, .cancelAssignment, .failAssignment, .seal:
            throw refusal("Assignment disposition belongs to the host's assignment ledger, not a step transition.", saved.plan)
        case .accept, .amend:
            guard caller == saved.opener else {
                throw refusal("A child cannot release or amend its own plan.", saved.plan)
            }
            if request.action == .accept {
                saved.plan = try saved.plan.accepted(expectedRevision: revision)
            } else {
                guard let step = request.step else { throw refusal("Supply the revised current step.", saved.plan) }
                saved.plan = try saved.plan.amendingCurrent(step, acceptance: request.acceptance,
                                                            expectedRevision: revision)
            }
        }
        try persist(saved)
        return .init(plan: saved.plan)
    }

    private func persist(_ record: Record) throws {
        try record.plan.validate()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try write(JSONEncoder().encode(record), location(record.child))
    }

    private func location(_ child: String) throws -> URL {
        guard UUID(uuidString: child) != nil else { throw refusal("A child must name a session UUID.") }
        return directory.appendingPathComponent(child + ".json")
    }

    private func refusal(_ rule: String, _ plan: AgentDelegationPlan? = nil) -> AgentDelegationViolation {
        .init(stepID: plan?.currentStep?.id ?? "brief", title: plan?.currentStep?.title ?? "Assignment", rule: rule)
    }
}

/// No symlink is an authority alias, even when it resolves inside the project.
/// This host check is repeated by the mobile file committer. It does not make
/// arbitrary processes safe; they remain unsupported by the admission policy.
enum AgentDelegationPath {
    static func validate(_ path: String, projectRoot: String) throws {
        guard AgentDelegationBrief.validRelativePath(path),
              !path.split(separator: "/").contains(".git"),
              let root = CanonicalPath.resolve(projectRoot) else {
            throw AgentDelegationViolation(stepID: "path", title: "Write boundary", rule: "Use a normalised project-relative file path outside git metadata.")
        }
        var current = root
        for component in path.split(separator: "/") {
            current += "/" + component
            var info = stat()
            if lstat(current, &info) == 0 {
                guard info.st_mode & S_IFMT != S_IFLNK,
                      let canonical = CanonicalPath.resolve(current), canonical == current,
                      CanonicalPath.isCanonical(canonical, inside: root) else {
                    throw AgentDelegationViolation(stepID: "path", title: "Write boundary", rule: "A write component is a link or moved outside the declared path.")
                }
            } else if errno != ENOENT {
                throw AgentDelegationViolation(stepID: "path", title: "Write boundary", rule: "A write component cannot be inspected.")
            }
        }
    }
}
