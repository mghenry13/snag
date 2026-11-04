import Foundation
import AppKit
import CryptoKit
import GRDB

// Who the library's items came from, in two levels:
//
//   Account  — the brand or person ("Tangle News"), what the sidebar lists.
//   Profile  — one platform presence of it (Tangle on Instagram, on X, its
//              Facebook page, the same page as a Meta Ads advertiser).
//
// Every item points at the profile it was saved from. A new profile starts in
// an account of its own; merging accounts moves profiles under one.

/// One platform presence: an Instagram or X handle, a LinkedIn person or
/// company, a Facebook page, a Meta Ads advertiser.
struct Profile: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable {
    static let databaseTableName = "profile"
    /// "platform:handle", lowercased. Deterministic, so saving from any source
    /// finds the same row without a lookup.
    var id: String
    var platform: String
    var handle: String
    var name: String
    var url: String?
    var accountId: String
    /// File name in Library.avatarsDir, once a picture has been fetched.
    var avatarFile: String?
    var createdAt: Date

    var platformInfo: Platform { Platform(rawValue: platform) ?? .other }
    var displayName: String { name.isEmpty ? handle : name }

    /// "@handle" where handles are what people call the account.
    var handleLabel: String? {
        guard platformInfo.handlesAreNames else { return nil }
        return "@\(handle)"
    }
}

/// The brand or person behind one or more profiles.
struct Account: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable {
    static let databaseTableName = "account"
    var id: String
    var name: String
    var createdAt: Date
}

enum Platform: String, CaseIterable {
    case instagram, x, linkedin, facebook, metaAds = "meta_ads", tiktok, youtube, threads, pinterest, reddit, vimeo, other

    var label: String {
        switch self {
        case .instagram: return "Instagram"
        case .x: return "X"
        case .linkedin: return "LinkedIn"
        case .facebook: return "Facebook"
        case .metaAds: return "Meta Ads"
        case .tiktok: return "TikTok"
        case .youtube: return "YouTube"
        case .threads: return "Threads"
        case .pinterest: return "Pinterest"
        case .reddit: return "Reddit"
        case .vimeo: return "Vimeo"
        case .other: return "Other"
        }
    }

    /// A short badge: brand logos are not ours to ship.
    var badge: String {
        switch self {
        case .instagram: return "IG"
        case .x: return "X"
        case .linkedin: return "in"
        case .facebook: return "FB"
        case .metaAds: return "AD"
        case .tiktok: return "TT"
        case .youtube: return "YT"
        case .threads: return "TH"
        case .pinterest: return "PI"
        case .reddit: return "RD"
        case .vimeo: return "VI"
        case .other: return "•"
        }
    }

    var color: String {
        switch self {
        case .instagram: return "#E1306C"
        case .x: return "#8A8D91"
        case .linkedin: return "#0A66C2"
        case .facebook: return "#1877F2"
        case .metaAds: return "#0081FB"
        case .tiktok: return "#25C4CE"
        case .youtube: return "#FF0000"
        case .threads: return "#8A8D91"
        case .pinterest: return "#E60023"
        case .reddit: return "#FF4500"
        case .vimeo: return "#1AB7EA"
        case .other: return "#8A8D91"
        }
    }

    /// Order of the platform tabs inside an account.
    static let tabOrder: [Platform] = [.instagram, .facebook, .metaAds, .x, .linkedin, .tiktok, .youtube, .threads, .pinterest, .reddit, .vimeo, .other]

    var handlesAreNames: Bool { [.instagram, .x, .tiktok, .threads, .youtube, .pinterest, .reddit].contains(self) }

    /// The platform a page belongs to, from its address.
    static func from(host: String?) -> Platform? {
        guard var h = host?.lowercased() else { return nil }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        if h.hasPrefix("m.") || h.hasPrefix("mobile.") { h = String(h.drop { $0 != "." }.dropFirst()) }
        switch true {
        case h.hasSuffix("instagram.com"): return .instagram
        case h == "x.com" || h.hasSuffix("twitter.com"): return .x
        case h.hasSuffix("linkedin.com"): return .linkedin
        case h.hasSuffix("facebook.com") || h == "fb.com" || h == "fb.watch": return .facebook
        case h.hasSuffix("tiktok.com"): return .tiktok
        case h.hasSuffix("youtube.com") || h == "youtu.be": return .youtube
        case h.hasSuffix("threads.net") || h.hasSuffix("threads.com"): return .threads
        case h.hasSuffix("pinterest.com"): return .pinterest
        case h.hasSuffix("reddit.com"): return .reddit
        case h.hasSuffix("vimeo.com"): return .vimeo
        default: return nil
        }
    }
}

