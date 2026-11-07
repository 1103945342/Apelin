import Foundation

/// A projection only: a missing parent, a cross-project link or a cycle must
/// never hide a saved conversation. No node is duplicated in pinned or search.
struct SidebarTree {
    enum Item: Hashable {
        case chat(UUID)
        case group(UUID, ChatRelationship)

        var chatID: UUID? {
            if case let .chat(id) = self { return id }
            return nil
        }

        var storageKey: String {
            switch self {
            case let .chat(id): return "chat:\(id.uuidString)"
            case let .group(id, kind): return "\(kind.rawValue):\(id.uuidString)"
            }
        }
    }

    struct Row: Equatable {
        var item: Item
        /// Each ancestor's vertical guide continues when it has a next sibling.
        var guides: [Bool]
        var isLast: Bool
        var expandable: Bool
        var expanded: Bool
        var working: Bool
        var unread: Bool
        /// All visible rows of one root share a step so deep guides align.
        var layoutDepth: Int = 0
        var depth: Int { guides.count }
    }

    private(set) var chats: [UUID: ChatSummary]
    private(set) var parents: [UUID: UUID] = [:]
    private var children: [UUID: [UUID]] = [:]

    init(_ summaries: [ChatSummary]) {
        chats = Dictionary(summaries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for chat in summaries {
            guard chat.relationship != nil, let parent = chat.parentChatID,
                  parent != chat.id, let owner = chats[parent],
                  owner.projectName == chat.projectName
            else { continue }
            parents[chat.id] = parent
        }
        // Remove the edges of cycles, but keep their legitimate descendants.
        var checked: Set<UUID> = []
        for id in chats.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            var path: [UUID] = []
            var positions: [UUID: Int] = [:]
            var cursor: UUID? = id
            while let node = cursor, !checked.contains(node) {
                if let start = positions[node] {
                    for member in path[start...] { parents.removeValue(forKey: member) }
                    break
                }
                positions[node] = path.count
                path.append(node)
                cursor = parents[node]
            }
            checked.formUnion(path)
        }
        for (child, parent) in parents { children[parent, default: []].append(child) }
    }

    func ancestors(of id: UUID) -> [UUID] {
        var result: [UUID] = []
        var cursor = parents[id]
        while let parent = cursor {
            result.append(parent)
            cursor = parents[parent]
        }
        return result
    }

    /// Opening a deep link reveals just its ancestry, never another branch.
    func revealing(_ id: UUID, in expanded: Set<String>) -> Set<String> {
        var result = expanded
        var child = id
        while let parent = parents[child], let kind = chats[child]?.relationship {
            result.insert(Item.chat(parent).storageKey)
            result.insert(Item.group(parent, kind).storageKey)
            child = parent
        }
        return result
    }

    private func matching(_ query: String) -> Set<UUID> {
        guard !query.isEmpty else { return Set(chats.keys) }
        var included: Set<UUID> = []
        for chat in chats.values where chat.displayTitle.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
            included.insert(chat.id)
            included.formUnion(ancestors(of: chat.id))
        }
        return included
    }

    /// Pinning a descendant promotes its root, not a second copy of the child.
    func roots(query: String) -> [ChatSummary] {
        let included = matching(query)
        let pinnedRoots = Set(chats.values.filter(\.isPinned).map { ancestors(of: $0.id).last ?? $0.id })
        return chats.values.filter { parents[$0.id] == nil && included.contains($0.id) }.map {
            var root = $0
            root.isPinned = pinnedRoots.contains(root.id)
            return root
        }
    }

    func rows(under root: UUID, expanded: Set<String>, query: String) -> [Row] {
        let included = matching(query)
        guard included.contains(root) else { return [] }
        func childIDs(_ parent: UUID, _ kind: ChatRelationship) -> [UUID] {
            let candidates = (children[parent] ?? []).compactMap { chats[$0] }.filter {
                $0.relationship == kind && included.contains($0.id)
            }
            if kind == .branch {
                return candidates.sorted {
                    if $0.branchNumber != $1.branchNumber { return ($0.branchNumber ?? .max) < ($1.branchNumber ?? .max) }
                    return $0.id.uuidString < $1.id.uuidString
                }.map(\.id)
            }
            return SidebarOrder.newestFirst(candidates).sorted { lhs, rhs in
                lhs.isPinned && !rhs.isPinned
            }.map(\.id)
        }
        func descendants(_ ids: [UUID]) -> [ChatSummary] {
            var pending = ids
            var result: [ChatSummary] = []
            while let id = pending.popLast() {
                if let chat = chats[id] { result.append(chat) }
                pending += children[id] ?? []
            }
            return result
        }
        var rows: [Row] = []
        var pending: [(Item, [Bool], Bool)] = [(.chat(root), [], true)]
        while let (item, guides, isLast) = pending.popLast() {
            let next: [Item]
            let members: [ChatSummary]
            switch item {
            case let .chat(id):
                next = [ChatRelationship.branch, .derived].filter { !childIDs(id, $0).isEmpty }.map { .group(id, $0) }
                members = descendants([id])
            case let .group(id, kind):
                let ids = childIDs(id, kind)
                next = ids.map { .chat($0) }
                members = descendants(ids)
            }
            let isExpanded = !next.isEmpty && (!query.isEmpty || expanded.contains(item.storageKey))
            rows.append(Row(item: item, guides: guides, isLast: isLast, expandable: !next.isEmpty,
                            expanded: isExpanded, working: members.contains(where: \.isWorking),
                            unread: members.contains(where: \.showsUnread)))
            if isExpanded {
                for (index, child) in next.enumerated().reversed() {
                    pending.append((child, guides + [guides.isEmpty ? false : !isLast], index == next.count - 1))
                }
            }
        }
        let maximumDepth = rows.map(\.depth).max() ?? 0
        for index in rows.indices { rows[index].layoutDepth = maximumDepth }
        return rows
    }
}
