import ApelinProtocol
import Foundation

/// The untracked group: what stands on its own, what is listed under the
/// folder it first hangs in, how many files the group counts, and how much of
/// a nested file's folder is left to show under its name.
func checkUntrackedGroup() {
    func entry(_ path: String) -> GitStatusEntry {
        GitStatusEntry(path: path, index: "?", worktree: "?")
    }
    let entries = [
        entry("Sources/Sub/C.m"), entry("README.md"), entry("Docs/"), entry("Sources/B.m"),
        entry("Docs/x.md"), entry("Sources/A.m"),
    ]
    let (files, folders) = GitUntrackedGroup.split(entries)
    precondition(files.map(\.path) == ["README.md"], "a file at the top stands on its own: \(files.map(\.path))")
    precondition(folders.map(\.path) == ["Docs/", "Sources/"], "folders in path order: \(folders.map(\.path))")
    precondition(folders[0].children.map(\.path) == ["Docs/x.md"], "a folder's own entry is not its child")
    precondition(folders[1].children.map(\.path) == ["Sources/A.m", "Sources/B.m", "Sources/Sub/C.m"],
                 "children in path order, however deep: \(folders[1].children.map(\.path))")
    precondition(GitUntrackedGroup.fileCount(entries) == 5, "counts the files, not the folders")

    let lone = GitUntrackedGroup.split([entry("Empty/")])
    precondition(lone.files.isEmpty && lone.folders.map(\.path) == ["Empty/"])
    precondition(lone.folders[0].children.isEmpty, "a folder with nothing to open holds nothing")
    precondition(GitUntrackedGroup.fileCount([entry("Empty/")]) == 1, "and counts once, all Git said of it")
    precondition(GitUntrackedGroup.split([]).folders.isEmpty, "an empty group has no folders")

    precondition(GitUntrackedGroup.shownFolder(of: "Sources/Sub/C.m", under: "Sources/") == "Sub")
    precondition(GitUntrackedGroup.shownFolder(of: "Sources/A.m", under: "Sources/") == "",
                 "a file directly in its folder shows no folder under its name")
    precondition(GitUntrackedGroup.shownFolder(of: "Sources/A.m", under: "Sources") == "")
    precondition(GitUntrackedGroup.shownFolder(of: "Sources/A.m", under: nil) == "Sources")
    precondition(GitUntrackedGroup.shownFolder(of: "Other/x.m", under: "Sources/") == "Other",
                 "a file outside the folder keeps its own path")
    print("ok: untracked files stand apart or under their folder, and the count is files")
}
