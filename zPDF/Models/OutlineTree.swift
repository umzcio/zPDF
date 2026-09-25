import Foundation

/// Pure tree edits on bookmark models, addressed by the models' UUIDs.
/// Kept free of UI so reorder/nest/delete logic is unit-testable.
enum OutlineTree {
    static func find(_ id: UUID, in items: [OutlineItemModel]) -> OutlineItemModel? {
        for item in items {
            if item.id == id { return item }
            if let found = find(id, in: item.children) { return found }
        }
        return nil
    }

    /// Parent id (nil = root) and index of `id`.
    static func location(of id: UUID, in items: [OutlineItemModel], parent: UUID? = nil) -> (parent: UUID?, index: Int)? {
        for (index, item) in items.enumerated() {
            if item.id == id { return (parent, index) }
            if let found = location(of: id, in: item.children, parent: item.id) { return found }
        }
        return nil
    }

    static func isDescendant(_ candidate: UUID, of ancestor: UUID, in items: [OutlineItemModel]) -> Bool {
        guard let node = find(ancestor, in: items) else { return false }
        return find(candidate, in: node.children) != nil
    }

    @discardableResult
    static func update(_ id: UUID, in items: inout [OutlineItemModel], _ change: (inout OutlineItemModel) -> Void) -> Bool {
        for index in items.indices {
            if items[index].id == id { change(&items[index]); return true }
            if update(id, in: &items[index].children, change) { return true }
        }
        return false
    }

    /// Removes and returns the items for `ids` (outermost selection wins).
    static func remove(_ ids: Set<UUID>, from items: inout [OutlineItemModel]) -> [OutlineItemModel] {
        var removed: [OutlineItemModel] = []
        items.removeAll { item in
            if ids.contains(item.id) { removed.append(item); return true }
            return false
        }
        for index in items.indices {
            removed += remove(ids, from: &items[index].children)
        }
        return removed
    }

    /// Inserts `moving` under `parent` (nil = root) at `index` (nil = end).
    static func insert(_ moving: [OutlineItemModel], under parent: UUID?, at index: Int?, into items: inout [OutlineItemModel]) {
        if let parent {
            update(parent, in: &items) { node in
                let position = min(max(0, index ?? node.children.count), node.children.count)
                node.children.insert(contentsOf: moving, at: position)
                node.open = true
            }
        } else {
            let position = min(max(0, index ?? items.count), items.count)
            items.insert(contentsOf: moving, at: position)
        }
    }

    /// Moves items (in document order) under `parent` at `index`, adjusting the
    /// index for items removed above it within the same parent. Refuses to
    /// move an item into itself or one of its descendants.
    static func move(_ ids: [UUID], under parent: UUID?, at index: Int?, in items: inout [OutlineItemModel]) -> Bool {
        guard !ids.isEmpty else { return false }
        if let parent, ids.contains(where: { $0 == parent || isDescendant(parent, of: $0, in: items) }) { return false }
        var adjusted = index
        if let target = index {
            let siblings = parent.flatMap { find($0, in: items)?.children } ?? (parent == nil ? items : [])
            adjusted = target - siblings.prefix(target).filter { ids.contains($0.id) }.count
        }
        let order = flatten(items).map(\.id)
        let set = Set(ids)
        var removed = remove(set, from: &items)
        removed.sort { (order.firstIndex(of: $0.id) ?? 0) < (order.firstIndex(of: $1.id) ?? 0) }
        insert(removed, under: parent, at: adjusted, into: &items)
        return true
    }

    static func flatten(_ items: [OutlineItemModel]) -> [OutlineItemModel] {
        items.flatMap { [$0] + flatten($0.children) }
    }

    /// Matches for the filter field, each with its ancestor titles.
    static func matches(_ query: String, in items: [OutlineItemModel], path: [String] = []) -> [(item: OutlineItemModel, path: [String])] {
        var found: [(OutlineItemModel, [String])] = []
        for item in items {
            if item.title.localizedCaseInsensitiveContains(query) { found.append((item, path)) }
            found += matches(query, in: item.children, path: path + [item.title])
        }
        return found
    }

    static func count(_ items: [OutlineItemModel]) -> Int { flatten(items).count }
}
