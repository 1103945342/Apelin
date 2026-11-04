import Foundation

/// One entry of a project's folder, as the files page lists it and the
/// editor opens it.
struct ProjectFile: Hashable, Sendable {
    /// Inside the project: `""` is the folder itself, `Sources/App.swift` a
    /// file two levels down. Never absolute, never with a `..` in it.
    var relativePath: String
    /// The last component, shown on the row.
    var name: String
    var isDirectory: Bool
    var modified: Date?
    var byteCount: Int64?

    /// How deep it sits, for indenting the row: 0 for what the folder holds,
    /// 1 for what that holds, and so on.
    var depth: Int {
        relativePath.isEmpty ? 0 : relativePath.filter { $0 == "/" }.count + 1
    }
}

/// A project's folder, read a directory at a time.
///
/// Reading on demand rather than walking the whole tree: a project can hold
/// a `node_modules` or a build folder with more entries than the page could
/// show, and expanding one folder should cost one directory listing, not a
/// walk of everything below it.
@MainActor
final class ProjectFiles {
    let root: URL
    /// What each directory listed last time, by its relative path.
    private var cache: [String: [ProjectFile]] = [:]
    /// The directories the reader opened.
    private var expanded: Set<String> = []

    init(root: URL) {
        self.root = root
    }

    /// The folder itself, for a title or an empty state.
    var name: String { root.lastPathComponent }

    /// Reads `directory` again, and puts back what it held.
    func reload(_ directory: String = "") {
        cache[directory] = nil
    }

    func reloadAll() {
        cache.removeAll()
    }

    func isExpanded(_ path: String) -> Bool {
        expanded.contains(path)
    }

    /// Opens or closes a folder, answering whether it is open now.
    @discardableResult
    func toggle(_ path: String) -> Bool {
        if expanded.contains(path) {
            expanded.remove(path)
            return false
        }
        expanded.insert(path)
        return true
    }

    /// Closes a folder and everything opened inside it, for a folder that
    /// was renamed or deleted and whose paths no longer exist.
    func collapse(_ path: String) {
        expanded = expanded.filter { $0 != path && !$0.hasPrefix(path + "/") }
        cache = cache.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
    }

    /// Every directory between the top and `path`, opened, so a path
    /// `reveal`ed is on screen.
    func open(ancestorsOf path: String) {
        var parts = path.split(separator: "/").map(String.init)
        parts.removeLast()
        var current = ""
        for part in parts {
            current = current.isEmpty ? part : current + "/" + part
            expanded.insert(current)
        }
    }

    /// The rows the page shows: what the folder holds, then what each open
    /// folder inside it holds, in reading order.
    func rows() -> [ProjectFile] {
        var rows: [ProjectFile] = []
        append(contentsOf: "", to: &rows)
        return rows
    }

    /// The rows for one directory and everything open below it. A directory
    /// that cannot be read is left empty rather than failing the whole page:
    /// one unreadable folder should not hide the others.
    private func append(contentsOf directory: String, to rows: inout [ProjectFile]) {
        for entry in contents(of: directory) {
            rows.append(entry)
            if entry.isDirectory, expanded.contains(entry.relativePath) {
                append(contentsOf: entry.relativePath, to: &rows)
            }
        }
    }

    func contents(of directory: String) -> [ProjectFile] {
        if let cached = cache[directory] { return cached }
        let url = root.appendingPathComponent(directory)
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
            cache[directory] = []
            return []
        }
        var entries: [ProjectFile] = []
        for name in names {
            // A name that would leave the folder is never one: it came from
            // the file system, and nothing here follows a path it did not
            // build itself.
            guard name != ".", name != "..", !name.contains("/") else { continue }
            let relative = directory.isEmpty ? name : directory + "/" + name
            let values = try? url.appendingPathComponent(name).resourceValues(forKeys: Set(keys))
            entries.append(ProjectFile(
                relativePath: relative,
                name: name,
                isDirectory: values?.isDirectory ?? false,
                modified: values?.contentModificationDate,
                byteCount: values?.fileSize.map(Int64.init),
            ))
        }
        // Folders first, then by name, as every file browser reads.
        let sorted = entries.sorted { left, right in
            if left.isDirectory != right.isDirectory { return left.isDirectory }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
        cache[directory] = sorted
        return sorted
    }

