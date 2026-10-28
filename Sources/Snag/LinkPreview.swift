import Foundation
import AppKit
import WebKit
import GRDB

/// What a saved page looks like: the picture it chose for itself when shared,
/// its title and blurb, and its icon.
///
/// The share image (og:image, twitter:image) is the page's own idea of its
/// thumbnail, so it wins. A page without one gets a screenshot of itself,
/// taken in an off-screen web view. That same web view is a real browser, so
/// it also gets past the sites that refuse a plain fetch (LinkedIn, Cloudflare).
enum LinkPreview {

    struct Meta {
        var title: String?
        var description: String?
        var imageURL: URL?
        var faviconURL: URL?
    }

    /// Favicons live beside the library, not among the thumbnails: the
    /// thumbnail folder is mirrored to R2 for the phone, which has no use
    /// for them.
    static var faviconsDir: URL { Library.root.appendingPathComponent("favicons") }

    static func faviconURL(for item: Item) -> URL {
        faviconsDir.appendingPathComponent("\(item.id).png")
    }

    /// A browser's user agent. Plenty of sites serve a stripped page, or none,
    /// to URLSession's default one.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    static func request(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml,image/*;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        return req
    }

    // MARK: - Parsing

    /// Read the share metadata out of a page's HTML. Attribute order varies
    /// from site to site, so each tag is read as a set of attributes rather
    /// than matched with one fixed pattern.
    static func parse(html: String, base: URL) -> Meta {
        var meta = [String: String]()
        for tag in tags(named: "meta", in: html) {
            let a = attributes(of: tag)
            guard let key = (a["property"] ?? a["name"] ?? a["itemprop"])?.lowercased(),
                  let content = a["content"], !content.isEmpty, meta[key] == nil else { continue }
            meta[key] = decodeEntities(content).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var icon: URL?
        var iconRank = Int.max
        for tag in tags(named: "link", in: html) {
            let a = attributes(of: tag)
            guard let rel = a["rel"]?.lowercased(), let href = a["href"] else { continue }
            // The large touch icon reads best at card size; any icon beats none.
            let rank = rel.contains("apple-touch-icon") ? 0 : rel.split(separator: " ").contains("icon") ? 1 : Int.max
            if rank < iconRank, let u = URL(string: decodeEntities(href), relativeTo: base)?.absoluteURL {
                icon = u; iconRank = rank
            }
        }

        let titleTag = firstMatch(in: html, pattern: "<title[^>]*>([^<]*)</title>")
            .map { decodeEntities($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let image = ["og:image:secure_url", "og:image", "og:image:url", "twitter:image",
                     "twitter:image:src", "image"]
            .lazy.compactMap { meta[$0] }.first
            .flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }

        return Meta(
            title: nonEmpty(meta["og:title"]) ?? nonEmpty(titleTag) ?? nonEmpty(meta["twitter:title"]),
            description: nonEmpty(meta["og:description"]) ?? nonEmpty(meta["description"])
                ?? nonEmpty(meta["twitter:description"]),
            imageURL: image,
            faviconURL: icon ?? defaultFavicon(base)
        )
    }

    private static func defaultFavicon(_ base: URL) -> URL? {
        guard let scheme = base.scheme, let host = base.host else { return nil }
        return URL(string: "\(scheme)://\(host)/favicon.ico")
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    private static func tags(named name: String, in html: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "<\(name)\\b[^>]*>", options: [.caseInsensitive]) else { return [] }
        return re.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap {
            Range($0.range, in: html).map { String(html[$0]) }
        }
    }

    private static let attrRegex = try? NSRegularExpression(
        pattern: "([a-zA-Z_:-]+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))")

    private static func attributes(of tag: String) -> [String: String] {
        guard let re = attrRegex else { return [:] }
        var out = [String: String]()
        for m in re.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
            guard let k = Range(m.range(at: 1), in: tag) else { continue }
            let value = (2...4).lazy.compactMap { Range(m.range(at: $0), in: tag) }.first.map { String(tag[$0]) } ?? ""
            out[tag[k].lowercased()] = value
        }
        return out
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        for (k, v) in ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&#x27;": "'", "&apos;": "'",
                       "&lt;": "<", "&gt;": ">", "&nbsp;": " ", "&#8217;": "’", "&#8211;": "–",
                       "&#8212;": "—", "&#8220;": "“", "&#8221;": "”", "&hellip;": "…"] {
            out = out.replacingOccurrences(of: k, with: v)
        }
        return out
    }

    // MARK: - Enrichment

    /// Fill in a freshly saved bookmark: thumbnail, title, description, icon.
    /// Runs after the save so the extension and the panel never wait on it.
    /// `html` is the page body when the caller already fetched it.
    static func enrich(itemId: String, html prefetched: String? = nil) async {
        guard let item = try? await Database.shared.dbQueue.read({ db in try Item.fetchOne(db, key: itemId) }),
              item.itemType == .url, let link = item.sourceURL, let url = URL(string: link) else { return }

        var html = prefetched
        if html == nil, let (data, resp) = try? await URLSession.shared.data(for: request(url)),
           ((resp as? HTTPURLResponse)?.statusCode ?? 200) < 400 {
            html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        }
        let finalBase = url
        var meta = html.map { parse(html: $0, base: finalBase) } ?? Meta()

        let hasThumb = FileManager.default.fileExists(atPath: Library.thumbURL(for: item).path)
        var thumb: NSImage?
        if !hasThumb, let imageURL = meta.imageURL { thumb = await downloadImage(imageURL) }

        // No share image, or the page would not talk to a plain fetch: render
        // it. The rendered DOM also answers the metadata questions.
        if !hasThumb, thumb == nil {
            let shot = await PageSnapshotter.capture(url)
            if let m = shot.meta {
                meta.title = meta.title ?? m.title
                meta.description = meta.description ?? m.description
                meta.faviconURL = meta.faviconURL ?? m.faviconURL
                if let img = m.imageURL { thumb = await downloadImage(img) }
            }
            thumb = thumb ?? shot.image
        }

        if let iconURL = meta.faviconURL, let icon = await downloadImage(iconURL, minSide: 1) {
            try? FileManager.default.createDirectory(at: faviconsDir, withIntermediateDirectories: true)
            Library.writePNG(icon, to: faviconURL(for: item))
        }

        var colors: String?
        if let thumb {
            let sized = downscale(thumb, maxWidth: 1600)
            Library.writePNG(sized, to: Library.thumbURL(for: item))
            colors = Library.paletteJSON(from: sized)
        }

        // Only fill what the save left blank: a name or note the user typed
        // in the meantime stays.
        let title = meta.title, newColors = colors
        let desc = meta.description.map { String($0.prefix(600)) }
        try? await Database.shared.dbQueue.write { db in
            guard var it = try Item.fetchOne(db, key: itemId) else { return }
            if let title, !title.isEmpty, it.name == link || it.name.isEmpty { it.name = title }
            if let desc, !desc.isEmpty, it.note.isEmpty { it.note = desc }
            if let newColors { it.colors = newColors }
            it.modifiedAt = Date()
            try it.update(db)
        }
        Database.notifyChanged()
    }

    /// Bookmarks saved before this existed have no picture. Give each one a
    /// single try, oldest first, one at a time.
    static func backfillOnce() {
        Task.detached(priority: .background) {
            let key = "snag.linkPreview.backfilled"
            var tried = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
            let items = (try? await Database.shared.dbQueue.read { db in
                try Item.filter(Column("type") == ItemType.url.rawValue)
                    .filter(Column("deletedAt") == nil)
                    .order(Column("createdAt")).fetchAll(db)
            }) ?? []
            for item in items where !tried.contains(item.id) {
                let fm = FileManager.default
                if fm.fileExists(atPath: Library.thumbURL(for: item).path),
                   fm.fileExists(atPath: faviconURL(for: item).path) { continue }
                await enrich(itemId: item.id)
                tried.insert(item.id)
                UserDefaults.standard.set(Array(tried), forKey: key)
            }
        }
    }

    private static func downloadImage(_ url: URL, minSide: CGFloat = 64) async -> NSImage? {
        guard let (data, resp) = try? await URLSession.shared.data(for: request(url)),
              ((resp as? HTTPURLResponse)?.statusCode ?? 200) < 400,
              let img = NSImage(data: data) else { return nil }
        // Tracking pixels and spacer GIFs are not thumbnails.
        let px = img.representations.first.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? img.size
        return min(px.width, px.height) >= minSide ? img : nil
    }

    static func downscale(_ image: NSImage, maxWidth: CGFloat) -> NSImage {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              CGFloat(cg.width) > maxWidth else { return image }
        let h = (CGFloat(cg.height) * maxWidth / CGFloat(cg.width)).rounded()
        guard let ctx = CGContext(data: nil, width: Int(maxWidth), height: Int(h), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: maxWidth, height: h))
        guard let out = ctx.makeImage() else { return image }
        return NSImage(cgImage: out, size: NSSize(width: maxWidth, height: h))
    }
}

