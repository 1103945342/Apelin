import enum ApelinProtocol.GitBranchName
import Foundation

/// A name is not a shell command. Validate it before asking the reader;
/// the environment worker validates it again before touching libgit2.
enum GitBranchTools {
    static func checkName(_ name: String) throws {
        if let problem = GitBranchName.problem(name) {
            throw ToolArgumentError(problem)
        }
    }

    static func checkRevision(_ revision: String) throws {
        guard !revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !revision.hasPrefix("-"),
              !revision.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw ToolArgumentError("Name a branch, tag or commit, without control characters or a leading dash.")
        }
    }
}
