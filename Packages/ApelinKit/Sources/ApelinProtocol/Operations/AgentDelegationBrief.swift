import Foundation

/// The structured delegation contract. This value grants no operating-system
/// permissions: callers must canonicalise paths and enforce every mutation
/// before using the decision below. Unknown operations fail closed.
public struct AgentDelegationBrief: Codable, Sendable, Equatable, Hashable {
    public enum Gates: String, Codable, Sendable { case each, end }
    public enum Capability: String, Codable, Sendable, CaseIterable {
        case fileWrite, build, install, gitCommit, publish, delegate
    }
    public struct Step: Codable, Sendable, Equatable, Hashable {
        public var id: String
        public var title: String
        /// Exact files or directory roots, relative to the canonical project.
        public var writeRoots: [String]
        public var capabilities: [Capability]
        /// A registered host adapter ID, never a shell command.
        public var checkID: String?

        public init(id: String, title: String, writeRoots: [String] = [],
                    capabilities: [Capability] = [], checkID: String? = nil) {
            self.id = id
            self.title = title
            // "Notes/" is how a subtree is written in prose; it names the same
            // root as "Notes", so it is kept in the one form the rest reads.
            self.writeRoots = writeRoots.map(AgentDelegationBrief.normalisedPath)
            self.capabilities = capabilities
            self.checkID = checkID
        }
    }

    public var objective: String
    public var acceptance: [String]
    public var gates: Gates
    public var steps: [Step]

    public init(objective: String, acceptance: [String], gates: Gates = .each, steps: [Step]) {
        self.objective = objective
        self.acceptance = acceptance
        self.gates = gates
        self.steps = steps
    }

    public func validate() throws {
        guard Self.nonempty(objective), objective.utf8.count <= 4096,
              !acceptance.isEmpty, acceptance.count <= 32,
              acceptance.allSatisfy({ Self.nonempty($0) && $0.utf8.count <= 1024 }),
              !steps.isEmpty, steps.count <= 32 else {
            throw AgentDelegationViolation(stepID: "brief", title: "Brief", rule: "Supply a bounded objective, acceptance criteria and 1–32 steps.")
        }
        var ids = Set<String>()
        for step in steps {
            func reject(_ rule: String) -> AgentDelegationViolation {
                AgentDelegationViolation(stepID: step.id, title: step.title, rule: rule)
            }
            guard Self.identifier(step.id), ids.insert(step.id).inserted,
                  Self.nonempty(step.title), step.title.utf8.count <= 160 else {
                throw reject("Steps require unique identifiers and nonempty titles.")
            }
            guard step.writeRoots.count <= 64,
                  step.writeRoots.allSatisfy(Self.validRelativePath),
                  Set(step.writeRoots.map(Self.normalisedPath)).count == step.writeRoots.count else {
                throw reject("Write roots must be distinct normalised project-relative paths, not globs or links.")
            }
            guard Set(step.capabilities).count == step.capabilities.count else {
                throw reject("Duplicate capabilities are not allowed.")
            }
            if let check = step.checkID, !Self.identifier(check) {
                throw reject("A check names a registered adapter, not a command string.")
            }
        }
    }

    /// A path as a write root means it: one trailing slash names the same
    /// subtree (`Notes/` is `Notes`), and nothing else is rewritten.
    public static func normalisedPath(_ path: String) -> String {
        var value = path
        while value.count > 1, value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    /// Lexical validation only. The admission layer must first resolve symlinks
    /// and prove that the canonical target remains inside the project.
    public static func validRelativePath(_ path: String) -> Bool {
        let path = normalisedPath(path)
        guard !path.isEmpty, path.utf8.count <= 4096,
              !path.contains(where: { $0.isNewline || $0 == "\0" || $0 == "\\" || "*?[]".contains($0) }) else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func nonempty(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !value.contains("\0")
    }

    private static func identifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 80 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || $0 == 45 || $0 == 95 || $0 == 46
        }
    }
}

public struct AgentDelegationViolation: Error, LocalizedError, Sendable, Equatable {
    public var stepID: String
    public var title: String
    public var rule: String
    public init(stepID: String, title: String, rule: String) {
        self.stepID = stepID
        self.title = title
        self.rule = rule
    }
    public var errorDescription: String? {
        "Step \(stepID) \"\(title)\": \(rule) Report the blocker to the opener; approval cannot widen this step."
    }
}

/// Host-owned state transitions. The host authenticates the caller and commits
/// the returned value atomically before publishing it to a worker. A worker
/// decoding this struct is not authorised to install it as host state.
public struct AgentDelegationPlan: Codable, Sendable, Equatable, Hashable {
    public enum Status: String, Codable, Sendable {
        case pending, working, blocked, awaitingReview, verified, unverified
    }
    public private(set) var brief: AgentDelegationBrief
    public private(set) var revision: UInt64
    public private(set) var currentIndex: Int
    public private(set) var statuses: [Status]

    public init(brief: AgentDelegationBrief) throws {
        try brief.validate()
        self.brief = brief
        revision = 1
        currentIndex = 0
        statuses = brief.steps.indices.map { $0 == 0 ? .working : .pending }
    }

    public var currentStep: AgentDelegationBrief.Step? {
        brief.steps.indices.contains(currentIndex) ? brief.steps[currentIndex] : nil
    }

