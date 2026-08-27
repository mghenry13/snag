import Foundation
import AppKit
import SwiftUI
import GRDB

enum SidebarFilter: Hashable {
    case all, uncategorized, untagged, recent, random, allTags, trash
    case folder(String)
}

enum GridLayout: String, CaseIterable {
    case waterfall = "Waterfall"
    case grid = "Grid"
    case list = "List"
}

enum SortBy: String, CaseIterable {
    case dateAdded = "Date Added"
    case name = "Name"
    case size = "Size"
    case rating = "Rating"
}

final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var folders: [Folder] = []
    @Published var items: [Item] = []          // all non-deleted
    @Published var trashed: [Item] = []
    @Published var tagsByItem: [String: [String]] = [:]  // itemId -> tag names
    @Published var allTags: [Tag] = []

    @Published var filter: SidebarFilter = .all
    @Published var searchText: String = ""
    @Published var selectedItemId: String? = nil
    @Published var zoom: Double = 200
    @Published var folderFilterText: String = ""
    @Published var randomSeed: Int = 0
    @Published var layout: GridLayout = .waterfall
    @Published var sortBy: SortBy = .dateAdded
    @Published var showName: Bool = true
    @Published var previewItemId: String? = nil

    private init() {
        NotificationCenter.default.addObserver(forName: .libraryChanged, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }
        reload()
    }

    var selectedItem: Item? {
        guard let id = selectedItemId else { return nil }
        return items.first { $0.id == id } ?? trashed.first { $0.id == id }
    }

    func reload() {
        do {
            let (f, i, t, tags, itemTags): ([Folder], [Item], [Item], [Tag], [ItemTag]) = try Database.shared.dbQueue.read { db in
                (try Folder.order(Column("position"), Column("name")).fetchAll(db),
                 try Item.filter(Column("deletedAt") == nil).order(Column("createdAt").desc).fetchAll(db),
                 try Item.filter(Column("deletedAt") != nil).order(Column("deletedAt").desc).fetchAll(db),
                 try Tag.order(Column("name")).fetchAll(db),
                 try ItemTag.fetchAll(db))
            }
            folders = f
            items = i
            trashed = t
            allTags = tags
            let tagName = Dictionary(uniqueKeysWithValues: tags.map { ($0.id, $0.name) })
            var byItem: [String: [String]] = [:]
            for it in itemTags {
                byItem[it.itemId, default: []].append(tagName[it.tagId] ?? "")
            }
            tagsByItem = byItem
        } catch {
            NSLog("Snag reload error: \(error)")
        }
    }

    // MARK: - Derived views

    func childFolders(of parentId: String?) -> [Folder] {
        folders.filter { $0.parentId == parentId }
    }

    func descendantIds(of folderId: String) -> Set<String> {
        var result: Set<String> = [folderId]
        var queue = [folderId]
        while let next = queue.popLast() {
            for child in folders where child.parentId == next {
                if result.insert(child.id).inserted { queue.append(child.id) }
            }
        }
        return result
    }

    func count(for filter: SidebarFilter) -> Int {
        switch filter {
        case .all: return items.count
        case .uncategorized: return items.filter { $0.folderId == nil }.count
        case .untagged: return items.filter { (tagsByItem[$0.id] ?? []).isEmpty }.count
        case .recent: return min(items.count, 50)
        case .random: return items.count
        case .allTags: return allTags.count
        case .trash: return trashed.count
        case .folder(let id):
            let ids = descendantIds(of: id)
            return items.filter { $0.folderId.map(ids.contains) ?? false }.count
        }
    }

    var visibleItems: [Item] {
        var base: [Item]
        switch filter {
        case .all, .allTags: base = items
        case .uncategorized: base = items.filter { $0.folderId == nil }
        case .untagged: base = items.filter { (tagsByItem[$0.id] ?? []).isEmpty }
        case .recent: base = Array(items.prefix(50))
        case .random:
            var gen = SeededGenerator(seed: UInt64(bitPattern: Int64(randomSeed)) &+ 0x9E3779B9)
            base = items.shuffled(using: &gen)
        case .trash: base = trashed
        case .folder(let id):
            let ids = descendantIds(of: id)
            base = items.filter { $0.folderId.map(ids.contains) ?? false }
        }
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            base = base.filter { item in
                item.name.lowercased().contains(q)
                    || item.note.lowercased().contains(q)
                    || (item.domain ?? "").lowercased().contains(q)
                    || (tagsByItem[item.id] ?? []).contains { $0.lowercased().contains(q) }
            }
        }
        switch sortBy {
        case .dateAdded: break // already newest first
        case .name: base.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .size: base.sort { $0.sizeBytes > $1.sizeBytes }
        case .rating: base.sort { $0.rating > $1.rating }
        }
        return base
    }

    // MARK: - Preview navigation

    var previewItem: Item? {
        guard let id = previewItemId else { return nil }
        return items.first { $0.id == id } ?? trashed.first { $0.id == id }
    }

    func togglePreview() {
        if previewItemId != nil { previewItemId = nil }
        else if let sel = selectedItemId { previewItemId = sel }
    }

    func previewStep(_ delta: Int) {
        let vis = visibleItems
        guard !vis.isEmpty else { return }
        let currentId = previewItemId ?? selectedItemId
        let idx = vis.firstIndex { $0.id == currentId } ?? 0
        let next = min(max(idx + delta, 0), vis.count - 1)
        selectedItemId = vis[next].id
        if previewItemId != nil { previewItemId = vis[next].id }
    }

    var filterTitle: String {
        switch filter {
        case .all: return "All"
        case .uncategorized: return "Uncategorized"
        case .untagged: return "Untagged"
        case .recent: return "Recently Used"
        case .random: return "Random"
        case .allTags: return "All Tags"
        case .trash: return "Trash"
        case .folder(let id): return folders.first { $0.id == id }?.name ?? "Folder"
        }
    }

    // MARK: - Mutations

    func update(_ item: Item) {
        var it = item
        it.modifiedAt = Date()
        try? Database.shared.dbQueue.write { db in try it.update(db) }
        Database.notifyChanged()
    }

    func moveItem(_ itemId: String, to folderId: String?) {
        guard var it = items.first(where: { $0.id == itemId }) else { return }
        it.folderId = folderId
        update(it)
    }

    func trashItem(_ item: Item) {
        var it = item
        it.deletedAt = Date()
        try? Database.shared.dbQueue.write { db in try it.update(db) }
        if selectedItemId == it.id { selectedItemId = nil }
        Database.notifyChanged()
    }

    func restoreItem(_ item: Item) {
        var it = item
        it.deletedAt = nil
        try? Database.shared.dbQueue.write { db in try it.update(db) }
        Database.notifyChanged()
    }

    func emptyTrash() {
        let dead = trashed
        try? Database.shared.dbQueue.write { db in
            for it in dead {
                try ItemTag.filter(Column("itemId") == it.id).deleteAll(db)
                _ = try it.delete(db)
            }
        }
        for it in dead {
            try? FileManager.default.removeItem(at: Library.fileURL(for: it))
            try? FileManager.default.removeItem(at: Library.thumbURL(for: it))
        }
        Database.notifyChanged()
    }

    @discardableResult
    func createFolder(name: String, parentId: String? = nil) -> Folder {
        let folder = Folder(name: name, parentId: parentId, position: folders.count)
        try? Database.shared.dbQueue.write { db in try folder.insert(db) }
        Database.notifyChanged()
        return folder
    }

    func addTag(_ name: String, to item: Item) {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        try? Database.shared.dbQueue.write { db in
            let tag: Tag
            if let existing = try Tag.filter(Column("name") == clean).fetchOne(db) {
                tag = existing
            } else {
                tag = Tag(id: UUID().uuidString, name: clean)
                try tag.insert(db)
            }
            try? ItemTag(itemId: item.id, tagId: tag.id).insert(db)
        }
        Database.notifyChanged()
    }

    func removeTag(_ name: String, from item: Item) {
        try? Database.shared.dbQueue.write { db in
            if let tag = try Tag.filter(Column("name") == name).fetchOne(db) {
                try ItemTag.filter(Column("itemId") == item.id && Column("tagId") == tag.id).deleteAll(db)
            }
        }
        Database.notifyChanged()
    }
}

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0xDEADBEEF : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}

final class ThumbCache {
    static let shared = ThumbCache()
    private let cache = NSCache<NSString, NSImage>()

    func thumbnail(for item: Item) -> NSImage? {
        let key = item.id as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let thumbURL = Library.thumbURL(for: item)
        var image = NSImage(contentsOf: thumbURL)
        if image == nil, item.itemType == .image {
            image = NSImage(contentsOf: Library.fileURL(for: item))
        }
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    func invalidate(_ itemId: String) { cache.removeObject(forKey: itemId as NSString) }
}
