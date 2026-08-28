import Foundation
import AppKit
import Network
import GRDB

/// Minimal localhost HTTP/1.1 server for the Chrome extension and MCP.
final class APIServer {
    static let port: UInt16 = 41777
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "snag.api")

    func start() {
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
            listener = try NWListener(using: params)
            listener?.newConnectionHandler = { [weak self] conn in
                self?.handle(conn)
            }
            listener?.start(queue: queue)
            NSLog("Snag API listening on 127.0.0.1:\(Self.port)")
        } catch {
            NSLog("Snag API failed to start: \(error)")
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveRequest(conn, buffer: Data())
    }

    private func receiveRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if error != nil { conn.cancel(); return }

            if let request = HTTPRequest(data: buf) {
                self.route(request) { response in
                    conn.send(content: response.serialized, completion: .contentProcessed { _ in conn.cancel() })
                }
            } else if done {
                conn.cancel()
            } else {
                self.receiveRequest(conn, buffer: buf)
            }
        }
    }

    private func route(_ req: HTTPRequest, respond: @escaping (HTTPResponse) -> Void) {
        let parts = req.path.split(separator: "?")[0].split(separator: "/").map(String.init)
        do {
            switch (req.method, parts.first ?? "") {
            case ("GET", "debug-responder"):
                var name = "none"
                DispatchQueue.main.sync {
                    if let win = (NSApp.delegate as? AppDelegate)?.window,
                       let fr = win.firstResponder {
                        name = String(describing: type(of: fr))
                    }
                }
                respond(.json(["responder": name]))

            case ("POST", "r2-sync"):
                Task {
                    let summary = await R2Sync.shared.syncNow()
                    respond(.json(["result": summary]))
                }

            case ("GET", "health"):
                respond(.json(["ok": true, "version": "1.0", "app": "Snag"]))

            case ("GET", "folders"):
                let folders = try Database.shared.dbQueue.read { try Folder.order(Column("position"), Column("name")).fetchAll($0) }
                respond(.json(folders.map { ["id": $0.id, "name": $0.name, "parentId": $0.parentId as Any] }))

            case ("POST", "folders"):
                let body = req.jsonBody
                guard let name = body["name"] as? String, !name.isEmpty else {
                    respond(.error(400, "name required")); return
                }
                let folder = AppState.runOnMain { AppState.shared.createFolder(name: name, parentId: body["parentId"] as? String) }
                respond(.json(["id": folder.id, "name": folder.name]))

            case ("GET", "items") where parts.count == 1:
                let q = req.queryParams
                var items = try Database.shared.dbQueue.read {
                    try Item.filter(Column("deletedAt") == nil).order(Column("createdAt").desc).fetchAll($0)
                }
                if let folderId = q["folderId"] { items = items.filter { $0.folderId == folderId } }
                if let query = q["query"]?.lowercased(), !query.isEmpty {
                    items = items.filter {
                        $0.name.lowercased().contains(query) || $0.note.lowercased().contains(query)
                            || ($0.domain ?? "").lowercased().contains(query)
                    }
                }
                let limit = Int(q["limit"] ?? "") ?? 100
                let offset = Int(q["offset"] ?? "") ?? 0
                let page = items.dropFirst(offset).prefix(limit)
                respond(.json(page.map { Self.itemJSON($0) }))

            case ("GET", "items") where parts.count >= 2:
                guard let item = try Database.shared.dbQueue.read({ try Item.fetchOne($0, key: parts[1]) }) else {
                    respond(.error(404, "not found")); return
                }
                if parts.count == 3 && parts[2] == "file" {
                    let url = Library.fileURL(for: item)
                    if let data = try? Data(contentsOf: url) {
                        respond(HTTPResponse(status: 200, contentType: "application/octet-stream", body: data))
                    } else { respond(.error(404, "file missing")) }
                } else if parts.count == 3 && parts[2] == "thumbnail" {
                    if let data = try? Data(contentsOf: Library.thumbURL(for: item)) {
                        respond(HTTPResponse(status: 200, contentType: "image/png", body: data))
                    } else { respond(.error(404, "no thumbnail")) }
                } else {
                    respond(.json(Self.itemJSON(item)))
                }

            case ("POST", "items"):
                let body = req.jsonBody
                // Raw upload (extension screen captures): {dataBase64, ext, name, folderId?}
                if let b64 = body["dataBase64"] as? String {
                    guard let data = Data(base64Encoded: b64) else {
                        respond(.error(400, "bad base64")); return
                    }
                    let ext = (body["ext"] as? String) ?? "png"
                    let name = (body["name"] as? String) ?? "Capture"
                    let result = try Library.importData(
                        data, ext: ext, name: name,
                        folderId: body["folderId"] as? String,
                        sourceURL: body["sourceURL"] as? String,
                        pageURL: body["pageURL"] as? String
                    )
                    respond(.json(["id": result.item.id, "duplicate": result.isDuplicate, "name": result.item.name]))
                    return
                }
                guard let urlString = body["url"] as? String else {
                    respond(.error(400, "url required")); return
                }
                let pageURL = body["pageURL"] as? String
                let folderId = body["folderId"] as? String
                Task {
                    do {
                        let result = try await Library.importRemote(urlString: urlString, pageURL: pageURL, folderId: folderId)
                        respond(.json(["id": result.item.id, "duplicate": result.isDuplicate, "name": result.item.name]))
                    } catch {
                        respond(.error(500, "import failed: \(error.localizedDescription)"))
                    }
                }

            case ("PATCH", "items") where parts.count == 2:
                guard var item = try Database.shared.dbQueue.read({ try Item.fetchOne($0, key: parts[1]) }) else {
                    respond(.error(404, "not found")); return
                }
                let body = req.jsonBody
                if let name = body["name"] as? String { item.name = name }
                if let note = body["note"] as? String { item.note = note }
                if let rating = body["rating"] as? Int { item.rating = rating }
                if body.keys.contains("folderId") { item.folderId = body["folderId"] as? String }
                item.modifiedAt = Date()
                try Database.shared.dbQueue.write { try item.update($0) }
                if let tags = body["tags"] as? [String] {
                    let frozen = item
                    AppState.runOnMainVoid {
                        for t in tags { AppState.shared.addTag(t, to: frozen) }
                    }
                }
                Database.notifyChanged()
                respond(.json(Self.itemJSON(item)))

            case ("DELETE", "items") where parts.count == 2:
                guard var item = try Database.shared.dbQueue.read({ try Item.fetchOne($0, key: parts[1]) }) else {
                    respond(.error(404, "not found")); return
                }
                item.deletedAt = Date()
                try Database.shared.dbQueue.write { try item.update($0) }
                Database.notifyChanged()
                respond(.json(["ok": true]))

            default:
                respond(.error(404, "unknown route"))
            }
        } catch {
            respond(.error(500, error.localizedDescription))
        }
    }

    static func itemJSON(_ item: Item) -> [String: Any] {
        [
            "id": item.id, "name": item.name, "type": item.type, "ext": item.ext,
            "folderId": item.folderId as Any, "sizeBytes": item.sizeBytes,
            "width": item.width, "height": item.height,
            "sourceURL": item.sourceURL as Any, "pageURL": item.pageURL as Any,
            "note": item.note, "colors": item.palette, "rating": item.rating,
            "filePath": Library.fileURL(for: item).path,
            "createdAt": ISO8601DateFormatter().string(from: item.createdAt),
        ]
    }
}