/// A profile as a saver describes it, before it has a row.
struct AccountInfo {
    var platform: String
    var handle: String
    var name: String
    var url: String?
    var avatarURL: String?

    init?(platform: String?, handle: String?, name: String?, url: String?, avatarURL: String? = nil) {
        let p = (platform ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        var h = (handle ?? "").trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("@") { h.removeFirst() }
        let n = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if h.isEmpty { h = n }
        guard !p.isEmpty, !h.isEmpty else { return nil }
        self.platform = p
        self.handle = h
        self.name = n
        self.url = url.flatMap { $0.isEmpty ? nil : $0 }
        self.avatarURL = avatarURL.flatMap { $0.hasPrefix("http") ? $0 : nil }
    }

    /// The `account` object the browser extension and the API send.
    init?(json: Any?) {
        guard let d = json as? [String: Any] else { return nil }
        self.init(platform: d["platform"] as? String, handle: d["handle"] as? String,
                  name: d["name"] as? String, url: d["url"] as? String,
                  avatarURL: d["avatar"] as? String)
    }

    var id: String { "\(platform):\(handle.lowercased())" }

    /// The profile behind a yt-dlp download, from its info file.
    static func from(ytdlp info: [String: Any], link: String) -> AccountInfo? {
        func s(_ k: String) -> String { ((info[k] as? String) ?? "").trimmingCharacters(in: .whitespaces) }
        let page = s("webpage_url").isEmpty ? link : s("webpage_url")
        guard let platform = Platform.from(host: URL(string: page)?.host) else { return nil }
        // A username beats a display name, and neither is a bare number.
        let handle = [s("channel"), s("uploader_id")].first {
            !$0.isEmpty && !$0.contains(" ") && !$0.allSatisfy(\.isNumber)
        }
        let profile = [s("uploader_url"), s("channel_url")].first { !$0.isEmpty }
        return AccountInfo(platform: platform.rawValue, handle: handle ?? s("uploader"),
                           name: s("uploader"), url: profile)
    }
}

enum Accounts {

    // MARK: Profiles

    /// Find or create the profile (and, for a new one, its account), filling
    /// in a name or link it lacked. Returns the profile id.
    @discardableResult
    static func upsert(_ info: AccountInfo, _ db: GRDB.Database) throws -> String {
        if var row = try Profile.fetchOne(db, key: info.id) {
            var changed = false
            if !info.name.isEmpty, row.name != info.name, row.name.isEmpty || row.name == row.handle {
                row.name = info.name; changed = true
            }
            if row.url == nil, let u = info.url { row.url = u; changed = true }
            if changed {
                try row.update(db)
                // An account named after a bare handle takes the real name.
                if var acct = try Account.fetchOne(db, key: row.accountId),
                   acct.name.caseInsensitiveCompare(row.handle) == .orderedSame {
                    acct.name = row.displayName
                    try acct.update(db)
                }
            }
            return row.id
        }
        let accountId = try homeAccount(for: info, db)
        try Profile(id: info.id, platform: info.platform, handle: info.handle, name: info.name,
                    url: info.url ?? defaultURL(info), accountId: accountId, avatarFile: nil,
                    createdAt: Date()).insert(db)
        return info.id
    }

