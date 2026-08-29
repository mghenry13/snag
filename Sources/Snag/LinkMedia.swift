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
        "threads.com", "pinterest.com",
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
        /// Temporary directory holding the download. The caller deletes it.
        let dir: URL
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
            "-f", "b[ext=mp4]/bv*+ba/b",
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

        let log = try run(tool, args: args, cwd: dir, timeout: timeout)

        let all = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []

        var title: String?
        if let info = all.first(where: { $0.lastPathComponent.hasSuffix(".info.json") }),
           let data = try? Data(contentsOf: info),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            title = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let skip = [".json", ".log", ".part", ".ytdl"]
        guard let media = all.first(where: { url in
            !skip.contains { url.lastPathComponent.hasSuffix($0) }
        }) else {
            try? fm.removeItem(at: dir)
            throw Failure.toolFailed(0, log)
        }
        return Fetched(fileURL: media, title: title, dir: dir)
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
            proc.terminate()
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
