import Foundation

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
     "description": "Get one Snag item by id, including its local file path.",
     "inputSchema": schema(["id": ["type": "string"]], required: ["id"])],
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

func runTool(_ name: String, _ args: [String: Any]) -> (String, Bool) {
    func text(_ obj: Any?) -> String {
        guard let obj, let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) else { return "null" }
        return String(data: data, encoding: .utf8) ?? "null"
    }

    switch name {
    case "search_items":
        var qs: [String] = []
        if let q = args["query"] as? String { qs.append("query=\(q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")") }
        if let f = args["folderId"] as? String { qs.append("folderId=\(f)") }
        qs.append("limit=\((args["limit"] as? Int) ?? 25)")
        let (status, json) = apiRequest(method: "GET", path: "/items?\(qs.joined(separator: "&"))")
        return status == 200 ? (text(json), false) : ("Snag app is not running or errored (status \(status))", true)
    case "get_item":
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
        let (out, isError) = runTool(name, args)
        reply(id: id ?? NSNull(), result: [
            "content": [["type": "text", "text": out]],
            "isError": isError,
        ])
    default:
        if let id {
            send(["jsonrpc": "2.0", "id": id,
                  "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
    }
}
