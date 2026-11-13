import Foundation

/// Pulling real media out of a shared link.
///
/// A link shared from the phone is a post, not a file. yt-dlp knows how to
/// turn one into a video. When it cannot — the site wants a login, the format
/// is gone, the tool is missing — the caller keeps the link as a bookmark, so
/// a save is never lost.
enum LinkMedia {

    enum Failure: LocalizedError {
        case notInstalled, timedOut, nothingDownloaded, toolFailed(Int, String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:      return "yt-dlp is not installed"
            case .timedOut:          return "the download took too long"
            case .nothingDownloaded: return "nothing landed on disk"
            case .toolFailed(let code, let detail):
                return "yt-dlp exited \(code): \(detail)"
            }
        }
    }

    /// Hosts worth handing to yt-dlp. Everything else stays a bookmark, so a
    /// shared article never pays for a subprocess.
    private static let hosts: Set<String> = [
        "instagram.com", "tiktok.com", "youtube.com", "youtu.be", "vimeo.com",
        "x.com", "twitter.com", "reddit.com", "facebook.com", "threads.net",
        "threads.com", "pinterest.com", "linkedin.com",
    ]

    /// A link that points straight at a video file is worth fetching wherever
    /// it is hosted, not only on the sites above.
    private static let directVideoExts: Set<String> = ["mp4", "mov", "m4v", "webm"]

    static func handles(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString), let host = url.host?.lowercased() else { return false }
        if directVideoExts.contains(url.pathExtension.lowercased()) { return true }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return hosts.contains(bare) || hosts.contains { bare.hasSuffix("." + $0) }
    }

    /// A GUI app does not inherit a login shell's PATH, so the tool has to be
    /// found by hand.
    private static let binDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]

    static var toolPath: String? {
        binDirs.map { $0 + "/yt-dlp" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Which browser to borrow cookies from, or nil for none.
    ///
    /// Instagram will not serve a reel to a signed-out client, so for that site
    /// this setting is the whole difference between a video and a bookmark. It
    /// is off until the user picks a browser in Settings, because reading a
    /// browser's cookie jar is not something to switch on for someone.
    static var cookieBrowser: String? {
        let value = UserDefaults.standard.string(forKey: Keys.cookieBrowser) ?? ""
        return value.isEmpty ? nil : value
    }

    /// An exported cookies.txt, for browsers yt-dlp cannot read itself.
    ///
    /// Arc is the reason this exists. It is Chromium underneath, but it seals
    /// its cookies with a Keychain key named for itself, and yt-dlp only knows
    /// the names of the browsers it ships support for. Pointing it at Arc's
    /// database gets "cannot decrypt v10 cookies: no key found". Exporting the
    /// cookies once sidesteps the Keychain entirely.
    static var cookieFile: String? {
        let raw = (UserDefaults.standard.string(forKey: Keys.cookieFile) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let path = (raw as NSString).expandingTildeInPath
        return FileManager.default.isReadableFile(atPath: path) ? path : nil
    }

    enum Keys {
        static let cookieBrowser = "snag.linkCookieBrowser"
        static let cookieFile = "snag.linkCookieFile"
    }

    struct Fetched {
        let fileURL: URL
        let title: String?
        /// Caption, account and link, for the item's note.
        let note: String?
        /// Who posted it, for the item's account.
        let account: AccountInfo?
        /// Temporary directory holding the download. The caller deletes it.
        let dir: URL
    }

    /// YouTube's only single-file mp4 is 360p, so take its separate H.264
    /// video (up to 1080p) and AAC audio and let ffmpeg join them. H.264,
    /// not VP9: AVPlayer will not play VP9.
    private static func format(for urlString: String) -> String {
        if LinkPreview.youTubeID(urlString) != nil {
            return "bv*[vcodec^=avc1][height<=1080]+ba[ext=m4a]/b[ext=mp4]/bv*+ba/b"
        }
        return "b[ext=mp4]/bv*+ba/b"
    }

    /// Download whatever the link points at, into a fresh temporary directory.
    static func download(_ urlString: String, timeout: TimeInterval = 180) async throws -> Fetched {
        guard let tool = toolPath else { throw Failure.notInstalled }

        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("snag-link-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        var args = [
            "--no-warnings", "--no-playlist", "--no-progress", "--write-info-json",
            // A phone save should not be able to drag a feature film into the
            // library, and the import path holds the file in memory.
            "--max-filesize", "200M",
            "-f", format(for: urlString),
            "--merge-output-format", "mp4",
            "-o", "%(id)s.%(ext)s",
        ]
        // An explicit file wins: it is the only option that works for a
        // browser yt-dlp cannot decrypt on its own.
        if let file = cookieFile {
            args += ["--cookies", file]
        } else if let browser = cookieBrowser {
            args += ["--cookies-from-browser", browser]
        }
        args.append(urlString)

        let log: String
        do {
            log = try run(tool, args: args, cwd: dir, timeout: timeout)
        } catch {
            // A refused or timed-out download used to leave its folder (and
            // up to 200 MB of .part files) in the temp directory for good.
            try? fm.removeItem(at: dir)
            throw error
        }

        let all = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []

        var title: String?
        var note: String?
        var account: AccountInfo?
        if let info = all.first(where: { $0.lastPathComponent.hasSuffix(".info.json") }),
           let data = try? Data(contentsOf: info),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            title = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            note = Self.note(from: obj, link: urlString)
            account = AccountInfo.from(ytdlp: obj, link: urlString)
        }

        let skip = [".json", ".log", ".part", ".ytdl"]
        guard let media = all.first(where: { url in
            !skip.contains { url.lastPathComponent.hasSuffix($0) }
        }) else {
            try? fm.removeItem(at: dir)
            throw Failure.toolFailed(0, log)
        }
        return Fetched(fileURL: media, title: title, note: note, account: account, dir: dir)
    }

    /// The pictures in a post that has no video: an Instagram photo, or every
    /// slide of a carousel. yt-dlp refuses to "download" these, but with
    /// formats errors ignored it still describes each slide, and the largest
    /// thumbnail it lists is the original image (1440 px on Instagram).
    static func postImages(_ urlString: String, timeout: TimeInterval = 90) async throws
        -> (title: String?, urls: [URL], note: String?, account: AccountInfo?) {
        guard let tool = toolPath else { throw Failure.notInstalled }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("snag-post-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        var args = ["--no-warnings", "--no-progress", "--skip-download",
                    "--ignore-no-formats-error", "--write-info-json", "-o", "%(id)s.%(ext)s"]
        if let file = cookieFile {
            args += ["--cookies", file]
        } else if let browser = cookieBrowser {
            args += ["--cookies-from-browser", browser]
        }
        args.append(urlString)
        try run(tool, args: args, cwd: dir, timeout: timeout)

        var title: String?
        var note: String?
        var account: AccountInfo?
        var slides: [(index: Int, url: URL)] = []
        let infos = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasSuffix(".info.json") }
        for info in infos {
            guard let data = try? Data(contentsOf: info),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            if title == nil { title = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            // The post's own caption, from whichever file has it (a carousel's
            // slides each repeat it, or only the post-level file does).
            if note == nil { note = Self.note(from: obj, link: urlString) }
            if account == nil { account = AccountInfo.from(ytdlp: obj, link: urlString) }
            if (obj["_type"] as? String) == "playlist" { continue }
            // A slide with a playable format is a video; the download path
            // already had its chance at those.
            if let formats = obj["formats"] as? [Any], !formats.isEmpty { continue }
            let thumbs = (obj["thumbnails"] as? [[String: Any]]) ?? []
            let best = thumbs.max { a, b in
                ((a["width"] as? Int) ?? 0) * ((a["height"] as? Int) ?? 0)
                    < ((b["width"] as? Int) ?? 0) * ((b["height"] as? Int) ?? 0)
            }
            if let raw = best?["url"] as? String, let url = URL(string: raw) {
                slides.append(((obj["playlist_index"] as? Int) ?? 0, url))
            }
        }
        return (title, slides.sorted { $0.index < $1.index }.map(\.url), note, account)
    }

    /// "Caption\n\n— @account\n\nlink", the same shape the browser extension
    /// writes, from a yt-dlp info file. Nil when the post says nothing.
    static func note(from info: [String: Any], link: String) -> String? {
        func clean(_ key: String) -> String {
            ((info[key] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let caption = clean("description")
        // A username beats a display name; Instagram puts it in `channel`,
        // X and TikTok in `uploader_id`.
        let handle = [clean("channel"), clean("uploader_id")].first {
            !$0.isEmpty && !$0.contains(" ") && !$0.allSatisfy(\.isNumber)
        }
        let display = clean("uploader")
        let account = handle.map { "— @\($0)" } ?? (display.isEmpty ? "" : "— \(display)")
        let page = clean("webpage_url").isEmpty ? link : clean("webpage_url")
        guard !caption.isEmpty || !account.isEmpty else { return nil }
        return [caption, account, page].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Give a freshly saved item its post's note. Never replaces one that is
    /// already there: re-saving must not undo a note written since.
    static func fillNote(_ result: ImportResult, _ note: String?) {
        guard let note, !note.isEmpty else { return }
        try? Database.shared.dbQueue.write { db in
            try db.execute(sql: "UPDATE item SET note = ? WHERE id = ? AND note = ''",
                           arguments: [note, result.item.id])
        }
        Database.notifyChanged()
    }

    /// Save every picture of a photo post. Returns the first saved item, or
    /// nil when the post had no pictures to offer.
    static func importPostImages(_ link: String, fallbackName: String,
                                 folderId: String?) async -> ImportResult? {
        guard let post = try? await postImages(link), !post.urls.isEmpty else { return nil }
        // yt-dlp titles every Instagram post "Video by <user>", photos too.
        var base = (post.title?.isEmpty == false ? post.title! : fallbackName)
        if base.hasPrefix("Video by ") { base = "Post by " + base.dropFirst("Video by ".count) }
        var first: ImportResult?
        // Several pictures are one carousel: keep them together as a group.
        let groupId = post.urls.count > 1 ? UUID().uuidString : nil
        for (n, url) in post.urls.enumerated() {
            guard let (data, resp) = try? await URLSession.shared.data(from: url),
                  (resp as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { continue }
            let ext = url.pathExtension.lowercased()
            let name = post.urls.count > 1 ? "\(base) (\(n + 1))" : base
            if let result = try? Library.importData(
                data, ext: Library.imageExts.contains(ext) ? ext : "jpg", name: name,
                folderId: folderId, sourceURL: link, pageURL: link) {
                fillNote(result, post.note)
                Accounts.attach(post.account, toItem: result.item.id)
                if let groupId { Library.joinGroup(result.item.id, groupId: groupId, index: n) }
                first = first ?? result
            }
        }
        return first
    }

    /// Run the tool, sending its chatter to a file rather than a pipe: a full
    /// pipe buffer would wedge the child until the timeout killed it. Returns
    /// the tail of that log, which carries the reason for any refusal.
    @discardableResult
    private static func run(_ tool: String, args: [String], cwd: URL,
                            timeout: TimeInterval) throws -> String {
        let logURL = cwd.appendingPathComponent("yt-dlp.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tool)
        proc.arguments = args
        proc.currentDirectoryURL = cwd
        proc.standardOutput = handle
        proc.standardError = handle

        // yt-dlp shells out to ffmpeg, which it will not find otherwise.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (binDirs + ["/usr/bin", "/bin"]).joined(separator: ":")
        proc.environment = env

        try proc.run()

        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        if proc.isRunning {
            // yt-dlp hands merging to an ffmpeg child, which outlives a plain
            // terminate() and keeps writing. Stop the children first.
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            kill.arguments = ["-TERM", "-P", String(proc.processIdentifier)]
            try? kill.run()
            kill.waitUntilExit()
            proc.terminate()
            proc.waitUntilExit()
            throw Failure.timedOut
        }

        let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        let tail = text.split(separator: "\n").suffix(2).joined(separator: " ")
        guard proc.terminationStatus == 0 else {
            throw Failure.toolFailed(Int(proc.terminationStatus), String(tail.prefix(300)))
        }
        return String(tail.prefix(300))
    }
}
