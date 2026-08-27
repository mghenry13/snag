import Foundation
import GRDB

extension Notification.Name {
    static let libraryChanged = Notification.Name("snag.libraryChanged")
}

final class Database {
    static let shared = Database()
    let dbQueue: DatabaseQueue

    private init() {
        try? FileManager.default.createDirectory(at: Library.root, withIntermediateDirectories: true)
        let dbURL = Library.root.appendingPathComponent("library.sqlite")
        dbQueue = try! DatabaseQueue(path: dbURL.path)
        try! migrator.migrate(dbQueue)
    }

    private var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "folder") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("parentId", .text)
                t.column("position", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "item") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("type", .text).notNull()
                t.column("ext", .text).notNull()
                t.column("folderId", .text)
                t.column("sizeBytes", .integer).notNull().defaults(to: 0)
                t.column("width", .integer).notNull().defaults(to: 0)
                t.column("height", .integer).notNull().defaults(to: 0)
                t.column("sourceURL", .text)
                t.column("pageURL", .text)
                t.column("note", .text).notNull().defaults(to: "")
                t.column("colors", .text).notNull().defaults(to: "[]")
                t.column("hash", .text)
                t.column("rating", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
                t.column("modifiedAt", .datetime).notNull()
                t.column("deletedAt", .datetime)
            }
            try db.create(index: "item_hash", on: "item", columns: ["hash"])
            try db.create(table: "tag") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull().unique()
            }
            try db.create(table: "item_tag") { t in
                t.column("itemId", .text).notNull()
                t.column("tagId", .text).notNull()
                t.primaryKey(["itemId", "tagId"])
            }
        }
        m.registerMigration("v2-folder-color") { db in
            try db.alter(table: "folder") { t in
                t.add(column: "color", .text)
            }
        }
        m.registerMigration("v3-item-sortindex") { db in
            try db.alter(table: "item") { t in
                t.add(column: "sortIndex", .double).notNull().defaults(to: 0)
            }
            // Seed the custom order from the default view (newest first).
            let ids = try String.fetchAll(db, sql: "SELECT id FROM item ORDER BY createdAt DESC")
            for (i, id) in ids.enumerated() {
                try db.execute(sql: "UPDATE item SET sortIndex = ? WHERE id = ?",
                               arguments: [Double(i + 1) * 1024, id])
            }
        }
        return m
    }

    static func notifyChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .libraryChanged, object: nil)
        }
    }
}
