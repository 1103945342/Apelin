import Foundation

/// Why the browser could not do something, kept as a value so that the page
/// can name the reason and a test can tell one refusal from another. A folder
/// that cannot be read is never shown as an empty one.
enum FileBrowserFailure: Error, Equatable {
    /// Nothing exists at the path.
    case missing
    /// The file system refused: mobile may not read or write there.
    case notPermitted
    /// The path names a file where a folder was needed.
    case notADirectory
    /// Something of that name is already there.
    case exists
    /// A name a file may not have: empty, a slash, a colon, `.`, `..`, or a
    /// NUL the C library would read as an earlier end.
    case invalidName
    /// A folder cannot be put inside itself.
    case insideItself
    /// The top of the file system: nothing above it, and no row removes it.
    case atRoot
    /// A symbolic link whose target does not resolve.
    case brokenLink
    /// One of Apelin's own records: reading is the point, and changing it
    /// belongs to the page that manages it.
    case record(FileBrowserProtectedRecord)
    /// Readable, and nothing more.
    case readOnly(FileBrowserReadOnly)
    /// The system's own sentence, for a refusal none of the above names.
    case failed(String)
}

extension FileBrowserFailure: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missing: String(localized: "There is nothing at this path.")
        case .notPermitted: String(localized: "Apelin does not have permission to open this.")
        case .notADirectory: String(localized: "This is a file, not a folder.")
        case .exists: String(localized: "Something with that name is already here.")
        case .invalidName: String(localized: "That name cannot be used here.")
        case .insideItself: String(localized: "A folder cannot be put inside itself.")
        case .atRoot: String(localized: "This is the top of the file system. It cannot be removed.")
        case .brokenLink: String(localized: "This link leads nowhere.")
        case let .record(record): record.sentence
        case let .readOnly(reason): reason.sentence
        case let .failed(message): message
        }
    }
}