    /// The account a new profile joins. A Meta Ads advertiser and the
    /// Facebook page it advertises as are the same page, so they share one;
    /// anything else starts its own.
    private static func homeAccount(for info: AccountInfo, _ db: GRDB.Database) throws -> String {
        let twin: String? = switch info.platform {
        case Platform.metaAds.rawValue: "\(Platform.facebook.rawValue):\(info.handle.lowercased())"
        case Platform.facebook.rawValue: "\(Platform.metaAds.rawValue):\(info.handle.lowercased())"
        default: nil
        }
        if let twin, let other = try Profile.fetchOne(db, key: twin) { return other.accountId }
        let account = Account(id: UUID().uuidString, name: info.name.isEmpty ? info.handle : info.name,
                              createdAt: Date())
        try account.insert(db)
        return account.id
    }

    /// A profile link when the saver gave none.
    private static func defaultURL(_ info: AccountInfo) -> String? {
        switch Platform(rawValue: info.platform) {
        case .instagram: return "https://www.instagram.com/\(info.handle)/"
        case .x: return "https://x.com/\(info.handle)"
        case .tiktok: return "https://www.tiktok.com/@\(info.handle)"
        case .threads: return "https://www.threads.net/@\(info.handle)"
        case .facebook, .metaAds: return "https://www.facebook.com/\(info.handle)"
        default: return nil
        }
    }

    /// Link an item to its profile. `replace` is for an explicit choice (the
    /// extension knows the author for certain); otherwise an item keeps the
    /// profile it has.
    static func attach(_ info: AccountInfo?, toItem itemId: String, replace: Bool = false) {
        guard let info else { return }
        try? Database.shared.dbQueue.write { db in
            let id = try upsert(info, db)
            let sql = replace
                ? "UPDATE item SET profileId = ? WHERE id = ?"
                : "UPDATE item SET profileId = ? WHERE id = ? AND profileId IS NULL"
            try db.execute(sql: sql, arguments: [id, itemId])
        }
        fetchAvatarIfMissing(info)
        Database.notifyChanged()
    }

    // MARK: Pictures

    /// Download a profile's picture once. The links the sites hand out are
    /// signed and expire within days, so keep the picture, not the link.
    /// With no picture link (a phone share, an older save), try the profile
    /// page's own preview image, which public Instagram and Facebook pages
    /// carry.
    static func fetchAvatarIfMissing(_ info: AccountInfo) {
        let row = try? Database.shared.dbQueue.read { db in try Profile.fetchOne(db, key: info.id) }
        guard let profile = row ?? nil, profile.avatarFile == nil else { return }
        let direct = info.avatarURL.flatMap(URL.init(string:))
        Task.detached(priority: .utility) { await fetchAvatar(profile, direct: direct) }
    }

    /// Every profile still without a picture, at most once a day each.
    static func fetchMissingAvatars() {
        let missing = (try? Database.shared.dbQueue.read { db in
            try Profile.filter(Column("avatarFile") == nil).fetchAll(db)
        }) ?? []
        Task.detached(priority: .background) {
            for p in missing { await fetchAvatar(p, direct: nil) }
        }
    }

