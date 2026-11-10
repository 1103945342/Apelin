import Foundation

/// How a model's name finds its way into a catalog.
///
/// A relay serves models under names of its own — `cn:deepseek-v4.1-flash`,
/// `free: deepseek-v4.1-flash`, `anthropic/claude-sonnet-4` — while the
/// catalogs Apelin reads spell the same model `deepseek-v4.1-flash`. The name
/// is never rewritten before it is looked up: the catalog entry matches when it
/// is the name, or a whole stretch of it that begins and ends where the name
/// breaks (`:`, `/`, `-`, `.`, `@`, `_`, a space). A stretch from the middle of
/// a word never matches, so `v4.1` alone is not a model and a name is never
/// read as a model buried inside it.
public enum ModelIdentity {
    /// The shortest stretch worth matching. `gpt-4` is five characters and
    /// could be a piece of a longer word; every real model name is longer.
    static let minimumLength = 6

    /// Where a name breaks: a catalog entry may begin or end at any of these.
    static let breaks: Set<Character> = [":", "/", "-", ".", "@", "_", " ", ","]

    /// The names to try for `id`, whole first, then each shorter form with a
    /// prefix taken off (`cn:`, `free: `, `anthropic/`).
    public static func candidates(_ id: String) -> [String] {
        var candidates: [String] = []
        func add(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= minimumLength, !candidates.contains(trimmed) else { return }
            candidates.append(trimmed)
        }
        var text = id.trimmingCharacters(in: .whitespacesAndNewlines)
        add(text)
        while let cut = text.firstIndex(where: { breaks.contains($0) }) {
            let rest = String(text[text.index(after: cut)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rest.isEmpty, rest != text else { break }
            add(rest)
            text = rest
        }
        return candidates
    }

    /// Every stretch of `candidate` a catalog entry may be, longest first: its
    /// whole self, then each part that begins and ends where the name breaks.
    public static func stretches(_ candidate: String) -> [String] {
        let characters = Array(candidate.lowercased())
        guard characters.count >= minimumLength else { return [] }
        var starts = [0]
        var ends = [characters.count]
        for (index, character) in characters.enumerated() where breaks.contains(character) {
            if index + 1 < characters.count { starts.append(index + 1) }
            if index > 0 { ends.append(index) }
        }
        var stretches: [(offset: Int, text: String)] = []
        for start in starts {
            for end in ends where end - start >= minimumLength {
                stretches.append((start, String(characters[start ..< end])))
            }
        }
        // Longest first, and the earlier start of two equal-length stretches
        // first, so the same candidate always answers the same entry.
        stretches.sort { left, right in
            left.text.count == right.text.count
                ? left.offset < right.offset
                : left.text.count > right.text.count
        }
        var seen: Set<String> = []
        return stretches.compactMap { seen.insert($0.text).inserted ? $0.text : nil }
    }
}
