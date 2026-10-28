import Foundation
import AppKit
import AVFoundation
import CryptoKit
import QuickLookThumbnailing
import GRDB
import UniformTypeIdentifiers

enum ImportResult {
    case imported(Item)
    case duplicate(Item)

    var item: Item {
        switch self {
        case .imported(let i): return i
        case .duplicate(let i): return i
        }
    }
    var isDuplicate: Bool { if case .duplicate = self { return true }; return false }
}

enum Library {
    static let root = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Snag")
    static var filesDir: URL { root.appendingPathComponent("files") }
    static var thumbsDir: URL { root.appendingPathComponent("thumbnails") }

    static let imageExts: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "svg", "heic", "heif", "tiff", "bmp", "avif"]
    static let videoExts: Set<String> = ["mp4", "mov", "webm", "m4v", "mpg", "mpeg", "avi"]

    static func bootstrap() {
        try? FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: thumbsDir, withIntermediateDirectories: true)
    }

    static func fileURL(for item: Item) -> URL {
        filesDir.appendingPathComponent("\(item.id).\(item.ext)")
    }
    static func thumbURL(for item: Item) -> URL {
        thumbsDir.appendingPathComponent("\(item.id).png")
    }

    // MARK: - Import

    /// Import a local file (copies it; the original stays where it was).
    static func importFile(at src: URL, folderId: String?, sourceURL: String? = nil, pageURL: String? = nil) throws -> ImportResult {
        let data = try Data(contentsOf: src)
        let ext = src.pathExtension.lowercased().isEmpty ? "bin" : src.pathExtension.lowercased()
        let name = src.deletingPathExtension().lastPathComponent
        return try importData(data, ext: ext, name: name, folderId: folderId, sourceURL: sourceURL, pageURL: pageURL)
    }

    /// Identify media by magic bytes when the extension lies or is missing.
    static func sniffExt(_ data: Data) -> String? {
        guard data.count > 12 else { return nil }
        let b = [UInt8](data.prefix(16))
        if b[0] == 0xFF, b[1] == 0xD8 { return "jpg" }
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "png" }
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return "gif" }
        if b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return "webp" }
        if b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 { return "mp4" }
        if b[0] == 0x1A, b[1] == 0x45, b[2] == 0xDF, b[3] == 0xA3 { return "webm" }
        return nil
    }

    /// Import raw bytes (drag of image data, or a downloaded file).
    static func importData(_ data: Data, ext rawExt: String, name: String, folderId: String?,
                           sourceURL: String? = nil, pageURL: String? = nil) throws -> ImportResult {
        var ext = rawExt
        if ext.isEmpty || ext == "bin" || (!imageExts.contains(ext) && !videoExts.contains(ext)) {
            if let sniffed = sniffExt(data) { ext = sniffed }
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        if let existing = try Database.shared.dbQueue.read({ db in
            try Item.filter(Column("hash") == hash).filter(Column("deletedAt") == nil).fetchOne(db)
        }) {
            return .duplicate(existing)
        }

        let type: ItemType = imageExts.contains(ext) ? .image : (videoExts.contains(ext) ? .video : .image)
        var item = Item(
            id: UUID().uuidString, name: name, type: type.rawValue, ext: ext, folderId: folderId,
            sizeBytes: Int64(data.count), width: 0, height: 0,
            sourceURL: sourceURL, pageURL: pageURL, note: "", colors: "[]",
            hash: hash, rating: 0, createdAt: Date(), modifiedAt: Date(), deletedAt: nil,
            sortIndex: nextTopIndex()
        )

        let dest = filesDir.appendingPathComponent("\(item.id).\(ext)")
        try data.write(to: dest)

        // Dimensions
        if type == .image, let src = CGImageSourceCreateWithURL(dest as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            item.width = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
            item.height = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        } else if type == .video {
            let asset = AVURLAsset(url: dest)
            if let track = asset.tracks(withMediaType: .video).first {
                let size = track.naturalSize.applying(track.preferredTransform)
                item.width = Int(abs(size.width)); item.height = Int(abs(size.height))
            }
        }

        // Thumbnail + palette
        if let thumb = generateThumbnail(for: dest) {
            writePNG(thumb, to: thumbsDir.appendingPathComponent("\(item.id).png"))
            item.colors = paletteJSON(from: thumb)
        }

        // The duplicate check above runs before the slow work (file write,
        // thumbnail), so two imports of the same bytes could both pass it and
        // land as two items. Check again inside the insert's own transaction;
        // writes are serialized, so exactly one wins and the other cleans up.
        var duplicateOf: Item? = nil
        do {
            try Database.shared.dbQueue.write { db in
                if let existing = try Item.filter(Column("hash") == hash)
                    .filter(Column("deletedAt") == nil).fetchOne(db) {
                    duplicateOf = existing
                    return
                }
                // A folder deleted meanwhile, or a stale id from the phone or
                // MCP, would leave the item visible in no folder at all.
                if let f = item.folderId, try !Folder.exists(db, key: f) { item.folderId = nil }
                try item.insert(db)
            }
        } catch {
            removeStoredFiles(of: item)
            throw error
        }
        if let duplicateOf {
            removeStoredFiles(of: item)
            return .duplicate(duplicateOf)
        }
        touchRecentFolder(item.folderId)
        Database.notifyChanged()
        return .imported(item)
    }

    /// Files written for an item that never made it into the database.
    private static func removeStoredFiles(of item: Item) {
        try? FileManager.default.removeItem(at: fileURL(for: item))
        try? FileManager.default.removeItem(at: thumbURL(for: item))
    }

    /// Save a URL bookmark item (a link card).
    static func importBookmark(url: String, title: String?, folderId: String?, previewData: Data? = nil) throws -> ImportResult {
        let hash = SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
        if let existing = try Database.shared.dbQueue.read({ db in
            try Item.filter(Column("hash") == hash).filter(Column("deletedAt") == nil).fetchOne(db)
        }) {
            return .duplicate(existing)
        }
        var item = Item(
            id: UUID().uuidString, name: title ?? url, type: ItemType.url.rawValue, ext: "url",
            folderId: folderId, sizeBytes: Int64(url.utf8.count), width: 0, height: 0,
            sourceURL: url, pageURL: url, note: "", colors: "[]",
            hash: hash, rating: 0, createdAt: Date(), modifiedAt: Date(), deletedAt: nil,
            sortIndex: nextTopIndex()
        )
        try url.data(using: .utf8)!.write(to: filesDir.appendingPathComponent("\(item.id).url"))
        if let previewData, let img = NSImage(data: previewData) {
            writePNG(img, to: thumbsDir.appendingPathComponent("\(item.id).png"))
            item.colors = paletteJSON(from: img)
        }
        // Same race and stale-folder guards as importData.
        var duplicateOf: Item? = nil
        do {
            try Database.shared.dbQueue.write { db in
                if let existing = try Item.filter(Column("hash") == hash)
                    .filter(Column("deletedAt") == nil).fetchOne(db) {
                    duplicateOf = existing
                    return
                }
                if let f = item.folderId, try !Folder.exists(db, key: f) { item.folderId = nil }
                try item.insert(db)
            }
        } catch {
            removeStoredFiles(of: item)
            throw error
        }
        if let duplicateOf {
            removeStoredFiles(of: item)
            return .duplicate(duplicateOf)
        }
        touchRecentFolder(item.folderId)
        Database.notifyChanged()
        return .imported(item)
    }

    /// Download a remote file URL and import it. For non-file pages, saves a bookmark.
    static func importRemote(urlString: String, pageURL: String?, folderId: String?) async throws -> ImportResult {
        guard let url = URL(string: urlString) else { throw NSError(domain: "Snag", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bad URL"]) }
        let looksLikeMedia = imageExts.contains(url.pathExtension.lowercased())
            || videoExts.contains(url.pathExtension.lowercased())
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(from: url)
        } catch {
            // Offline or unreachable. A page link is still worth keeping as a
            // bookmark; a media file we could not fetch is a real failure.
            if !looksLikeMedia {
                return try importBookmark(url: urlString, title: nil, folderId: folderId, previewData: nil)
            }
            throw error
        }
        if let status = (response as? HTTPURLResponse)?.statusCode, status >= 400 {
            // Sites that refuse non-browsers (LinkedIn's 999, Cloudflare's 403)
            // used to save nothing at all. A bookmark needs no page body.
            if !looksLikeMedia {
                return try importBookmark(url: urlString, title: nil, folderId: folderId, previewData: nil)
            }
            throw NSError(domain: "Snag", code: status,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(status) for \(urlString)"])
        }
        let mime = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""

        var ext = url.pathExtension.lowercased()
        if ext.isEmpty || (!imageExts.contains(ext) && !videoExts.contains(ext)) {
            if let ut = UTType(mimeType: mime.components(separatedBy: ";")[0].trimmingCharacters(in: .whitespaces)),
               let preferred = ut.preferredFilenameExtension {
                ext = preferred
            }
        }

        if imageExts.contains(ext) || videoExts.contains(ext) {
            var name = url.deletingPathExtension().lastPathComponent
            if name.isEmpty || name == "/" { name = url.host ?? "download" }
            return try importData(data, ext: ext, name: name, folderId: folderId, sourceURL: urlString, pageURL: pageURL)
        }

        // CDN and S3 links often carry no extension and a generic type
        // (application/octet-stream). Read the bytes before calling it a page,
        // or the image or video is thrown away and only a link is kept.
        if let sniffed = sniffExt(data) {
            var name = url.lastPathComponent
            if name.isEmpty || name == "/" { name = url.host ?? "download" }
            return try importData(data, ext: sniffed, name: name, folderId: folderId,
                                  sourceURL: urlString, pageURL: pageURL)
        }

        // Not a media file: treat as a page bookmark.
        let html = String(data: data, encoding: .utf8) ?? ""
        let title = firstMatch(in: html, pattern: "<title[^>]*>([^<]*)</title>")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var preview: Data? = nil
        if let og = firstMatch(in: html, pattern: "property=[\"']og:image[\"'][^>]*content=[\"']([^\"']+)[\"']")
            ?? firstMatch(in: html, pattern: "content=[\"']([^\"']+)[\"'][^>]*property=[\"']og:image[\"']"),
           let ogURL = URL(string: og, relativeTo: url) {
            preview = try? await URLSession.shared.data(from: ogURL.absoluteURL).0
        }
        return try importBookmark(url: urlString, title: title, folderId: folderId, previewData: preview)
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    /// Track which folders receive saves, for the panel's Recent section.
    static func touchRecentFolder(_ id: String?) {
        guard let id else { return }
        var arr = UserDefaults.standard.stringArray(forKey: "snag.recentFolders") ?? []
        arr.removeAll { $0 == id }
        arr.insert(id, at: 0)
        UserDefaults.standard.set(Array(arr.prefix(8)), forKey: "snag.recentFolders")
    }

    /// New items land at the top of the custom order.
    static func nextTopIndex() -> Double {
        let current: Double? = try? Database.shared.dbQueue.read { db in
            try Double.fetchOne(db, sql: "SELECT MIN(sortIndex) FROM item")
        }
        return (current ?? 0) - 1024
    }

    // MARK: - Thumbnails

    static func generateThumbnail(for fileURL: URL) -> NSImage? {
        if videoExts.contains(fileURL.pathExtension.lowercased()),
           let frame = bestVideoFrame(fileURL) {
            return frame
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: fileURL, size: CGSize(width: 512, height: 512),
            scale: 2.0, representationTypes: .thumbnail
        )
        var result: NSImage? = nil
        let sem = DispatchSemaphore(value: 0)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            if let rep { result = rep.nsImage }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 10)
        if result == nil { result = NSImage(contentsOf: fileURL) } // fallback
        return result
    }

    /// The most telling frame of a video. Quick Look takes the first frame,
    /// and videos often open on a fade, a blank card or a flat colour, so the
    /// grid showed plain grey. Sample across the clip and keep the frame with
    /// the most detail, avoiding near-black and near-white ones.
    static func bestVideoFrame(_ url: URL) -> NSImage? {
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)
        guard seconds.isFinite, seconds > 0 else { return nil }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1024, height: 1024)
        let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = tolerance
        gen.requestedTimeToleranceAfter = tolerance

        var best: (score: Double, image: CGImage)?
        for fraction in [0.12, 0.25, 0.4, 0.55, 0.7, 0.85] {
            let t = CMTime(seconds: max(0.3, seconds * fraction), preferredTimescale: 600)
            guard let cg = try? gen.copyCGImage(at: t, actualTime: nil) else { continue }
            let score = frameDetail(cg)
            if best == nil || score > best!.score { best = (score, cg) }
        }
        guard let pick = best?.image else { return nil }
        return NSImage(cgImage: pick, size: NSSize(width: pick.width, height: pick.height))
    }

    /// How much is going on in a frame: luminance spread plus edges, on a
    /// 48 px copy, with very dark or very bright frames marked down.
    private static func frameDetail(_ image: CGImage) -> Double {
        let n = 48
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        guard let data = ctx.data else { return 0 }
        let px = data.bindMemory(to: UInt8.self, capacity: n * n)
        var sum = 0.0, sumSq = 0.0, edges = 0.0
        for y in 0..<n {
            for x in 0..<n {
                let v = Double(px[y * n + x])
                sum += v; sumSq += v * v
                if x + 1 < n { edges += abs(v - Double(px[y * n + x + 1])) }
                if y + 1 < n { edges += abs(v - Double(px[(y + 1) * n + x])) }
            }
        }
        let count = Double(n * n)
        let mean = sum / count
        let spread = (sumSq / count - mean * mean).squareRoot()
        var score = spread + edges / count
        if mean < 28 || mean > 235 { score *= 0.3 }
        return score
    }

    /// Redo the thumbnails of videos saved before frames were chosen this
    /// way. Runs once, in the background, after launch.
    static func refreshVideoThumbnailsOnce() {
        let key = "snag.videoThumbs.v2"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        DispatchQueue.global(qos: .utility).async {
            let videos = (try? Database.shared.dbQueue.read { db in
                try Item.filter(Column("type") == ItemType.video.rawValue)
                    .filter(Column("deletedAt") == nil).fetchAll(db)
            }) ?? []
            var changed = 0
            for item in videos {
                let file = fileURL(for: item)
                guard FileManager.default.fileExists(atPath: file.path),
                      let frame = bestVideoFrame(file) else { continue }
                writePNG(frame, to: thumbsDir.appendingPathComponent("\(item.id).png"))
                let colors = paletteJSON(from: frame)
                try? Database.shared.dbQueue.write { db in
                    try db.execute(sql: "UPDATE item SET colors = ?, modifiedAt = ? WHERE id = ?",
                                   arguments: [colors, Date(), item.id])
                }
                changed += 1
            }
            UserDefaults.standard.set(true, forKey: key)
            if changed > 0 { Database.notifyChanged() }
        }
    }

    static func writePNG(_ image: NSImage, to url: URL) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    // MARK: - Palette

    static func paletteJSON(from image: NSImage) -> String {
        let colors = dominantColors(in: image, count: 6)
        let hex = colors.map { c -> String in
            String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
        }
        let data = (try? JSONEncoder().encode(hex)) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    static func dominantColors(in image: NSImage, count: Int) -> [NSColor] {
        let size = 32
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let ptr = ctx.data else { return [] }
        let buf = ptr.bindMemory(to: UInt8.self, capacity: size * size * 4)

        var buckets: [Int: (count: Int, r: Int, g: Int, b: Int)] = [:]
        for i in 0..<(size * size) {
            let r = Int(buf[i * 4]), g = Int(buf[i * 4 + 1]), b = Int(buf[i * 4 + 2]), a = Int(buf[i * 4 + 3])
            if a < 128 { continue }
            let key = (r >> 5) << 6 | (g >> 5) << 3 | (b >> 5)
            var e = buckets[key] ?? (0, 0, 0, 0)
            e.count += 1; e.r += r; e.g += g; e.b += b
            buckets[key] = e
        }
        return buckets.values.sorted { $0.count > $1.count }.prefix(count).map { e in
            NSColor(red: CGFloat(e.r) / CGFloat(e.count) / 255.0,
                    green: CGFloat(e.g) / CGFloat(e.count) / 255.0,
                    blue: CGFloat(e.b) / CGFloat(e.count) / 255.0, alpha: 1)
        }
    }
}


/// Exporting originals out of the library. The panels run modally (a
/// non-modal panel from an inactive app never comes forward, which read as
/// "export does nothing"), and the copying runs off the main thread: copying
/// gigabytes of video to an external drive used to freeze the window.
enum Exporter {
    static func exportOne(_ item: Item) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(safeName(item)).\(item.ext)"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let src = Library.fileURL(for: item)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // The panel already asked about replacing; copyItem refuses to
                // overwrite, so remove the old file first.
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: src, to: dest)
            } catch {
                DispatchQueue.main.async { NSAlert(error: error).runModal() }
            }
        }
    }

    static func exportMany(_ items: [Item]) {
        guard !items.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            var failed = 0
            for it in items {
                let base = safeName(it)
                var dest = dir.appendingPathComponent("\(base).\(it.ext)")
                var n = 2
                while FileManager.default.fileExists(atPath: dest.path) {
                    dest = dir.appendingPathComponent("\(base) \(n).\(it.ext)")
                    n += 1
                }
                do { try FileManager.default.copyItem(at: Library.fileURL(for: it), to: dest) }
                catch { failed += 1 }
            }
            guard failed > 0 else { return }
            DispatchQueue.main.async {
                let a = NSAlert()
                a.messageText = "\(failed) of \(items.count) items could not be exported."
                a.informativeText = "Their files may be missing from the library folder, or the destination is full."
                a.runModal()
            }
        }
    }

    private static func safeName(_ item: Item) -> String {
        item.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }
}