    private static func fetchAvatar(_ profile: Profile, direct: URL?) async {
        var source = direct
        if source == nil {
            let key = "snag.avatarTried.\(profile.id)"
            let last = UserDefaults.standard.double(forKey: key)
            guard Date().timeIntervalSince1970 - last > 86_400,
                  let page = profile.url.flatMap(URL.init(string:)) else { return }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: key)
            guard let (data, _) = try? await URLSession.shared.data(for: LinkPreview.request(page)),
                  let html = String(data: data, encoding: .utf8) else { return }
            source = LinkPreview.parse(html: html, base: page).imageURL
        }
        guard let url = source,
              let (data, resp) = try? await URLSession.shared.data(for: LinkPreview.request(url)),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let image = NSImage(data: data),
              let png = squarePNG(image, side: 256) else { return }
        let name = SHA256.hash(data: Data(profile.id.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined() + ".png"
        try? FileManager.default.createDirectory(at: Library.avatarsDir, withIntermediateDirectories: true)
        guard (try? png.write(to: Library.avatarsDir.appendingPathComponent(name), options: .atomic)) != nil else { return }
        try? await Database.shared.dbQueue.write { db in
            try db.execute(sql: "UPDATE profile SET avatarFile = ? WHERE id = ?", arguments: [name, profile.id])
        }
        await MainActor.run { AvatarCache.shared.forget(name) }
        Database.notifyChanged()
    }

    /// Centre-cropped and downsized, so the sidebar never decodes a 1080px
    /// original for an 18px circle.
    private static func squarePNG(_ image: NSImage, side: CGFloat) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height), s = min(w, h)
        guard let crop = cg.cropping(to: CGRect(x: (w - s) / 2, y: (h - s) / 2, width: s, height: s)) else { return nil }
        let out = min(side, s)
        guard let ctx = CGContext(data: nil, width: Int(out), height: Int(out), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: out, height: out))
        guard let scaled = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:])
    }

    // MARK: Merging

    /// Move every profile of `from` under `into`, and drop the empty account.
    static func merge(_ from: String, into: String) {
        guard from != into else { return }
        try? Database.shared.dbQueue.write { db in
            try db.execute(sql: "UPDATE profile SET accountId = ? WHERE accountId = ?", arguments: [into, from])
            try db.execute(sql: "DELETE FROM account WHERE id = ?", arguments: [from])
        }
        Database.notifyChanged()
    }

    /// Give one profile back an account of its own.
    static func split(profileId: String) {
        try? Database.shared.dbQueue.write { db in
            guard var p = try Profile.fetchOne(db, key: profileId) else { return }
            let others = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM profile WHERE accountId = ?",
                                          arguments: [p.accountId]) ?? 0
            guard others > 1 else { return }
            let account = Account(id: UUID().uuidString, name: p.displayName, createdAt: Date())
            try account.insert(db)
            p.accountId = account.id
            try p.update(db)
        }
        Database.notifyChanged()
    }

    static func rename(_ accountId: String, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        try? Database.shared.dbQueue.write { db in
            try db.execute(sql: "UPDATE account SET name = ? WHERE id = ?", arguments: [n, accountId])
        }
        Database.notifyChanged()
    }

    // MARK: Older items

    /// Items saved before accounts existed still carry their author in the
    /// note ("— @handle" or "— Name (profile)") and the post in pageURL.
    static func backfill(_ db: GRDB.Database) throws {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, note, pageURL FROM item WHERE profileId IS NULL AND note LIKE '%— %'
            """)
        for row in rows {
            let note: String = row["note"] ?? ""
            let page: String? = row["pageURL"]
            guard let info = fromNote(note, pageURL: page) else { continue }
            let id = try upsert(info, db)
            try db.execute(sql: "UPDATE item SET profileId = ? WHERE id = ?", arguments: [id, row["id"] as String])
        }
    }

    static func fromNote(_ note: String, pageURL: String?) -> AccountInfo? {
        guard var platform = Platform.from(host: pageURL.flatMap { URL(string: $0)?.host }) else { return nil }
        if platform == .facebook, pageURL?.contains("/ads/library") == true { platform = .metaAds }
        for line in note.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("— ") else { continue }
            let who = String(t.dropFirst(2))
            if who.hasPrefix("@") {
                let handle = String(who.dropFirst()).components(separatedBy: " ").first ?? ""
                return AccountInfo(platform: platform.rawValue, handle: handle, name: nil, url: nil)
            }
            // "Name (https://…/in/slug/)"
            var name = who, url: String?
            if let open = who.range(of: " (http"), who.hasSuffix(")") {
                name = String(who[..<open.lowerBound])
                url = String(who[who.index(open.lowerBound, offsetBy: 2)..<who.index(before: who.endIndex)])
            }
            let slug = url.flatMap { URL(string: $0)?.path.split(separator: "/").last.map(String.init) }
            return AccountInfo(platform: platform.rawValue, handle: slug ?? name, name: name, url: url)
        }
        return nil
    }
}

/// Decoded profile pictures, small and few, kept for the life of the app.
@MainActor
final class AvatarCache {
    static let shared = AvatarCache()
    private var images: [String: NSImage] = [:]

    func image(_ file: String?) -> NSImage? {
        guard let file else { return nil }
        if let hit = images[file] { return hit }
        guard let img = NSImage(contentsOf: Library.avatarsDir.appendingPathComponent(file)) else { return nil }
        images[file] = img
        return img
    }

    func forget(_ file: String) { images[file] = nil }
}
