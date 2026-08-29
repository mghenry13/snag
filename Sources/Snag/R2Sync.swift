import Foundation
import CryptoKit
import GRDB

/// Cloudflare R2 sync. S3-compatible requests with SigV4 signing — no SDK.
///
/// Push: the database, an `index.json` the phone can read without SQLite,
/// every content file, and every thumbnail. Files and thumbnails are
/// immutable, so a local manifest keeps each one to a single upload.
///
/// Pull: anything the phone dropped in `inbox/`, imported into the library
/// and then removed from the bucket.
///
/// Local-only use stays the default: with no credentials saved, none of this runs.
final class R2Sync: ObservableObject {
    static let shared = R2Sync()

    @Published var status: String = ""
    @Published var running = false

    struct Config {
        var accountId: String
        var accessKey: String
        var secretKey: String
        var bucket: String

        var isComplete: Bool {
            ![accountId, accessKey, secretKey, bucket].contains(where: \.isEmpty)
        }

        static func load() -> Config {
            let d = UserDefaults.standard
            func clean(_ key: String) -> String {
                (d.string(forKey: key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return Config(
                accountId: clean("snag.r2.accountId"),
                accessKey: clean("snag.r2.accessKey"),
                secretKey: clean("snag.r2.secretKey"),
                bucket: clean("snag.r2.bucket")
            )
        }

        func save() {
            let d = UserDefaults.standard
            d.set(accountId, forKey: "snag.r2.accountId")
            d.set(accessKey, forKey: "snag.r2.accessKey")
            d.set(secretKey, forKey: "snag.r2.secretKey")
            d.set(bucket, forKey: "snag.r2.bucket")
        }
    }

    private var manifestURL: URL {
        Library.root.appendingPathComponent("backups/r2-manifest.json")
    }

    private func loadManifest() -> Set<String> {
        guard let data = try? Data(contentsOf: manifestURL),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(arr)
    }

    private func saveManifest(_ set: Set<String>) {
        try? FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Array(set).sorted()) {
            try? data.write(to: manifestURL)
        }
    }

    /// Push the library up, pull the phone's inbox down. Returns a summary line.
    @discardableResult
    func syncNow() async -> String {
        let config = Config.load()
        guard config.isComplete else {
            let msg = "R2 not configured"
            await MainActor.run { self.status = msg }
            return msg
        }
        await MainActor.run { self.running = true; self.status = "Syncing…" }
        defer { Task { @MainActor in self.running = false } }

        // 1. Anything saved from the phone comes in first, so the index we
        //    upload below already describes it.
        var imported = 0
        do {
            imported = try await drainInbox(config: config)
        } catch {
            // A failed pull must not block the backup.
            imported = 0
        }

        var uploaded = 0, failed = 0
        var manifest = loadManifest()

        // 2. The database, always fresh.
        do {
            let db = try Data(contentsOf: Library.root.appendingPathComponent("library.sqlite"))
            try await put(key: "library.sqlite", data: db, config: config)
        } catch {
            let msg = "Sync failed: \(error.localizedDescription)"
            await MainActor.run { self.status = msg }
            return msg
        }

        // 3. The phone reads this instead of the database.
        do {
            try await put(key: "index.json", data: try buildIndex(),
                          contentType: "application/json", config: config)
        } catch {
            failed += 1
        }

        let fm = FileManager.default
        // 4. Content files and thumbnails are immutable — upload only what is new.
        let files = (try? fm.contentsOfDirectory(at: Library.filesDir, includingPropertiesForKeys: nil)) ?? []
        for url in files where !manifest.contains(url.lastPathComponent) {
            do {
                let data = try Data(contentsOf: url)
                try await put(key: "files/\(url.lastPathComponent)", data: data, config: config)
                manifest.insert(url.lastPathComponent)
                uploaded += 1
                if uploaded % 10 == 0 {
                    let n = uploaded
                    await MainActor.run { self.status = "Syncing… \(n) files" }
                    saveManifest(manifest)
                }
            } catch {
                failed += 1
            }
        }

        let thumbs = (try? fm.contentsOfDirectory(at: Library.thumbsDir, includingPropertiesForKeys: nil)) ?? []
        for url in thumbs where !manifest.contains("thumb/\(url.lastPathComponent)") {
            do {
                let data = try Data(contentsOf: url)
                try await put(key: "thumbs/\(url.lastPathComponent)", data: data,
                              contentType: "image/png", config: config)
                manifest.insert("thumb/\(url.lastPathComponent)")
                uploaded += 1
                if uploaded % 25 == 0 { saveManifest(manifest) }
            } catch {
                failed += 1
            }
        }
        saveManifest(manifest)

        let df = DateFormatter(); df.dateFormat = "MMM d, HH:mm"
        UserDefaults.standard.set(Date(), forKey: "snag.r2.lastSync")
        let phonePart = imported > 0 ? ", \(imported) from phone" : ""
        let msg = failed == 0
            ? "Synced \(df.string(from: Date())) — \(uploaded) new files\(phonePart)"
            : "Synced with \(failed) failures — \(uploaded) new files\(phonePart)"
        await MainActor.run { self.status = msg }
        return msg
    }

    // MARK: - Background poll

    /// Long enough to stay out of the way, short enough that something saved
    /// on the phone appears while you are still thinking about it.
    private static let pollInterval: UInt64 = 5 * 60 * 1_000_000_000

    private var poller: Task<Void, Never>?
    private var lastStamp: Date?

    /// Watch for phone saves and for local edits the phone has not seen.
    /// Safe to call more than once. Called after the first sync, so the
    /// library is already current when the first tick lands.
    func startPolling() {
        guard poller == nil else { return }
        lastStamp = databaseStamp()
        poller = Task.detached(priority: .background) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: R2Sync.pollInterval)
                guard let self else { return }
                await self.syncIfNeeded()
            }
        }
    }

    /// A full sync walks the whole library, so only pay for one when there is
    /// something to carry. A quiet tick costs one LIST request and a stat, and
    /// says nothing in the UI.
    private func syncIfNeeded() async {
        let config = Config.load()
        guard config.isComplete else { return }

        // Never race a sync the user started, or the one before this tick.
        let busy = await MainActor.run { self.running }
        if busy { return }

        // Phone saves are the reason this poll exists.
        let inbox = (try? await list(prefix: "inbox/", config: config)) ?? []
        var due = !inbox.isEmpty

        // Local edits have to reach the phone too.
        let stamp = databaseStamp()
        if !due, stamp != lastStamp { due = true }

        guard due else { return }
        lastStamp = stamp
        await syncNow()
    }

    /// Newest write across the database and any journal beside it. A missing
    /// file just reads as "nothing changed", which is the safe answer.
    private func databaseStamp() -> Date? {
        let fm = FileManager.default
        var newest: Date?
        for name in ["library.sqlite", "library.sqlite-wal"] {
            let path = Library.root.appendingPathComponent(name).path
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let date = attrs[.modificationDate] as? Date else { continue }
            if newest == nil || date > newest! { newest = date }
        }
        return newest
    }

    // MARK: - Index

    /// A flat JSON description of the library. The phone has no SQLite copy of
    /// this database, and giving it one would mean shipping the whole file on
    /// every change, so the index carries only what the grid needs to draw.
    private func buildIndex() throws -> Data {
        let (folders, items) = try Database.shared.dbQueue.read { db in
            (try Folder.order(Column("position")).fetchAll(db),
             try Item.filter(Column("deletedAt") == nil)
                     .order(Column("createdAt").desc).fetchAll(db))
        }
        let iso = ISO8601DateFormatter()
        let payload: [String: Any] = [
            "version": 1,
            "generatedAt": iso.string(from: Date()),
            "folders": folders.map { f -> [String: Any] in
                ["id": f.id, "name": f.name, "parentId": f.parentId as Any,
                 "position": f.position, "color": f.color as Any]
            },
            "items": items.map { item -> [String: Any] in
                var row = APIServer.itemJSON(item)
                // A path on this Mac means nothing on the phone.
                row.removeValue(forKey: "filePath")
                row["modifiedAt"] = iso.string(from: item.modifiedAt)
                return row
            },
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    // MARK: - Inbox

    /// Import everything the phone left in `inbox/`, then delete it from the
    /// bucket. Each upload is a pair: the media file, and a `.json` sidecar
    /// naming the folder it should land in.
    private func drainInbox(config: Config) async throws -> Int {
        let keys = try await list(prefix: "inbox/", config: config)
        let sidecars = keys.filter { $0.hasSuffix(".json") }
        guard !sidecars.isEmpty else { return 0 }

        await MainActor.run { self.status = "Importing \(sidecars.count) from phone…" }

        var imported = 0
        for sidecarKey in sidecars {
            do {
                let metaData = try await get(key: sidecarKey, config: config)
                let meta = (try? JSONSerialization.jsonObject(with: metaData)) as? [String: Any] ?? [:]
                guard let mediaKey = meta["key"] as? String else { continue }

                let media = try await get(key: mediaKey, config: config)
                let name = (meta["name"] as? String) ?? "From phone"
                let ext = (mediaKey as NSString).pathExtension.isEmpty
                    ? "jpg" : (mediaKey as NSString).pathExtension

                let folderId = meta["folderId"] as? String
                let result: ImportResult
                if ext == "url" {
                    // A link shared from the phone. The body is the URL text.
                    // importData would file it as an image with no pixels and
                    // no thumbnail, so use the same path the web clipper uses.
                    let raw = (meta["sourceURL"] as? String)
                        ?? String(decoding: media, as: UTF8.self)
                    result = try Library.importBookmark(
                        url: raw.trimmingCharacters(in: .whitespacesAndNewlines),
                        title: name,
                        folderId: folderId
                    )
                } else {
                    // Import the bytes directly. Staging to a temp file would
                    // name the item after that file, losing the phone's name.
                    result = try Library.importData(
                        media,
                        ext: ext,
                        name: name,
                        folderId: folderId,
                        sourceURL: meta["sourceURL"] as? String,
                        pageURL: meta["pageURL"] as? String
                    )
                }
                if let note = meta["note"] as? String, !note.isEmpty {
                    try await Database.shared.dbQueue.write { db in
                        var item = result.item
                        item.note = note
                        try item.update(db)
                    }
                }

                try await delete(key: mediaKey, config: config)
                try await delete(key: sidecarKey, config: config)
                imported += 1
            } catch {
                // Leave a failed item in the bucket so the next sync retries it.
                continue
            }
        }
        if imported > 0 {
            await MainActor.run { AppState.shared.reload() }
        }
        return imported
    }

    // MARK: - SigV4

    enum R2Error: LocalizedError {
        case http(Int, String)
        var errorDescription: String? {
            if case .http(let code, let body) = self { return "HTTP \(code): \(body.prefix(120))" }
            return nil
        }
    }

    private static let allowedInPath = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/")
    private static let allowedInQuery = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    /// Build a signed request. `query` is given as pairs so the canonical
    /// string can sort and encode them the way SigV4 demands.
    private func signedRequest(method: String, key: String, query: [(String, String)] = [],
                               body: Data = Data(), contentType: String? = nil,
                               config: Config) throws -> URLRequest {
        let host = "\(config.accountId).r2.cloudflarestorage.com"
        let path = key.isEmpty ? "/\(config.bucket)" : "/\(config.bucket)/\(key)"
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: Self.allowedInPath) ?? path

        var encodedPairs: [String] = []
        for (k, v) in query {
            let ek: String = k.addingPercentEncoding(withAllowedCharacters: Self.allowedInQuery) ?? k
            let ev: String = v.addingPercentEncoding(withAllowedCharacters: Self.allowedInQuery) ?? v
            encodedPairs.append(ek + "=" + ev)
        }
        encodedPairs.sort()
        let canonicalQuery: String = encodedPairs.joined(separator: "&")

        var comps = "https://\(host)\(encodedPath)"
        if !canonicalQuery.isEmpty { comps += "?\(canonicalQuery)" }
        guard let url = URL(string: comps) else { throw R2Error.http(0, "bad url") }

        let amzFmt = DateFormatter()
        amzFmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        amzFmt.timeZone = TimeZone(identifier: "UTC")
        amzFmt.locale = Locale(identifier: "en_US_POSIX")
        let amzDate = amzFmt.string(from: Date())
        let dateStamp = String(amzDate.prefix(8))

        let payloadHash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()

        let canonical = [
            method, encodedPath, canonicalQuery,
            "host:\(host)", "x-amz-content-sha256:\(payloadHash)", "x-amz-date:\(amzDate)", "",
            "host;x-amz-content-sha256;x-amz-date",
            payloadHash,
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/auto/s3/aws4_request"
        let canonicalHash = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, canonicalHash].joined(separator: "\n")

        func hmac(_ key: Data, _ msg: String) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: Data(msg.utf8), using: SymmetricKey(data: key)))
        }
        let kDate = hmac(Data("AWS4\(config.secretKey)".utf8), dateStamp)
        let kRegion = hmac(kDate, "auto")
        let kService = hmac(kRegion, "s3")
        let kSigning = hmac(kService, "aws4_request")
        let signature = hmac(kSigning, stringToSign).map { String(format: "%02x", $0) }.joined()

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        req.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        req.setValue("AWS4-HMAC-SHA256 Credential=\(config.accessKey)/\(scope), "
                     + "SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=\(signature)",
                     forHTTPHeaderField: "Authorization")
        return req
    }

    @discardableResult
    private func send(_ req: URLRequest, uploading body: Data?) async throws -> Data {
        let (data, resp): (Data, URLResponse)
        if let body {
            (data, resp) = try await URLSession.shared.upload(for: req, from: body)
        } else {
            (data, resp) = try await URLSession.shared.data(for: req)
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw R2Error.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private func put(key: String, data: Data, contentType: String? = nil, config: Config) async throws {
        let req = try signedRequest(method: "PUT", key: key, body: data,
                                    contentType: contentType, config: config)
        try await send(req, uploading: data)
    }

    private func get(key: String, config: Config) async throws -> Data {
        let req = try signedRequest(method: "GET", key: key, config: config)
        return try await send(req, uploading: nil)
    }

    private func delete(key: String, config: Config) async throws {
        let req = try signedRequest(method: "DELETE", key: key, config: config)
        try await send(req, uploading: nil)
    }

    /// List every key under a prefix, following continuation tokens.
    private func list(prefix: String, config: Config) async throws -> [String] {
        var keys: [String] = []
        var token: String?
        repeat {
            var query: [(String, String)] = [("list-type", "2"), ("prefix", prefix)]
            if let token { query.append(("continuation-token", token)) }
            let req = try signedRequest(method: "GET", key: "", query: query, config: config)
            let xml = String(data: try await send(req, uploading: nil), encoding: .utf8) ?? ""
            keys.append(contentsOf: Self.parseTags(xml, tag: "Key"))
            let next = Self.parseTags(xml, tag: "NextContinuationToken").first
            token = (Self.parseTags(xml, tag: "IsTruncated").first == "true") ? next : nil
        } while token != nil
        return keys
    }

    /// Pull the contents of one repeated XML tag. The list response is a fixed,
    /// flat shape, so a full parser would be more moving parts than it is worth.
    private static func parseTags(_ xml: String, tag: String) -> [String] {
        var out: [String] = []
        let open = "<\(tag)>", close = "</\(tag)>"
        var rest = Substring(xml)
        while let s = rest.range(of: open), let e = rest.range(of: close, range: s.upperBound..<rest.endIndex) {
            out.append(String(rest[s.upperBound..<e.lowerBound])
                .replacingOccurrences(of: "&amp;", with: "&"))
            rest = rest[e.upperBound...]
        }
        return out
    }
}
