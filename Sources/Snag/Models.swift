import Foundation
import GRDB

enum ItemType: String, Codable {
    case image, video, url
}

struct Folder: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable {
    static let databaseTableName = "folder"
    var id: String
    var name: String
    var parentId: String?
    var position: Int
    var createdAt: Date

    init(name: String, parentId: String? = nil, position: Int = 0) {
        self.id = UUID().uuidString
        self.name = name
        self.parentId = parentId
        self.position = position
        self.createdAt = Date()
    }
}

struct Item: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable {
    static let databaseTableName = "item"
    var id: String
    var name: String
    var type: String
    var ext: String
    var folderId: String?
    var sizeBytes: Int64
    var width: Int
    var height: Int
    var sourceURL: String?
    var pageURL: String?
    var note: String
    var colors: String // JSON array of hex strings
    var hash: String?
    var rating: Int
    var createdAt: Date
    var modifiedAt: Date
    var deletedAt: Date?

    var itemType: ItemType { ItemType(rawValue: type) ?? .image }

    var palette: [String] {
        guard let data = colors.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return arr
    }

    var domain: String? {
        guard let s = sourceURL ?? pageURL, let url = URL(string: s), let host = url.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var isYouTube: Bool { (domain ?? "").contains("youtube.com") || (domain ?? "").contains("youtu.be") }
}

struct Tag: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable {
    static let databaseTableName = "tag"
    var id: String
    var name: String
}

struct ItemTag: Codable, FetchableRecord, PersistableRecord, Hashable {
    static let databaseTableName = "item_tag"
    var itemId: String
    var tagId: String
}
