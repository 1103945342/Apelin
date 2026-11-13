import Foundation

func require(_ condition: Bool, _ message: String, line: Int = #line) {
    guard condition else { fatalError("Line \(line): \(message)") }
}

// The order the box rolls in, wrapping back to the first.
var rotation = ComposerTipRotation(count: 5)
require(rotation.index == 0, "a rotation starts on the first tip")
for expected in [1, 2, 3, 4, 0, 1] {
    rotation.advance()
    require(rotation.index == expected, "advance gave \(rotation.index), wanted \(expected)")
}

// The tip about folding leads while something is open, and the roll carries
// on from it rather than starting over.
rotation.lead(ComposerTips.collapseHint)
require(rotation.index == ComposerTips.collapseHint, "lead lands on the folding tip")
rotation.advance()
require(rotation.index == ComposerTips.collapseHint + 1, "the roll continues after it")

// An index off the list lands on the nearest tip there is.
rotation.lead(-4)
require(rotation.index == 0, "a negative index clamps to the first tip")
rotation.lead(99)
require(rotation.index == 4, "an index past the end clamps to the last tip")

// A list with nothing in it stays put instead of dividing by zero, and one tip
// does not advance away from itself.
var empty = ComposerTipRotation(count: 0)
empty.advance()
empty.lead(2)
require(empty.index == 0, "an empty rotation holds at zero")
var single = ComposerTipRotation(count: 1)
single.advance()
require(single.index == 0, "a single tip stays on itself")

// The tip led with is one of the tips rolled, and the box rolls the five it
// was given.
let tips = ComposerTips.all
require(tips.count == 5, "the box rolls \(tips.count) tips, wanted 5")
require(ComposerTips.collapseHint >= 0 && ComposerTips.collapseHint < tips.count,
        "the folding tip is one of the tips")
require(tips.allSatisfy { !$0.isEmpty }, "a tip is empty")

print("ok: tip rotation wraps, leads with the folding tip, clamps off-list indexes and survives empty lists")
