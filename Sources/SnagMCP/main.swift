import Foundation
import ImageIO
import UniformTypeIdentifiers

// snag-mcp: stdio MCP server bridging to the Snag app's local HTTP API.
// Newline-delimited JSON-RPC 2.0 over stdin/stdout.

let API = "http://127.0.0.1:41777"

// MARK: - HTTP bridge

func apiRequest(method: String, path: String, body: [String: Any]? = nil) -> (Int, Any?) {
    guard let url = URL(string: API + path) else { return (0, nil) }
    var req = URLRequest(url: url)
    req.httpMethod = method
    if let body {
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let sem = DispatchSemaphore(value: 0)
    var status = 0
    var json: Any? = nil
    URLSession.shared.dataTask(with: req) { data, resp, _ in
        status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if let data { json = try? JSONSerialization.jsonObject(with: data) }
        sem.signal()
    }.resume()
    sem.wait()
    return (status, json)
}

// MARK: - Tool definitions

func schema(_ props: [String: [String: Any]], required: [String] = []) -> [String: Any] {
    ["type": "object", "properties": props, "required": required]
}

let tools: [[String: Any]] = [
    ["name": "search_items",
     "description": "Search the Snag library. Returns item metadata including local file paths.",
     "inputSchema": schema([
        "query": ["type": "string", "description": "Text matched against name, note, and source domain"],
        "folderId": ["type": "string", "description": "Limit to one folder"],
        "limit": ["type": "integer", "description": "Max results, default 25"],
     ])],
    ["name": "get_item",
     "description": "Get one Snag item by id, including its local file path and its picture so you can see it. People copy items out of Snag as lines like `Snag item 0082934F-0119-4B6B-938D-17449C51C620 \"Name\"` (Copy Snag ID); the UUID is the id to pass here and to move_item, set_note and add_tags.",
     "inputSchema": schema(["id": ["type": "string", "description": "The item's UUID, e.g. from a pasted `Snag item <id>` line"]], required: ["id"])],
    ["name": "view_items",
     "description": "Look at Snag items: returns each item's picture (the image itself, or the thumbnail of a video or link) so you can see it, plus its id and name. Up to 8 ids per call.",
     "inputSchema": schema(["ids": ["type": "array", "items": ["type": "string"],
                                    "description": "Item UUIDs, e.g. from search_items or pasted `Snag item <id>` lines"]],
                           required: ["ids"])],
    ["name": "list_folders",
     "description": "List all folders in the Snag library (id, name, parentId).",
     "inputSchema": schema([:])],
    ["name": "create_folder",
     "description": "Create a folder in the Snag library.",
     "inputSchema": schema([
        "name": ["type": "string"],
        "parentId": ["type": "string", "description": "Optional parent folder id"],
     ], required: ["name"])],
    ["name": "add_item",
     "description": "Save a URL into the Snag library. Image and video URLs are downloaded; other pages are saved as URL bookmarks.",
     "inputSchema": schema([
        "url": ["type": "string"],
        "pageURL": ["type": "string", "description": "The page the asset came from"],
        "folderId": ["type": "string"],
     ], required: ["url"])],
    ["name": "move_item",
     "description": "Move an item to a folder (or to Uncategorized when folderId is omitted).",
     "inputSchema": schema([
        "id": ["type": "string"],
        "folderId": ["type": "string"],
     ], required: ["id"])],
    ["name": "set_note",
     "description": "Set the note text on an item.",
     "inputSchema": schema([
        "id": ["type": "string"],
        "note": ["type": "string"],
     ], required: ["id", "note"])],
    ["name": "add_tags",
     "description": "Add tags to an item.",
     "inputSchema": schema([
        "id": ["type": "string"],
        "tags": ["type": "array", "items": ["type": "string"]],
     ], required: ["id", "tags"])],
]

// MARK: - Tool execution

// MARK: - Pictures

let libraryRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Snag")
let imageExts: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "heic", "heif", "tiff", "tif", "bmp", "avif"]

/// An MCP image block for an item: the file itself when it's an image,
/// otherwise the thumbnail Snag made for it (videos, links). Scaled to at
/// most 1568px on the long side and sent as JPEG, so a screenshot or a
/// 1920px Mobbin screen stays well under the clients' size limits.
func imageBlock(for item: [String: Any]) -> [String: Any]? {
    guard let id = item["id"] as? String else { return nil }
    var candidates: [URL] = []
    if let path = item["filePath"] as? String, imageExts.contains((item["ext"] as? String ?? "").lowercased()) {
        candidates.append(URL(fileURLWithPath: path))
    }
    candidates.append(libraryRoot.appendingPathComponent("thumbnails/\(id).png"))
    for url in candidates where FileManager.default.fileExists(atPath: url.path) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1568,
              ] as CFDictionary) else { continue }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { continue }
        return ["type": "image", "data": (out as Data).base64EncodedString(), "mimeType": "image/jpeg"]
    }
    return nil
}

