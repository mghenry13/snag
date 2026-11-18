import Foundation
import UniformTypeIdentifiers
import CoreTransferable
import GRDB

// Private drag payloads so in-app drags (reorder, move, nest) never collide
// with external drags (files, images, URLs), which often carry text too.

extension UTType {
    static let snagItem = UTType(exportedAs: "com.mh.snag.item")
    static let snagFolder = UTType(exportedAs: "com.mh.snag.folder")
}

struct ItemDragPayload: Codable, Transferable {
    let id: String

    static var transferRepresentation: some TransferRepresentation {
        // Internal reference first: in-app reorder/move stays first-class.
        CodableRepresentation(contentType: .snagItem)
        // The actual FILE second: dropping into Finder, Figma, Mail, or any
        // other app delivers a copy with the item's real name.
        FileRepresentation(exportedContentType: .data, exporting: { payload in
            let info: (String, String)? = try? Database.shared.dbQueue.read { db in
                if let row = try Row.fetchOne(db, sql: "SELECT ext, name FROM item WHERE id = ?",
                                              arguments: [payload.id]) {
                    return (row["ext"], row["name"])
                }
                return nil
            }
            guard let (ext, name) = info else {
                throw NSError(domain: "Snag", code: 404,
                              userInfo: [NSLocalizedDescriptionKey: "item not found"])
            }
            let src = Library.filesDir.appendingPathComponent("\(payload.id).\(ext)")
            let safe = String(name.replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-").prefix(80))
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("SnagExport-\(payload.id)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent("\(safe.isEmpty ? payload.id : safe).\(ext)")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: src, to: dest)
            return SentTransferredFile(dest, allowAccessingOriginalFile: true)
        })
    }
}

struct FolderDragPayload: Codable, Transferable {
    let id: String
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .snagFolder)
    }
}

/// What an item drag puts on the pasteboard. Shared by grid cards and list rows.
enum ItemDrag {
    /// - Snag's own item id, so in-app drops (reorder, move to folder) work.
    /// - The file under its own type (public.jpeg, public.mpeg-4…).
    /// - A plain file URL, exactly what a Finder drag carries. Chrome, Electron
    ///   apps (Slack, Discord, ChatGPT) and web upload boxes only read that;
    ///   a lazily created file representation alone reaches them as nothing.
    ///   Registered after the file type so apps that take the picture itself
    ///   still prefer it over a link.
    static func provider(for item: Item) -> NSItemProvider {
        AppState.shared.draggingItemId = item.id
        AppState.shared.draggingFolderId = nil
        let provider = NSItemProvider()
        provider.suggestedName = "\(safeName(item)).\(item.ext)"

        let file = exportURL(for: item)
        let contentType = UTType(filenameExtension: item.ext) ?? .data
        provider.registerFileRepresentation(forTypeIdentifier: contentType.identifier,
                                            fileOptions: [], visibility: .all) { completion in
            completion(file, false, nil)
            return nil
        }
        provider.registerObject(file as NSURL, visibility: .all)

        let id = item.id
        provider.registerDataRepresentation(forTypeIdentifier: UTType.snagItem.identifier,
                                            visibility: .all) { completion in
            completion(try? JSONEncoder().encode(["id": id]), nil)
            return nil
        }
        return provider
    }

    /// The file to hand over. A file from the Files browser is already named,
    /// so it goes as is. A library file is stored under its UUID, so the drag
    /// carries a copy named after the item. The copy is made now, not on drop,
    /// because a file URL has to point at a real file when the drag starts.
    /// On APFS the copy is a clone: instant and takes no extra space.
    static func safeName(_ item: Item) -> String {
        item.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    static func exportURL(for item: Item) -> URL {
        let file = Library.fileURL(for: item)
        if ExternalFiles.isExternal(item.id) { return file }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnagDrag-\(item.id)")
        let base = String(safeName(item).prefix(80))
        let dest = dir.appendingPathComponent("\(base.isEmpty ? item.id : base).\(item.ext)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: file, to: dest)
            return dest
        } catch {
            return file   // the UUID-named original still drops fine, just with that name
        }
    }
}

enum DragDecode {
    static func payloadId(_ provider: NSItemProvider, type: UTType, completion: @escaping (String?) -> Void) {
        guard provider.hasItemConformingToTypeIdentifier(type.identifier) else {
            completion(nil); return
        }
        provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
            guard let data,
                  let obj = try? JSONDecoder().decode([String: String].self, from: data),
                  let id = obj["id"] else { completion(nil); return }
            completion(id)
        }
    }
}