    /// Decoding is deliberately not validation: every entry point checks this
    /// before indexing persisted data or accepting a caller's revision.
    public func validate() throws {
        try brief.validate()
        guard revision > 0, statuses.count == brief.steps.count,
              (0...brief.steps.count).contains(currentIndex) else {
            throw refusal("The saved plan is inconsistent; preserve it and stop.")
        }
        for index in statuses.indices {
            if index < currentIndex {
                guard statuses[index] == .verified || statuses[index] == .unverified else {
                    throw refusal("A previous step has not been reviewed.")
                }
            } else if index > currentIndex {
                guard statuses[index] == .pending else { throw refusal("A later step cannot already be active.") }
            } else {
                guard statuses[index] != .pending else { throw refusal("The current step cannot be pending.") }
            }
        }
    }

    public func authorize(_ capability: AgentDelegationBrief.Capability,
                          canonicalRelativePath: String? = nil, expectedRevision: UInt64) throws {
        try requireRevision(expectedRevision)
        guard let step = currentStep, statuses[currentIndex] == .working else {
            throw refusal("No step is open for mutation; the pointer has not advanced.")
        }
        guard step.capabilities.contains(capability) else {
            throw refusal("This step does not allow \(capability.rawValue).")
        }
        if capability == .fileWrite {
            let target = AgentDelegationBrief.normalisedPath(canonicalRelativePath ?? "")
            guard let path = canonicalRelativePath, AgentDelegationBrief.validRelativePath(path),
                  step.writeRoots.contains(where: {
                      let root = AgentDelegationBrief.normalisedPath($0)
                      return target == root || target.hasPrefix(root + "/")
                  }) else {
                throw refusal("The canonical target is outside this step's write roots.")
            }
        }
    }

    public func blocked(expectedRevision: UInt64) throws -> Self {
        try requireWorking(expectedRevision)
        var next = self
        next.statuses[currentIndex] = .blocked
        try next.bumpRevision()
        return next
    }

    public func requestReview(expectedRevision: UInt64) throws -> Self {
        try requireWorking(expectedRevision)
        guard currentStep?.checkID == nil else {
            throw refusal("Only the registered host check can verify this step.")
        }
        var next = self
        next.statuses[currentIndex] = .awaitingReview
        try next.bumpRevision()
        return next
    }

    /// Called only with a host-observed receipt, never a child's exit-code claim.
    public func checked(adapterID: String, exitCode: Int, expectedRevision: UInt64) throws -> Self {
        try requireWorking(expectedRevision)
        guard currentStep?.checkID == adapterID else {
            throw refusal("The check receipt does not match the current step's adapter.")
        }
        guard exitCode == 0 else { return self }
        var next = self
        next.statuses[currentIndex] = .verified
        if brief.gates == .end { next.advance() }
        try next.bumpRevision()
        return next
    }

    /// Only the authenticated opener calls this. A step without a check stays
    /// unverified even when the opener accepts its deliverable.
    public func accepted(expectedRevision: UInt64) throws -> Self {
        try requireRevision(expectedRevision)
        guard let step = currentStep else { throw refusal("There is no next step to release.") }
        let status = statuses[currentIndex]
        guard status == .verified || (status == .awaitingReview && step.checkID == nil) else {
            throw refusal("The current step has no passing check or review request.")
        }
        var next = self
        if status != .verified { next.statuses[currentIndex] = .unverified }
        next.advance()
        try next.bumpRevision()
        return next
    }

    /// Minimal revision: completed prefix and current ID stay stable. A new
    /// objective/plan is a new assignment, not an amendment hiding old evidence.
    /// `acceptance` restates what the assignment is measured against, so a step
    /// that changes what "done" means can say so in the same move; the ledger
    /// re-baselines the member and its old receipts stop counting.
    public func amendingCurrent(_ step: AgentDelegationBrief.Step,
                                acceptance: [String]? = nil,
                                expectedRevision: UInt64) throws -> Self {
        try requireRevision(expectedRevision)
        guard let current = currentStep, current.id == step.id, revision < UInt64.max else {
            throw refusal("An amendment keeps the current step identity and must have a new revision.")
        }
        var next = self
        next.brief.steps[currentIndex] = step
        if let acceptance {
            next.brief.acceptance = acceptance
        }
        next.revision += 1
        next.statuses[currentIndex] = .working
        try next.validate()
        return next
    }

    private func requireRevision(_ expected: UInt64) throws {
        try validate()
        guard expected == revision else { throw refusal("Stale revision \(expected); current revision is \(revision).") }
    }

    private func requireWorking(_ expected: UInt64) throws {
        try requireRevision(expected)
        guard currentStep != nil, statuses[currentIndex] == .working else {
            throw refusal("The current step is not open for work.")
        }
    }

    private mutating func bumpRevision() throws {
        guard revision < UInt64.max else { throw refusal("The revision space is exhausted.") }
        revision += 1
    }

    private mutating func advance() {
        currentIndex += 1
        if currentIndex < statuses.count { statuses[currentIndex] = .working }
    }

    private func refusal(_ rule: String) -> AgentDelegationViolation {
        AgentDelegationViolation(stepID: currentStep?.id ?? "end", title: currentStep?.title ?? "Assignment", rule: rule)
    }
}