func runTool(_ name: String, _ args: [String: Any]) -> [[String: Any]]? {
    switch name {
    case "get_item":
        let (status, json) = apiRequest(method: "GET", path: "/items/\(args["id"] as? String ?? "")")
        guard status == 200, let item = json as? [String: Any] else { return nil }
        let (out, _) = runTextTool(name, args, prefetched: json)
        return [["type": "text", "text": out]] + [imageBlock(for: item)].compactMap { $0 }
    case "view_items":
        let ids = (args["ids"] as? [String] ?? []).prefix(8)
        var blocks: [[String: Any]] = []
        for id in ids {
            let (status, json) = apiRequest(method: "GET", path: "/items/\(id)")
            guard status == 200, let item = json as? [String: Any] else {
                blocks.append(["type": "text", "text": "Snag item \(id): not found"]); continue
            }
            let label = "Snag item \(id) \"\(item["name"] as? String ?? "")\" (\(item["type"] as? String ?? ""))"
            if let img = imageBlock(for: item) {
                blocks.append(["type": "text", "text": label]); blocks.append(img)
            } else {
                blocks.append(["type": "text", "text": label + ": no picture available"])
            }
        }
        return blocks
    default:
        return nil
    }
}

func runTextTool(_ name: String, _ args: [String: Any], prefetched: Any? = nil) -> (String, Bool) {
    func text(_ obj: Any?) -> String {
        guard let obj, let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) else { return "null" }
        return String(data: data, encoding: .utf8) ?? "null"
    }

    switch name {
    case "search_items":
        var qs: [String] = []
        // .urlQueryAllowed leaves & and = alone, so "AT&T" searched for "AT".
        var valueChars = CharacterSet.urlQueryAllowed
        valueChars.remove(charactersIn: "&=+?#")
        if let q = args["query"] as? String { qs.append("query=\(q.addingPercentEncoding(withAllowedCharacters: valueChars) ?? "")") }
        if let f = args["folderId"] as? String { qs.append("folderId=\(f)") }
        qs.append("limit=\((args["limit"] as? Int) ?? 25)")
        let (status, json) = apiRequest(method: "GET", path: "/items?\(qs.joined(separator: "&"))")
        return status == 200 ? (text(json), false) : ("Snag app is not running or errored (status \(status))", true)
    case "get_item":
        if let prefetched { return (text(prefetched), false) }
        let (status, json) = apiRequest(method: "GET", path: "/items/\(args["id"] as? String ?? "")")
        return status == 200 ? (text(json), false) : ("Item not found (status \(status))", true)
    case "list_folders":
        let (status, json) = apiRequest(method: "GET", path: "/folders")
        return status == 200 ? (text(json), false) : ("Snag app is not running (status \(status))", true)
    case "create_folder":
        let (status, json) = apiRequest(method: "POST", path: "/folders", body: args)
        return status == 200 ? (text(json), false) : ("Create failed (status \(status))", true)
    case "add_item":
        let (status, json) = apiRequest(method: "POST", path: "/items", body: args)
        return status == 200 ? (text(json), false) : ("Import failed (status \(status)): \(text(json))", true)
    case "move_item":
        var body: [String: Any] = ["folderId": args["folderId"] as? String as Any]
        if args["folderId"] == nil { body["folderId"] = NSNull() }
        let (status, json) = apiRequest(method: "PATCH", path: "/items/\(args["id"] as? String ?? "")", body: body)
        return status == 200 ? (text(json), false) : ("Move failed (status \(status))", true)
    case "set_note":
        let (status, json) = apiRequest(method: "PATCH", path: "/items/\(args["id"] as? String ?? "")",
                                        body: ["note": args["note"] as? String ?? ""])
        return status == 200 ? (text(json), false) : ("Update failed (status \(status))", true)
    case "add_tags":
        let (status, json) = apiRequest(method: "PATCH", path: "/items/\(args["id"] as? String ?? "")",
                                        body: ["tags": args["tags"] as? [String] ?? []])
        return status == 200 ? (text(json), false) : ("Update failed (status \(status))", true)
    default:
        return ("Unknown tool: \(name)", true)
    }
}

// MARK: - JSON-RPC loop

func send(_ obj: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func reply(id: Any, result: [String: Any]) {
    send(["jsonrpc": "2.0", "id": id, "result": result])
}

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty,
          let data = line.data(using: .utf8),
          let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let method = msg["method"] as? String else { continue }
    let id = msg["id"]

    switch method {
    case "initialize":
        reply(id: id ?? NSNull(), result: [
            "protocolVersion": (msg["params"] as? [String: Any])?["protocolVersion"] as? String ?? "2024-11-05",
            "capabilities": ["tools": [:] as [String: Any]],
            "serverInfo": ["name": "snag", "version": "1.0.0"],
        ])
    case "notifications/initialized", "notifications/cancelled":
        break
    case "ping":
        reply(id: id ?? NSNull(), result: [:])
    case "tools/list":
        reply(id: id ?? NSNull(), result: ["tools": tools])
    case "tools/call":
        let params = msg["params"] as? [String: Any] ?? [:]
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        if let blocks = runTool(name, args) {
            reply(id: id ?? NSNull(), result: ["content": blocks, "isError": false])
        } else {
            let (out, isError) = runTextTool(name, args)
            reply(id: id ?? NSNull(), result: [
                "content": [["type": "text", "text": out]],
                "isError": isError,
            ])
        }
    default:
        if let id {
            send(["jsonrpc": "2.0", "id": id,
                  "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
    }
}
