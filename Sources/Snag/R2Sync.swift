import Foundation
import CryptoKit
import GRDB

/// Optional Cloudflare R2 backup. S3-compatible PUTs with SigV4 signing —
/// no SDK. Uploads the database on every sync plus any library files not
/// yet uploaded (tracked in a local manifest). Local-only use stays the
/// default: with no credentials saved, none of this runs.
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

    /// Upload the DB + any files not in the manifest. Returns a summary line.
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

        var uploaded = 0, failed = 0
        var manifest = loadManifest()

        // 1. The index, always fresh.
        do {
            let db = try Data(contentsOf: Library.root.appendingPathComponent("library.sqlite"))
            try await put(key: "library.sqlite", data: db, config: config)
        } catch {
            let msg = "Sync failed: \(error.localizedDescription)"
            await MainActor.run { self.status = msg }
            return msg
        }

        // 2. Content files are immutable — upload only what's new.
        let fm = FileManager.default
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
        saveManifest(manifest)

        let df = DateFormatter(); df.dateFormat = "MMM d, HH:mm"
        UserDefaults.standard.set(Date(), forKey: "snag.r2.lastSync")
        let msg = failed == 0
            ? "Synced \(df.string(from: Date())) — \(uploaded) new files"
            : "Synced with \(failed) failures — \(uploaded) new files"
        await MainActor.run { self.status = msg }
        return msg
    }

    // MARK: - SigV4 PUT

    enum R2Error: LocalizedError {
        case http(Int, String)
        var errorDescription: String? {
            if case .http(let code, let body) = self { return "HTTP \(code): \(body.prefix(120))" }
            return nil
        }
    }

    private func put(key: String, data: Data, config: Config) async throws {
        let host = "\(config.accountId).r2.cloudflarestorage.com"
        let path = "/\(config.bucket)/\(key)"
        guard let url = URL(string: "https://\(host)\(path)") else { throw R2Error.http(0, "bad url") }

        let now = Date()
        let amzFmt = DateFormatter()
        amzFmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        amzFmt.timeZone = TimeZone(identifier: "UTC")
        amzFmt.locale = Locale(identifier: "en_US_POSIX")
        let amzDate = amzFmt.string(from: now)
        let dateStamp = String(amzDate.prefix(8))

        let payloadHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters:
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/")) ?? path

        let canonical = [
            "PUT", encodedPath, "",
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
        req.httpMethod = "PUT"
        req.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        req.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        req.setValue("AWS4-HMAC-SHA256 Credential=\(config.accessKey)/\(scope), "
                     + "SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=\(signature)",
                     forHTTPHeaderField: "Authorization")
        let (body, resp) = try await URLSession.shared.upload(for: req, from: data)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw R2Error.http(code, String(data: body, encoding: .utf8) ?? "")
        }
    }
}
