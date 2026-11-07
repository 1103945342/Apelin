import Foundation

func checkSidebarTree() throws {
    func chat(_ title: String, parent: ChatSummary? = nil, kind: ChatRelationship? = nil, number: Int? = nil) -> ChatSummary {
        var value = ChatSummary(title: title, lastInteraction: Date(timeIntervalSince1970: 100), projectName: "Tree")
        value.parentChatID = parent?.id
        value.relationship = kind
        value.branchNumber = number
        return value
    }
    let root = chat("Root")
    let branch = chat("Root", parent: root, kind: .branch, number: 1)
    let second = chat("Root", parent: root, kind: .branch, number: 2)
    var worker = chat("Research", parent: branch, kind: .derived)
    worker.isWorking = true
    let grandchild = chat("Research", parent: worker, kind: .branch, number: 1)
    let helper = chat("Docs", parent: root, kind: .derived)
    let leaf = chat("Independent")
    let all = [root, branch, second, worker, grandchild, helper, leaf]
    let tree = SidebarTree(all)
    precondition(Set(tree.roots(query: "").map(\.id)) == [root.id, leaf.id], "children are not top-level duplicates")
    let collapsed = tree.rows(under: root.id, expanded: [], query: "")
    precondition(collapsed.count == 1 && collapsed[0].working, "hidden work is visible on the parent")
    let openRoot: Set<String> = [SidebarTree.Item.chat(root.id).storageKey]
    let categories = tree.rows(under: root.id, expanded: openRoot, query: "")
    precondition(categories.map(\.item) == [.chat(root.id), .group(root.id, .branch), .group(root.id, .derived)])
    precondition(tree.rows(under: leaf.id, expanded: [], query: "").first?.expandable == false, "leaves have no empty categories")
    let revealed = tree.revealing(grandchild.id, in: [])
    let deep = tree.rows(under: root.id, expanded: revealed, query: "")
    precondition(deep.contains { $0.item == .chat(grandchild.id) && $0.depth == 6 }, "recursive branch/derived hierarchy")
    precondition(!deep.contains { $0.item == .chat(helper.id) }, "revealing a path does not expand its sibling category")
    precondition(Set(deep.map(\.item)).count == deep.count, "each node appears once")
    let branches = deep.compactMap { row -> UUID? in
        guard let id = row.item.chatID, tree.parents[id] == root.id, tree.chats[id]?.relationship == .branch else { return nil }
        return id
    }
    precondition(branches == [branch.id, second.id], "branch numbers set sibling order")
    precondition(deep.first { $0.item == .chat(branch.id) }?.isLast == false)
    precondition(deep.first { $0.item == .chat(second.id) }?.isLast == true)
    precondition(deep.first { $0.item == .chat(worker.id) }?.guides.contains(true) == true, "nested rows carry continuing ancestor guides")

    let search = tree.rows(under: root.id, expanded: [], query: "research")
    precondition(search.contains { $0.item == .chat(worker.id) } && search.contains { $0.item == .chat(root.id) }, "search reveals matching descendants with ancestry")
    precondition(!search.contains { $0.item == .chat(helper.id) || $0.item == .chat(second.id) }, "unrelated siblings stay out of search")
    precondition(tree.roots(query: "missing").isEmpty)
    precondition(tree.rows(under: root.id, expanded: [], query: "").count == 1, "search expansion does not mutate stored state")

    var pinned = worker
    pinned.isPinned = true
    let pinTree = SidebarTree([root, branch, pinned])
    precondition(pinTree.roots(query: "").count == 1 && pinTree.roots(query: "")[0].isPinned, "pinning descendants promotes one root")
    let orphan = SidebarTree([branch, worker])
    precondition(orphan.roots(query: "").map(\.id) == [branch.id], "deleting a parent preserves its child subtree")
    var foreign = root
    foreign.projectName = "Elsewhere"
    precondition(SidebarTree([foreign, branch]).roots(query: "").count == 2, "cross-project parent links do not nest")
    var cycleRoot = root
    cycleRoot.parentChatID = worker.id
    cycleRoot.relationship = .derived
    let cycle = SidebarTree([cycleRoot, branch, worker, grandchild])
    precondition(cycle.roots(query: "").count == 3, "cycle nodes remain visible as roots")
    precondition(cycle.parents[grandchild.id] == worker.id, "valid descendants of a cycle are kept")
    var selfLink = leaf
    selfLink.parentChatID = leaf.id
    selfLink.relationship = .derived
    precondition(SidebarTree([selfLink]).roots(query: "").count == 1)

    // Optional fields from an old version, round-trip persistence of new ones.
    let encoded = try JSONEncoder().encode(branch)
    let decoded = try JSONDecoder().decode(ChatSummary.self, from: encoded)
    precondition(decoded == branch)
    var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    for key in ["parentChatID", "relationship", "branchNumber", "lastBranchNumber"] { legacy.removeValue(forKey: key) }
    let old = try JSONDecoder().decode(ChatSummary.self, from: JSONSerialization.data(withJSONObject: legacy))
    precondition(old.parentChatID == nil && old.relationship == nil && old.branchNumber == nil)
    print("ok: recursive conversation tree, categories, reveal/search, guides, pinning, orphans, cycles and persistence")
}
