import Foundation

/// The two texts of one file, line by line, in the order an LCS walk gives
/// them.
///
/// This is deliberately not a patch. The diff page shows every line of both
/// versions, unchanged ones included, with a number in each of two gutters;
/// a patch carries three lines of context and one number, which is a
/// different page.
struct LineDiff {
    enum Kind: Equatable {
        case same
        case added
        case removed
    }

    struct Row: Equatable {
        let kind: Kind
        /// The 1-based line in the old text, or nil for a line it lacks.
        let oldNumber: Int?
        /// The 1-based line in the new text, or nil for a line it lacks.
        let newNumber: Int?
        let text: String
    }

    /// Above this many lines on either side the table is too big to be worth
    /// building. The page refuses a file over 2000 lines long before it gets
    /// here, so a direct caller is the only one this guards.
    static let maximumLines = 4000

    /// The lines of `text`, without the newline that ends each one.
    ///
    /// A file that ends with a newline has no extra empty line after it. A
    /// carriage return before the newline belongs to the line ending, not to
    /// the text, so a CRLF file compares equal to its LF twin.
    static func lines(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") {
            lines.removeLast()
        }
        return lines.map { line in
            line.hasSuffix("\r") ? String(line.dropLast()) : line
        }
    }

    static func rows(old: String, new: String) -> [Row] {
        let oldLines = lines(in: old)
        let newLines = lines(in: new)
        guard oldLines.count <= maximumLines, newLines.count <= maximumLines else {
            return replacingEverything(oldLines: oldLines, newLines: newLines)
        }

        // A suffix-length table, bottom-up, so the walk below can ask which
        // side loses fewer matches at every step. UInt16 is enough for the
        // 4000-line bound and halves the memory a second Int table would take.
        let columns = newLines.count + 1
        var lengths = [UInt16](repeating: 0, count: (oldLines.count + 1) * columns)
        if !oldLines.isEmpty, !newLines.isEmpty {
            for i in stride(from: oldLines.count - 1, through: 0, by: -1) {
                for j in stride(from: newLines.count - 1, through: 0, by: -1) {
                    let here = i * columns + j
                    if oldLines[i] == newLines[j] {
                        lengths[here] = lengths[(i + 1) * columns + j + 1] + 1
                    } else {
                        lengths[here] = max(lengths[(i + 1) * columns + j], lengths[here + 1])
                    }
                }
            }
        }

        var rows: [Row] = []
        rows.reserveCapacity(oldLines.count + newLines.count)
        var i = 0
        var j = 0
        while i < oldLines.count, j < newLines.count {
            if oldLines[i] == newLines[j] {
                rows.append(Row(kind: .same, oldNumber: i + 1, newNumber: j + 1, text: oldLines[i]))
                i += 1
                j += 1
            } else if lengths[(i + 1) * columns + j] >= lengths[i * columns + j + 1] {
                // Dropping the old line keeps at least as much of the match,
                // so removals come before the insertions that replace them.
                rows.append(Row(kind: .removed, oldNumber: i + 1, newNumber: nil, text: oldLines[i]))
                i += 1
            } else {
                rows.append(Row(kind: .added, oldNumber: nil, newNumber: j + 1, text: newLines[j]))
                j += 1
            }
        }
        while i < oldLines.count {
            rows.append(Row(kind: .removed, oldNumber: i + 1, newNumber: nil, text: oldLines[i]))
            i += 1
        }
        while j < newLines.count {
            rows.append(Row(kind: .added, oldNumber: nil, newNumber: j + 1, text: newLines[j]))
            j += 1
        }
        return rows
    }

    /// What a text too large to compare shows: every old line removed, then
    /// every new one added. It is not a diff of the file, but it is bounded
    /// work and the page refuses such a file before drawing it.
    private static func replacingEverything(oldLines: [String], newLines: [String]) -> [Row] {
        var rows = oldLines.enumerated().map { index, line in
            Row(kind: .removed, oldNumber: index + 1, newNumber: nil, text: line)
        }
        rows.append(contentsOf: newLines.enumerated().map { index, line in
            Row(kind: .added, oldNumber: nil, newNumber: index + 1, text: line)
        })
        return rows
    }
}
