import Foundation

/// What the composer is doing about a file reference: the reader typed `@`,
/// and the list behind it is being filled, is ready, or cannot be.
enum ComposerMentionState: Equatable {
    case idle
    case loading
    case ready(files: [String])
    case unavailable
    case failed(message: String)
}

/// The text typed after an `@`, when the caret is inside one that is still
/// being written.
///
/// Only the tail of the draft is read: a mention is the word the caret is in,
/// and a reference the reader finished — `@src/main.swift`, followed by a space —
/// is part of the sentence, not a query.
///
/// - Returns: the query, empty for a bare `@`; nil when no mention is open.
func composerMentionQuery(in text: String) -> String? {
    let trailing = String(text.reversed())
    var consumed = 0
    for character in trailing {
        if character.isNewline || character.isWhitespace {
            return nil
        }
        if character == "@" {
            break
        }
        consumed += 1
    }
    let index = text.index(text.endIndex, offsetBy: -consumed)
    guard index > text.startIndex else { return nil }
    let before = text.index(before: index)
    guard text[before] == "@" else { return nil }
    // A mention starts a word: `name@host` is an address, not a reference.
    if before > text.startIndex {
        let preceding = text.index(before: before)
        let character = text[preceding]
        if !character.isWhitespace, !character.isNewline, character != "(" {
            return nil
        }
    }
    return String(text[index...])
}

/// What is typed after a leading slash, when the draft is a command still
/// being named: `/`, `/com`, and nothing once it holds a space.
///
/// - Returns: the query, empty for a bare slash; nil when the draft is not a
///   command being named.
func composerCommandQuery(in text: String) -> String? {
    guard text.hasPrefix("/") else { return nil }
    let body = text.dropFirst()
    guard !body.contains("\n"), !body.contains(" ") else { return nil }
    return String(body)
}

/// Replaces the mention the caret is in with a finished reference, and answers
/// the text as it now stands. The trailing space closes the mention, so the
/// menu does not reopen on it.
func composerApplyingMention(_ path: String, to text: String) -> String {
    guard let at = text.lastIndex(of: "@") else { return text }
    return String(text[text.startIndex ..< at]) + "@" + path + " "
}

/// The files whose path contains `query`, closest to the top of the project
/// first, in a list short enough to read.
///
/// Matching by substring rather than prefix: a reader typing `@Panel` means
/// `Interface/ChatPanel.swift` as readily as `Panel/`, and a prefix rule would
/// hide the first.
func composerMatchingFiles(_ files: [String], query: String, limit: Int = 20) -> [String] {
    guard !query.isEmpty else { return Array(files.prefix(limit)) }
    let lowered = query.lowercased()
    var matches: [String] = []
    for path in files {
        guard path.lowercased().contains(lowered) else { continue }
        matches.append(path)
        if matches.count >= limit { break }
    }
    return matches
}
