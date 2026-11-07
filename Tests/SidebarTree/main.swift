import Foundation

try checkSidebarTree()

var parent = ChatSummary(title: "Original", lastInteraction: Date(), projectName: "Tree")
let first = ChatLineage.reserveBranchNumber(in: &parent, summaries: [])
precondition(first == 1)
let second = ChatLineage.reserveBranchNumber(in: &parent, summaries: [])
precondition(second == 2, "deleted branches do not release their numbers")
var child = ChatSummary(title: "Old fallback", lastInteraction: Date(), projectName: "Tree")
child.parentChatID = parent.id
child.relationship = .branch
child.branchNumber = 2
parent.rename(to: "Renamed")
precondition(ChatLineage.projected([parent, child]).last?.title == "Renamed")
precondition(ChatLineage.projected([child]).first?.title == "Old fallback")
print("ok: inherited titles and non-reused branch numbers")
