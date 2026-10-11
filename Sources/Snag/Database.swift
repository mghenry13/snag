import Foundation
import AppKit
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
        do {
            dbQueue = try DatabaseQueue(path: dbURL.path)
            try migrator.migrate(dbQueue)
        } catch {
            // A damaged library or a full disk used to crash on every launch
            // with no explanation. Say what happened and where the backups are,
            // then quit without touching anything.
            Database.failAndQuit(error, dbURL: dbURL)
        }
    }

    private static func failAndQuit(_ error: Error, dbURL: URL) -> Never {
        let show = {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Snag can't open its library"
            alert.informativeText = """
            \(error.localizedDescription)

            Library: \(dbURL.path)
            Daily backups: \(Library.root.appendingPathComponent("backups").path)

            Nothing was changed. To restore, quit Snag, replace library.sqlite with \
            the newest backup (renamed to library.sqlite), and open Snag again.
            """
            alert.addButton(withTitle: "Show Backups")
            alert.addButton(withTitle: "Quit")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(Library.root.appendingPathComponent("backups"))
            }
        }
        if Thread.isMainThread { show() } else { DispatchQueue.main.sync(execute: show) }
        exit(1)
    }

    /// A consistent copy of the live database at `url`. Copying the .sqlite
    /// file directly can capture a half-written page if a save lands mid-copy,
    /// and such a backup only reveals itself as corrupt when you need it.
    /// SQLite's online backup copies a transactionally consistent snapshot.
    func snapshot(to url: URL) throws {
        let fm = FileManager.default
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).partial")
        try? fm.removeItem(at: tmp)
        do {
            let dest = try DatabaseQueue(path: tmp.path)
            try dbQueue.backup(to: dest)
            try dest.close()
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
        // Publish only a finished copy, so a crash never leaves a truncated
        // file under the real name.
        try? fm.removeItem(at: url)
        try fm.moveItem(at: tmp, to: url)
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

    // Every write used to queue its own full reload, so moving or trashing N
    // items (or importing a batch) re-read the whole library N times on the
    // main thread. A reload reads the database as it is when it runs, so one
    // reload after a burst of writes shows all of them; later calls during the
    // burst are folded into the one already queued.
    private static let notifyLock = NSLock()
    private static var notifyPending = false

    static func notifyChanged() {
        notifyLock.lock()
        if notifyPending { notifyLock.unlock(); return }
        notifyPending = true
        notifyLock.unlock()
        DispatchQueue.main.async {
            notifyLock.lock(); notifyPending = false; notifyLock.unlock()
            NotificationCenter.default.post(name: .libraryChanged, object: nil)
        }
    }
}