    /// Every file and folder under the project whose name has `query` in it,
    /// for the search field. Bounded like the composer's mention index: a
    /// reader typing wants the file they are thinking of, not a listing of
    /// everything.
    func search(_ query: String, limit: Int = 300) -> [ProjectFile] {
        guard !query.isEmpty else { return [] }
        var found: [ProjectFile] = []
        var pending: [String] = [""]
        while let directory = pending.popLast(), found.count < limit {
            for entry in contents(of: directory) {
                if entry.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                    found.append(entry)
                    if found.count >= limit { break }
                }
                if entry.isDirectory, entry.name != ".git" { pending.append(entry.relativePath) }
            }
        }
        return found
    }

    func url(of path: String) -> URL {
        path.isEmpty ? root : root.appendingPathComponent(path)
    }

    // MARK: - Changing the folder

    /// The name a file or folder the reader types may have: one component,
    /// nothing that would leave the folder or name nothing at all.
    enum NameProblem: Error {
        case empty
        case slash
        case reserved
        case exists
    }

    func check(name: String, in directory: String) -> NameProblem? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if trimmed.contains("/") || trimmed.contains(":") { return .slash }
        if trimmed == "." || trimmed == ".." { return .reserved }
        let relative = directory.isEmpty ? trimmed : directory + "/" + trimmed
        if FileManager.default.fileExists(atPath: url(of: relative).path) { return .exists }
        return nil
    }

    func createFile(named name: String, in directory: String) throws {
        let relative = directory.isEmpty ? name : directory + "/" + name
        try Data().write(to: url(of: relative), options: .withoutOverwriting)
        cache[directory] = nil
    }

    func createFolder(named name: String, in directory: String) throws {
        let relative = directory.isEmpty ? name : directory + "/" + name
        try FileManager.default.createDirectory(at: url(of: relative), withIntermediateDirectories: false)
        cache[directory] = nil
    }

    func rename(_ file: ProjectFile, to name: String) throws {
        let directory = file.relativePath.split(separator: "/").dropLast().joined(separator: "/")
        let destination = directory.isEmpty ? name : directory + "/" + name
        try FileManager.default.moveItem(at: url(of: file.relativePath), to: url(of: destination))
        collapse(file.relativePath)
        cache[directory] = nil
    }

    func delete(_ file: ProjectFile) throws {
        try FileManager.default.removeItem(at: url(of: file.relativePath))
        let directory = file.relativePath.split(separator: "/").dropLast().joined(separator: "/")
        collapse(file.relativePath)
        cache[directory] = nil
    }

    /// Copies or moves `file` into `directory`, keeping its name; a name
    /// that is already there becomes `name 2`, `name 3`, as Finder does.
    @discardableResult
    func transfer(_ file: ProjectFile, into directory: String, moving: Bool) throws -> String {
        let destination = uniqueName(for: file.name, in: directory)
        let target = directory.isEmpty ? destination : directory + "/" + destination
        if moving {
            try FileManager.default.moveItem(at: url(of: file.relativePath), to: url(of: target))
            let parent = file.relativePath.split(separator: "/").dropLast().joined(separator: "/")
            collapse(file.relativePath)
            cache[parent] = nil
        } else {
            try FileManager.default.copyItem(at: url(of: file.relativePath), to: url(of: target))
        }
        cache[directory] = nil
        return target
    }

    /// `name 2`, `name 3`… for a name the folder already holds.
    private func uniqueName(for name: String, in directory: String) -> String {
        let existing = Set(contents(of: directory).map(\.name))
        guard existing.contains(name) else { return name }
        let pathExtension = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        for index in 2... {
            let candidate = pathExtension.isEmpty
                ? "\(name) \(index)"
                : "\(stem) \(index).\(pathExtension)"
            if !existing.contains(candidate) { return candidate }
        }
        return name
    }
}

/// Reading and writing one of a project's text files.
enum ProjectFileContent {
    /// The most the editor opens: a file bigger than this is one to look at
    /// in the terminal, not to scroll in a sidebar sheet.
    static let maximumByteCount = 4 * 1024 * 1024

    enum ReadError: LocalizedError {
        case tooLarge
        case notText

        var errorDescription: String? {
            switch self {
            case .tooLarge: String(localized: "This file is too large to open here.")
            case .notText: String(localized: "This file is not text.")
            }
        }
    }

    static func read(at url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= Int64(maximumByteCount) else { throw ReadError.tooLarge }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        // A NUL byte is the file system's own way of saying binary; a text
        // file may be in any encoding, so ask the text system rather than
        // assuming UTF-8.
        guard !data.contains(0), let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
        else { throw ReadError.notText }
        return text
    }

    /// Writes it back where it was, and nowhere else: the file is the one
    /// the editor was opened on, and a save never creates a path.
    static func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
