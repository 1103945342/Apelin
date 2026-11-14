import Foundation

/// A reply cut for WeChat: one bubble per piece, at a blank line or a line
/// end when one is near the cut, never inside a character.
///
/// It lives here rather than in the host because it is the far side's rule —
/// how much a message may hold — and because a chunking bug is the kind of
/// thing a test should see without a device.
public enum IlinkText {
    /// Longer than any text WeChat shows in one bubble. The API takes long
    /// text too; splitting keeps a long answer readable on a phone.
    public static let maximumChunkLength = 1200

    public static func chunks(of text: String, limit: Int = IlinkText.maximumChunkLength) -> [String] {
        guard limit > 0 else { return text.isEmpty ? [] : [text] }
        guard text.count > limit else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }
        var pieces: [String] = []
        var rest = Substring(text)
        while rest.count > limit {
            let window = rest.prefix(limit)
            var cut = window.endIndex
            if let paragraph = window.range(of: "\n\n", options: .backwards), paragraph.lowerBound > rest.startIndex {
                cut = paragraph.upperBound
            } else if let line = window.lastIndex(of: "\n"), line > rest.startIndex {
                cut = rest.index(after: line)
            }
            let piece = rest[rest.startIndex ..< cut].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty {
                pieces.append(piece)
            }
            rest = rest[cut...]
        }
        let tail = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            pieces.append(tail)
        }
        return pieces
    }
}