/// Renders a page off screen and photographs it. One page at a time: each
/// render is a whole browser tab's worth of memory.
@MainActor
final class PageSnapshotter: NSObject, WKNavigationDelegate {

    struct Shot { var image: NSImage?; var meta: LinkPreview.Meta? }

    private static var queue: Task<Void, Never>?

    static func capture(_ url: URL, timeout: TimeInterval = 20) async -> Shot {
        let previous = queue
        let task = Task { () -> Shot in
            await previous?.value
            return await PageSnapshotter().run(url, timeout: timeout)
        }
        queue = Task { _ = await task.value }
        return await task.value
    }

    private var finished: CheckedContinuation<Void, Never>?
    private var done = false

    private func run(_ url: URL, timeout: TimeInterval) async -> Shot {
        let size = NSSize(width: 1280, height: 800)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = .all
        let web = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: config)
        web.customUserAgent = LinkPreview.userAgent
        web.navigationDelegate = self

        // WebKit stops painting a view that is in no window, so the page gets
        // one, far off every screen, that never takes focus or a click.
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.contentView = web
        window.orderFrontRegardless()
        defer {
            web.stopLoading()
            web.navigationDelegate = nil
            window.orderOut(nil)
            window.contentView = nil
        }

        web.load(LinkPreview.request(url))
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                await withCheckedContinuation { cont in
                    if self.done { cont.resume() } else { self.finished = cont }
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            }
            await group.next()
            group.cancelAll()
            self.resolve()
        }
        // Fonts, hero images, and cookie banners settle after "finished".
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        let meta = await readMeta(web, base: url)
        let snap = WKSnapshotConfiguration()
        snap.rect = NSRect(origin: .zero, size: size)
        let image = try? await web.takeSnapshot(configuration: snap)
        return Shot(image: image.flatMap(Self.blankCheck), meta: meta)
    }

    private func resolve() {
        done = true
        finished?.resume()
        finished = nil
    }

    /// A white rectangle is what a page that never painted looks like.
    private static func blankCheck(_ image: NSImage) -> NSImage? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return image }
        let w = rep.pixelsWide, h = rep.pixelsHigh
        guard w > 0, h > 0, let first = rep.colorAt(x: 0, y: 0) else { return image }
        for y in stride(from: 0, to: h, by: 16) {
            for x in stride(from: 0, to: w, by: 16) {
                if let c = rep.colorAt(x: x, y: y), c != first { return image }
            }
        }
        return nil
    }

    private func readMeta(_ web: WKWebView, base: URL) async -> LinkPreview.Meta? {
        guard let html = try? await web.evaluateJavaScript("document.documentElement.outerHTML") as? String
        else { return nil }
        return LinkPreview.parse(html: html, base: web.url ?? base)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.resolve() }
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.resolve() }
    }
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                             withError error: Error) {
        Task { @MainActor in self.resolve() }
    }
}
