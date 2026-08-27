import Foundation
import UniformTypeIdentifiers
import CoreTransferable

// Private drag payloads so in-app drags (reorder, move, nest) never collide
// with external drags (files, images, URLs), which often carry text too.

extension UTType {
    static let snagItem = UTType(exportedAs: "com.mh.snag.item")
    static let snagFolder = UTType(exportedAs: "com.mh.snag.folder")
}

struct ItemDragPayload: Codable, Transferable {
    let id: String
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .snagItem)
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
