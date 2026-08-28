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

enum MediaFilter: String, CaseIterable {
    case all = "All Types"
    case image = "Images"
    case video = "Videos"
    case url = "Links"

    var icon: String {
        switch self {
        case .all: return "square.stack.3d.up"
        case .image: return "photo"
        case .video: return "film"
        case .url: return "link"
        }
    }
}

enum SortBy: String, CaseIterable {
    case mostRecent = "Most Recent"
    case oldestFirst = "Oldest First"
    case name = "Name"
    case size = "Size"
    case rating = "Rating"
    case custom = "Custom Order"
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
    @Published var selectedItemId: String? = nil   // primary (drives inspector/preview)
    @Published var selectedItemIds: Set<String> = []
    @Published var searchFocusToken: Int = 0
    @Published var searchBlurToken: Int = 0
    @Published var zoom: Double = 200
    @Published var folderFilterText: String = ""
    @Published var randomSeed: Int = 0
    @Published var layout: GridLayout = .waterfall
    @Published var sortBy: SortBy = .mostRecent
    @Published var minRating: Int = 0
    @Published var mediaFilter: MediaFilter = .all
    @Published var showName: Bool = false
    @Published var showRating: Bool = false
    @Published var previewItemId: String? = nil
    @Published var visualSearchItem: Item? = nil
    @Published var previewZoom: CGFloat = 1.0
    @Published var showSettings = false
    /// True while ANY drag is in flight — per-card drop views mount only then.
    @Published var dragActive = false
    /// In-process handoff for Snag's own drags. SwiftUI provides pasteboard
    /// data lazily, so a drop target reading it synchronously gets nothing —
    /// these are set at drag start and read at drop time.
    var draggingItemId: String? = nil
    var draggingFolderId: String? = nil
    @Published var recentFolderIds: [String] = []

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
            recentFolderIds = UserDefaults.standard.stringArray(forKey: "snag.recentFolders") ?? []
            rebuildCounts()
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

    // Counts are O(n) each; sidebar rows render often — compute once per reload.
    private var folderCounts: [String: Int] = [:]
    private var uncategorizedCount = 0
    private var untaggedCount = 0

    private func rebuildCounts() {
        var direct: [String: Int] = [:]
        uncategorizedCount = 0
        untaggedCount = 0
        for it in items {
            if let f = it.folderId { direct[f, default: 0] += 1 } else { uncategorizedCount += 1 }
            if (tagsByItem[it.id] ?? []).isEmpty { untaggedCount += 1 }
        }
        var rolled: [String: Int] = [:]
        for f in folders {
            var total = 0
            for id in descendantIds(of: f.id) { total += direct[id] ?? 0 }
            rolled[f.id] = total
        }
        folderCounts = rolled
    }

