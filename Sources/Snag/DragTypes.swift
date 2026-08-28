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