extension AppState {
    static func runOnMain<T>(_ block: @escaping () -> T) -> T {
        if Thread.isMainThread { return block() }
        var result: T!
        DispatchQueue.main.sync { result = block() }
        return result
    }
    static func runOnMainVoid(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.sync(execute: block) }
    }
}

// MARK: - Tiny HTTP plumbing

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    init?(data: Data) {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].components(separatedBy: " ")
        guard requestLine.count >= 2 else { return nil }
        method = requestLine[0]
        path = requestLine[1]
        var h: [String: String] = [:]
        for line in lines.dropFirst() {
            if let idx = line.firstIndex(of: ":") {
                h[String(line[..<idx]).lowercased()] = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        headers = h
        let bodyStart = headerEnd.upperBound
        let expected = Int(h["content-length"] ?? "0") ?? 0
        let available = data.count - bodyStart
        if available < expected { return nil } // wait for more data
        body = data.subdata(in: bodyStart..<(bodyStart + expected))
    }

    var jsonBody: [String: Any] {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }

    var queryParams: [String: String] {
        guard let qIdx = path.firstIndex(of: "?") else { return [:] }
        var out: [String: String] = [:]
        for pair in path[path.index(after: qIdx)...].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                out[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
            }
        }
        return out
    }
}

struct HTTPResponse {
    let status: Int
    let contentType: String
    let body: Data

    static func json(_ obj: Any) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [])) ?? Data("{}".utf8)
        return HTTPResponse(status: 200, contentType: "application/json", body: data)
    }
    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data()
        return HTTPResponse(status: status, contentType: "application/json", body: data)
    }

    var serialized: Data {
        let statusText = status == 200 ? "OK" : "Error"
        var head = "HTTP/1.1 \(status) \(statusText)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        return out
    }
}