    func count(for filter: SidebarFilter) -> Int {
        switch filter {
        case .all: return items.count
        case .uncategorized: return uncategorizedCount
        case .untagged: return untaggedCount
        case .recent: return min(items.count, 50)
        case .random: return items.count
        case .allTags: return allTags.count
        case .trash: return trashed.count
        case .folder(let id): return folderCounts[id] ?? 0
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
        if minRating > 0 {
            base = base.filter { $0.rating >= minRating }
        }
        switch mediaFilter {
        case .all: break
        case .image: base = base.filter { $0.itemType == .image }
        case .video: base = base.filter { $0.itemType == .video }
        case .url: base = base.filter { $0.itemType == .url }
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
        base = sorted(base)
        return base
    }

    /// Apply the current sort to any item array (base order is newest first).
    private func sorted(_ arr: [Item]) -> [Item] {
        var a = arr
        switch sortBy {
        case .mostRecent: break // already newest first
        case .oldestFirst: a.reverse()
        case .name: a.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .size: a.sort { $0.sizeBytes > $1.sizeBytes }
        case .rating: a.sort { $0.rating > $1.rating }
        case .custom: a.sort { $0.sortIndex < $1.sortIndex }
        }
        return a
    }

    // MARK: - Clipboard

    /// Cmd+C. Copies the previewed item, or the whole grid selection.
    /// Images go on the pasteboard as BOTH image data and a file URL, so a
    /// paste lands correctly in Figma/Photoshop and in Finder alike.
    @discardableResult
    func copySelectionToClipboard() -> Int {
        var targets: [Item] = []
        if let pid = previewItemId, let it = items.first(where: { $0.id == pid }) {
            targets = [it]
        } else {
            let ids = selectedItemIds
            targets = items.filter { ids.contains($0.id) }
            if targets.isEmpty, let it = selectedItem { targets = [it] }
        }
        guard !targets.isEmpty else { return 0 }

        let pb = NSPasteboard.general
        pb.clearContents()

        // Bookmarks copy as their link; everything else as the real file.
        var objects: [NSPasteboardWriting] = []
        for item in targets {
            if item.itemType == .url, let s = item.sourceURL, let url = URL(string: s) {
                objects.append(url as NSURL)
                continue
            }
            let file = Library.fileURL(for: item)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            if targets.count == 1, item.itemType == .image, let img = NSImage(contentsOf: file) {
                objects.append(img)   // pasteable pixels for design tools
            }
            objects.append(file as NSURL)
        }
        guard !objects.isEmpty else { return 0 }
        pb.writeObjects(objects)
        return targets.count
    }

    // MARK: - Manual grid order (drag to reorder, Cmd+Z to undo)

    private struct ReorderStep {
        let indexes: [String: Double]
        let sort: SortBy
    }
    private var reorderStack: [ReorderStep] = []
    var canUndoReorder: Bool { !reorderStack.isEmpty }

    /// Place the dragged item immediately before the target, switching to
    /// Custom Order (seeded from whatever order is on screen right now).
    func reorderItem(_ draggedId: String, before targetId: String) {
        guard draggedId != targetId,
              let dragged = items.first(where: { $0.id == draggedId }),
              items.contains(where: { $0.id == targetId }) else { return }

        var snapshot: [String: Double] = [:]
        for it in items { snapshot[it.id] = it.sortIndex }
        let step = ReorderStep(indexes: snapshot, sort: sortBy)

        var order = sorted(items)
        order.removeAll { $0.id == draggedId }
        guard let t = order.firstIndex(where: { $0.id == targetId }) else { return }
        order.insert(dragged, at: t)

        try? Database.shared.dbQueue.write { db in
            for (i, var it) in order.enumerated() {
                it.sortIndex = Double(i + 1) * 1024
                try it.update(db)
            }
        }
        reorderStack.append(step)
        if reorderStack.count > 30 { reorderStack.removeFirst() }
        sortBy = .custom
        Database.notifyChanged()
    }

    func undoReorder() {
        guard let step = reorderStack.popLast() else { return }
        try? Database.shared.dbQueue.write { db in
            for var it in try Item.fetchAll(db) {
                if let old = step.indexes[it.id], old != it.sortIndex {
                    it.sortIndex = old
                    try it.update(db)
                }
            }
        }
        sortBy = step.sort
        Database.notifyChanged()
    }

    /// Keyboard 1-5: rate the selection; on a single item the same number clears.
    func setRating(_ n: Int) {
        let targets = selectedItemIds.isEmpty
            ? (selectedItem.map { [$0.id] } ?? [])
            : Array(selectedItemIds)
        if targets.count == 1, var item = items.first(where: { $0.id == targets[0] }) {
            item.rating = (item.rating == n) ? 0 : n
            update(item)
            return
        }
        for id in targets {
            guard var item = items.first(where: { $0.id == id }) else { continue }
            item.rating = n
            update(item)
        }
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
        selectedItemIds = [vis[next].id]
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
        selectedItemIds.remove(it.id)
        Database.notifyChanged()
    }

    /// Release keyboard focus from any text field. SwiftUI's private field
    /// editor ignores makeFirstResponder(nil), so force the window to end
    /// editing and park focus on the window itself.
    func blurTextFocus() {
        searchBlurToken &+= 1
        // Let SwiftUI process searchFocused = false FIRST, then clear the
        // window's editor — doing it synchronously loses a race where the
        // focus engine immediately re-grabs the field.
        DispatchQueue.main.async {
            let win = NSApp.keyWindow ?? (NSApp.delegate as? AppDelegate)?.window
            guard let win else { return }
            win.endEditing(for: nil)
            win.makeFirstResponder(win)
        }
    }

    /// Click selection: plain click replaces, Cmd+click toggles.
    func select(_ id: String, additive: Bool) {
        blurTextFocus()
        if additive {
            if selectedItemIds.contains(id) {
                selectedItemIds.remove(id)
                if selectedItemId == id { selectedItemId = selectedItemIds.first }
            } else {
                selectedItemIds.insert(id)
                selectedItemId = id
            }
        } else {
            selectedItemIds = [id]
            selectedItemId = id
        }
    }

    func moveItems(_ ids: Set<String>, to folderId: String?) {
        for id in ids { moveItem(id, to: folderId) }
    }

    func trashItems(_ ids: Set<String>) {
        for id in ids {
            if let it = items.first(where: { $0.id == id }) { trashItem(it) }
        }
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

    /// Reorder: place a folder among the children of `parent` at `index`
    /// (index measured against the CURRENT displayed sibling list).
    func reorderFolder(_ folderId: String, parent: String?, index: Int) {
        guard folderId != parent,
              let dragged = folders.first(where: { $0.id == folderId }) else { return }
        if let parent, descendantIds(of: folderId).contains(parent) { return } // no cycles

        var siblings = childFolders(of: parent)
        var insertAt = index
        if let currentIdx = siblings.firstIndex(where: { $0.id == folderId }) {
            siblings.remove(at: currentIdx)
            if currentIdx < insertAt { insertAt -= 1 }
        }
        insertAt = max(0, min(insertAt, siblings.count))
        var moved = dragged
        moved.parentId = parent
        siblings.insert(moved, at: insertAt)

        try? Database.shared.dbQueue.write { db in
            for (i, var f) in siblings.enumerated() {
                f.position = i
                try f.update(db)
            }
        }
        Database.notifyChanged()
    }

    /// Re-parent a folder (drag-nesting). Refuses cycles.
    func nestFolder(_ folderId: String, under parentId: String?) {
        guard folderId != parentId,
              var folder = folders.first(where: { $0.id == folderId }) else { return }
        if let parentId, descendantIds(of: folderId).contains(parentId) { return } // no cycles
        guard folder.parentId != parentId else { return }
        folder.parentId = parentId
        try? Database.shared.dbQueue.write { db in try folder.update(db) }
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

/// Async, downsampled thumbnail cache. Decodes off the main thread via ImageIO
/// at the size actually displayed, so scrolling and zooming stay fluid.
final class ThumbCache {
    static let shared = ThumbCache()
    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "snag.thumbs", qos: .userInitiated, attributes: .concurrent)

    init() { cache.countLimit = 800 }

    private func key(_ item: Item, _ maxPixel: Int, original: Bool) -> NSString {
        "\(item.id)|\(maxPixel)|\(original)" as NSString
    }

    func cached(_ item: Item, maxPixel: Int = 480, original: Bool = false) -> NSImage? {
        cache.object(forKey: key(item, maxPixel, original: original))
    }

    func load(_ item: Item, maxPixel: Int = 480, original: Bool = false) async -> NSImage? {
        if let hit = cached(item, maxPixel: maxPixel, original: original) { return hit }
        return await withCheckedContinuation { cont in
            queue.async {
                let url = original ? Library.fileURL(for: item) : Library.thumbURL(for: item)
                var img = Self.decode(url: url, maxPixel: maxPixel)
                if img == nil, item.itemType == .image {
                    img = Self.decode(url: Library.fileURL(for: item), maxPixel: maxPixel)
                }
                if let img {
                    self.cache.setObject(img, forKey: self.key(item, maxPixel, original: original))
                }
                cont.resume(returning: img)
            }
        }
    }

    private static func decode(url: URL, maxPixel: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    func invalidate(_ itemId: String) {
        // Cheap blanket clear; repopulates lazily at display size.
        cache.removeAllObjects()
    }
}

/// Placeholder-then-image view: shows the cached bitmap instantly when warm,
/// otherwise a flat card while the decode happens off-main.
struct ThumbImage<Content: View>: View {
    let item: Item
    var maxPixel: Int = 480
    var original: Bool = false
    @ViewBuilder let content: (NSImage?) -> Content
    @State private var image: NSImage? = nil

    var body: some View {
        content(image ?? ThumbCache.shared.cached(item, maxPixel: maxPixel, original: original))
            .task(id: "\(item.id)|\(maxPixel)|\(original)") {
                if ThumbCache.shared.cached(item, maxPixel: maxPixel, original: original) == nil {
                    let loaded = await ThumbCache.shared.load(item, maxPixel: maxPixel, original: original)
                    if !Task.isCancelled { image = loaded }
                } else if image == nil {
                    image = ThumbCache.shared.cached(item, maxPixel: maxPixel, original: original)
                }
            }
    }
}
