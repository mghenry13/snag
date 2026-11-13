import SwiftUI
import AppKit
import AVFoundation
import QuickLookThumbnailing
import CryptoKit
import UniformTypeIdentifiers

// MARK: - Files on disk, shown in Snag's grid without importing them

/// Any folder on disk (Desktop, Downloads, Google Drive…) browsed in the
/// grid. Its pictures and videos become `Item`s that live only in memory:
/// their id is `file:` + the path, so the grid, hover-scrub and preview work
/// on them unchanged, and nothing is written to the library.
enum ExternalFiles {
    static let prefix = "file:"

    static func isExternal(_ id: String) -> Bool { id.hasPrefix(prefix) }
    static func id(for url: URL) -> String { prefix + url.path }
    static func url(_ id: String) -> URL { URL(fileURLWithPath: String(id.dropFirst(prefix.count))) }

    static let thumbsDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Snag/FileThumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func thumbURL(for item: Item) -> URL {
        let key = "\(item.id)|\(Int(item.modifiedAt.timeIntervalSince1970))"
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return thumbsDir.appendingPathComponent(String(digest.prefix(32)) + ".png")
    }

    // MARK: Cloud placeholders

    private static let lock = NSLock()
    private static var _dataless: Set<String> = []

    /// Online-only files (Google Drive, iCloud) that are not on this Mac yet.
    /// Reading their bytes downloads them, so the grid avoids it.
    static func isDataless(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _dataless.contains(id)
    }

    fileprivate static func setDataless(_ ids: Set<String>, under dir: String) {
        lock.lock(); defer { lock.unlock() }
        _dataless = _dataless.filter { !$0.hasPrefix(prefix + dir) }.union(ids)
    }

    /// SF_DATALESS: the file's contents live in the cloud.
    static func checkDataless(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_flags & 0x40000000) != 0
    }

    // MARK: Scanning

    struct Listing {
        var items: [Item]
        var subfolders: [URL]
    }

    /// The pictures and videos directly in `dir`, plus its subfolders.
    /// Sizes come from Spotlight or the image header; never the whole file.
    static func scan(_ dir: URL) -> Listing {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey,
                                      .contentModificationDateKey, .creationDateKey]
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                        options: [.skipsHiddenFiles]) else {
            return Listing(items: [], subfolders: [])
        }
        var items: [Item] = []
        var folders: [URL] = []
        var dataless: Set<String> = []
        for url in entries {
            let rv = try? url.resourceValues(forKeys: Set(keys))
            if rv?.isDirectory == true {
                if rv?.isPackage != true { folders.append(url) }
                continue
            }
            let ext = url.pathExtension.lowercased()
            let type: ItemType
            if Library.imageExts.contains(ext) { type = .image }
            else if Library.videoExts.contains(ext) { type = .video }
            else { continue }

            let id = id(for: url)
            let cloud = checkDataless(url.path)
            if cloud { dataless.insert(id) }
            let (w, h) = dimensions(url, type: type, cloud: cloud)
            let modified = rv?.contentModificationDate ?? Date.distantPast
            items.append(Item(
                id: id,
                name: url.deletingPathExtension().lastPathComponent,
                type: type.rawValue, ext: ext, folderId: nil,
                sizeBytes: Int64(rv?.fileSize ?? 0), width: w, height: h,
                sourceURL: nil, pageURL: nil, note: "", colors: "[]", hash: nil,
                rating: 0, createdAt: rv?.creationDate ?? modified, modifiedAt: modified,
                deletedAt: nil, sortIndex: -modified.timeIntervalSince1970))
        }
        setDataless(dataless, under: dir.path + "/")
        folders.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return Listing(items: items, subfolders: folders)
    }

    /// Subfolders only, for the sidebar tree.
    static func subfolders(of dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                        options: [.skipsHiddenFiles]) else { return [] }
        return entries.filter {
            let rv = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return rv?.isDirectory == true && rv?.isPackage != true
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private static func dimensions(_ url: URL, type: ItemType, cloud: Bool) -> (Int, Int) {
        if let md = MDItemCreateWithURL(nil, url as CFURL) {
            let w = (MDItemCopyAttribute(md, kMDItemPixelWidth) as? NSNumber)?.intValue ?? 0
            let h = (MDItemCopyAttribute(md, kMDItemPixelHeight) as? NSNumber)?.intValue ?? 0
            if w > 0, h > 0 { return (w, h) }
        }
        // The header only: ImageIO reads a few KB, not the picture.
        if !cloud, type == .image,
           let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            var w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            var h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            if let o = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue, o >= 5 { swap(&w, &h) }
            return (w, h)
        }
        return (0, 0)
    }

    // MARK: Thumbnails

    /// A grid thumbnail for a file on disk. Local pictures decode straight
    /// from the file at display size. Videos and online-only files go through
    /// a cached PNG; for online-only files only Quick Look is asked, which
    /// uses the cloud provider's own thumbnail instead of downloading.
    static func thumbnail(_ item: Item, maxPixel: Int) -> NSImage? {
        let file = url(item.id)
        let cloud = isDataless(item.id)
        if item.itemType == .image, !cloud {
            return ThumbCache.decode(url: file, maxPixel: maxPixel)
        }
        let cached = thumbURL(for: item)
        if !FileManager.default.fileExists(atPath: cached.path) {
            var img: NSImage? = nil
            if !cloud, item.itemType == .video { img = Library.bestVideoFrame(file) }
            if img == nil { img = quickLook(file) }
            guard let img, let png = pngData(img) else { return nil }
            try? png.write(to: cached)
        }
        return ThumbCache.decode(url: cached, maxPixel: maxPixel)
    }

    private static func quickLook(_ file: URL) -> NSImage? {
        let request = QLThumbnailGenerator.Request(fileAt: file, size: CGSize(width: 512, height: 512),
                                                   scale: 2.0, representationTypes: .thumbnail)
        var result: NSImage? = nil
        let sem = DispatchSemaphore(value: 0)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            result = rep?.nsImage
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 10)
        return result
    }

    private static func pngData(_ img: NSImage) -> Data? {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: - File operations

enum FileOps {
    /// Move files into `dir`. A name already taken there gets " 2", " 3"…
    static func move(_ urls: [URL], to dir: URL) {
        var failures: [String] = []
        for src in urls {
            guard src.deletingLastPathComponent().standardizedFileURL != dir.standardizedFileURL else { continue }
            // Never into itself or its own subfolder.
            if dir.standardizedFileURL.path.hasPrefix(src.standardizedFileURL.path + "/") { continue }
            let dest = uniqueDestination(for: src.lastPathComponent, in: dir)
            do { try FileManager.default.moveItem(at: src, to: dest) }
            catch { failures.append("\(src.lastPathComponent): \(error.localizedDescription)") }
        }
        AppState.shared.refreshFiles()
        if !failures.isEmpty { alert("Some files could not be moved", failures.joined(separator: "\n")) }
    }

    /// Copy library items out to a folder on disk, named as they are in Snag.
    static func export(_ items: [Item], to dir: URL) {
        for it in items where it.itemType != .url {
            let safe = it.name.replacingOccurrences(of: "/", with: "-")
            let dest = uniqueDestination(for: "\(safe).\(it.ext)", in: dir)
            try? FileManager.default.copyItem(at: Library.fileURL(for: it), to: dest)
        }
        AppState.shared.refreshFiles()
    }

    /// Finder's Trash, so it can be put back.
    static func trash(_ urls: [URL]) {
        var failures: [String] = []
        for u in urls {
            do { try FileManager.default.trashItem(at: u, resultingItemURL: nil) }
            catch { failures.append("\(u.lastPathComponent): \(error.localizedDescription)") }
        }
        AppState.shared.refreshFiles()
        if !failures.isEmpty { alert("Some files could not be moved to the Trash", failures.joined(separator: "\n")) }
    }

    static func chooseFolderAndMove(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Move Here"
        panel.message = urls.count == 1 ? "Move “\(urls[0].lastPathComponent)” to…" : "Move \(urls.count) files to…"
        if case .files(let path) = AppState.shared.filter {
            panel.directoryURL = URL(fileURLWithPath: path)
        }
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        move(urls, to: dir)
    }

    /// Copy files into the Snag library. The originals stay where they are.
    static func addToLibrary(_ urls: [URL], folderId: String?) {
        DispatchQueue.global(qos: .userInitiated).async {
            for u in urls { _ = try? Library.importFile(at: u, folderId: folderId) }
        }
    }

    static func uniqueDestination(for name: String, in dir: URL) -> URL {
        var dest = dir.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return dest
    }

    private static func alert(_ title: String, _ body: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.runModal()
    }
}

// MARK: - Sidebar locations

enum FileLocations {
    private static let key = "snag.files.locations"

    /// The folders pinned under Files. First run: Desktop, Downloads and any
    /// cloud drives (Google Drive and friends live in ~/Library/CloudStorage).
    static func load() -> [String] {
        if let saved = UserDefaults.standard.array(forKey: key) as? [String] { return saved }
        let home = FileManager.default.homeDirectoryForCurrentUser
        var out = [home.appendingPathComponent("Desktop").path,
                   home.appendingPathComponent("Downloads").path]
        let cloud = home.appendingPathComponent("Library/CloudStorage")
        if let drives = try? FileManager.default.contentsOfDirectory(at: cloud, includingPropertiesForKeys: nil,
                                                                     options: [.skipsHiddenFiles]) {
            out += drives.map(\.path).sorted()
        }
        return out
    }

    static func save(_ paths: [String]) {
        UserDefaults.standard.set(paths, forKey: key)
    }

    /// "GoogleDrive-name@gmail.com" reads as "Google Drive".
    static func displayName(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let last = url.lastPathComponent
        if url.deletingLastPathComponent().lastPathComponent == "CloudStorage" {
            let provider = last.split(separator: "-").first.map(String.init) ?? last
            switch provider {
            case "GoogleDrive": return "Google Drive"
            case "Dropbox": return "Dropbox"
            case "OneDrive": return "OneDrive"
            case "Box": return "Box"
            default: return provider
            }
        }
        if path == FileManager.default.homeDirectoryForCurrentUser.path { return "Home" }
        return last
    }

    static func icon(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        if url.deletingLastPathComponent().lastPathComponent == "CloudStorage" { return "cloud" }
        switch url.lastPathComponent {
        case "Desktop": return "menubar.dock.rectangle"
        case "Downloads": return "arrow.down.circle"
        case "Documents": return "doc"
        case "Pictures": return "photo"
        case "Movies": return "film"
        default: return "folder"
        }
    }
}

/// Watches the folder on screen and rescans when its contents change.
final class FolderWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1

    func watch(_ dir: URL, onChange: @escaping () -> Void) {
        stop()
        fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete],
                                                          queue: .main)
        s.setEventHandler(handler: onChange)
        let fd = self.fd
        s.setCancelHandler { close(fd) }
        source = s
        s.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        fd = -1
    }
}

// MARK: - Sidebar section

struct FilesSidebarSection: View {
    @EnvironmentObject var state: AppState
    @Binding var dropTarget: String?
    @AppStorage("snag.sidebar.filesOpen") private var open = true
    @State private var locations: [String] = FileLocations.load()
    @State private var expanded: Set<String> = []
    @State private var children: [String: [URL]] = [:]

    var body: some View {
        HStack(spacing: 4) {
            Button { open.toggle() } label: {
                HStack(spacing: 4) {
                    Text("Files").font(.system(size: 10.5, weight: .semibold))
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: addLocation) {
                Image(systemName: "plus").font(.system(size: 10, weight: .medium))
                    .frame(width: 20, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Add a folder from your Mac")
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.leading, 14).padding(.trailing, 10).padding(.top, 16).padding(.bottom, 5)

        if open {
            ForEach(locations, id: \.self) { path in
                tree(URL(fileURLWithPath: path), depth: 0, isRoot: true)
            }
        }
    }

    private func tree(_ url: URL, depth: Int, isRoot: Bool = false) -> AnyView {
        let path = url.path
        return AnyView(Group {
            row(url, depth: depth, isRoot: isRoot)
            if expanded.contains(path) {
                ForEach(children[path] ?? [], id: \.self) { child in
                    tree(child, depth: depth + 1)
                }
            }
        })
    }

    @ViewBuilder
    private func row(_ url: URL, depth: Int, isRoot: Bool) -> some View {
        let path = url.path
        let selected = state.filter == .files(path)
        let isExpanded = expanded.contains(path)
        let target = dropTarget == "file:" + path
        HStack(spacing: 5) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(selected ? .white.opacity(0.8) : Theme.textSecondary.opacity(0.8))
                .frame(width: 10, height: 16)
                .contentShape(Rectangle())
                .onTapGesture { toggle(url) }
            Image(systemName: isRoot ? FileLocations.icon(path) : "folder")
                .font(.system(size: 11.5))
                .frame(width: 16)
                .foregroundStyle(selected ? .white : Theme.textSecondary)
            Text(isRoot ? FileLocations.displayName(path) : url.lastPathComponent)
                .font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(selected ? .white : Color(white: 0.85))
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .padding(.leading, 6 + CGFloat(depth) * 14)
        .padding(.trailing, 10)
        .background(RoundedRectangle(cornerRadius: 6).fill(
            selected ? Theme.accent.opacity(0.85) : target ? Theme.accent.opacity(0.28) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.accent, lineWidth: target ? 1.8 : 0))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { toggle(url) }
        .onTapGesture {
            state.blurTextFocus()
            state.filter = .files(path)
        }
        .padding(.horizontal, 8)
        .help(path)
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("New Folder") { newFolder(in: url) }
            if isRoot {
                Divider()
                Button("Remove from Sidebar") { remove(path) }
            } else {
                Button("Add to Sidebar") { add(path) }
            }
        }
        // Drop pictures here to move them into this folder on disk. Snag
        // library items dropped here are copied out instead.
        .background(DropCatcher(
            folderId: nil,
            onTargeted: { t in dropTarget = t ? "file:" + path : (target ? nil : dropTarget) },
            onInternalItem: { id in
                let ids = AppState.shared.draggedItemIds(id)
                let external = ids.filter(ExternalFiles.isExternal).map(ExternalFiles.url)
                if !external.isEmpty { FileOps.move(external, to: url) }
                let library = AppState.shared.items.filter { ids.contains($0.id) }
                if !library.isEmpty { FileOps.export(library, to: url) }
            },
            onFileURLs: { urls in FileOps.move(urls, to: url) }
        ))
    }

    private func toggle(_ url: URL) {
        let path = url.path
        if expanded.contains(path) {
            expanded.remove(path)
        } else {
            expanded.insert(path)
            DispatchQueue.global(qos: .userInitiated).async {
                let subs = ExternalFiles.subfolders(of: url)
                DispatchQueue.main.async { children[path] = subs }
            }
        }
    }

    private func addLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Sidebar"
        guard panel.runModal() == .OK else { return }
        for u in panel.urls { add(u.path) }
        if let first = panel.urls.first { state.filter = .files(first.path) }
    }

    private func add(_ path: String) {
        guard !locations.contains(path) else { return }
        locations.append(path)
        FileLocations.save(locations)
    }

    private func remove(_ path: String) {
        locations.removeAll { $0 == path }
        FileLocations.save(locations)
        if case .files(let shown) = state.filter, shown == path || shown.hasPrefix(path + "/") {
            state.filter = .all
        }
    }

    private func newFolder(in dir: URL) {
        let dest = FileOps.uniqueDestination(for: "untitled folder", in: dir)
        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
            expanded.insert(dir.path)
            children[dir.path] = ExternalFiles.subfolders(of: dir)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch {
            NSSound.beep()
        }
    }
}

// MARK: - Header above the grid: where you are, and the folders inside

struct FilesHeader: View {
    @EnvironmentObject var state: AppState
    let path: String

    var body: some View {
        let url = URL(fileURLWithPath: path)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button {
                    state.filter = .files(url.deletingLastPathComponent().path)
                } label: {
                    Image(systemName: "arrow.up").font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
                .disabled(path == "/")
                .help("Enclosing folder")

                Text(displayPath(path))
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    .lineLimit(1).truncationMode(.head)
                Spacer()
                if state.filesLoading {
                    ProgressView().controlSize(.mini)
                }
                Text("\(state.fileItems.count) items")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accent)
            }
            if !state.fileSubfolders.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(state.fileSubfolders, id: \.self) { sub in
                            SubfolderChip(url: sub)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func displayPath(_ p: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let cloud = home + "/Library/CloudStorage/"
        if p.hasPrefix(cloud) {
            let rest = String(p.dropFirst(cloud.count))
            let parts = rest.split(separator: "/", maxSplits: 1).map(String.init)
            let root = FileLocations.displayName(cloud + parts[0])
            return parts.count > 1 ? "\(root) / \(parts[1].replacingOccurrences(of: "/", with: " / "))" : root
        }
        if p.hasPrefix(home) { return "~" + p.dropFirst(home.count) }
        return p
    }
}

/// A folder inside the one on screen: click to open it, drop files on it to
/// move them in.
private struct SubfolderChip: View {
    @EnvironmentObject var state: AppState
    let url: URL
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "folder.fill").font(.system(size: 10.5))
            Text(url.lastPathComponent).font(.system(size: 11.5)).lineLimit(1)
        }
        .foregroundStyle(Color(white: 0.88))
        .padding(.horizontal, 9).padding(.vertical, 4.5)
        .background(Capsule().fill(targeted ? Theme.accent.opacity(0.45) : Theme.fieldBG))
        .overlay(Capsule().strokeBorder(Theme.accent, lineWidth: targeted ? 1.5 : 0))
        .contentShape(Capsule())
        .onTapGesture { state.filter = .files(url.path) }
        .contextMenu {
            Button("Open") { state.filter = .files(url.path) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        .background(DropCatcher(
            folderId: nil,
            onTargeted: { targeted = $0 },
            onInternalItem: { id in
                let ids = AppState.shared.draggedItemIds(id)
                let external = ids.filter(ExternalFiles.isExternal).map(ExternalFiles.url)
                if !external.isEmpty { FileOps.move(external, to: url) }
                let library = AppState.shared.items.filter { ids.contains($0.id) }
                if !library.isEmpty { FileOps.export(library, to: url) }
            },
            onFileURLs: { urls in FileOps.move(urls, to: url) }
        ))
    }
}

// MARK: - Menus and panels for files on disk

struct FileItemMenu: View {
    @EnvironmentObject var state: AppState
    let item: Item

    var body: some View {
        let sel = state.selectedItemIds
        let ids: Set<String> = sel.count > 1 && sel.contains(item.id) ? sel : [item.id]
        let urls = ids.filter(ExternalFiles.isExternal).map(ExternalFiles.url)
        let n = urls.count
        if n == 1 {
            Button("Preview") { state.select(item.id, additive: false); state.previewItemId = item.id }
            Button("Open") { NSWorkspace.shared.open(ExternalFiles.url(item.id)) }
        }
        Button(n == 1 ? "Copy" : "Copy \(n) Items") {
            state.copyToClipboard(state.fileItems.filter { ids.contains($0.id) })
        }
        Button(n == 1 ? "Show in Finder" : "Show \(n) in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
        Divider()
        Button(n == 1 ? "Move to…" : "Move \(n) to…") { FileOps.chooseFolderAndMove(urls) }
        Menu(n == 1 ? "Add to Snag" : "Add \(n) to Snag") {
            Button("Uncategorized") { FileOps.addToLibrary(urls, folderId: nil) }
            ForEach(state.folders) { f in
                Button(f.name) { FileOps.addToLibrary(urls, folderId: f.id) }
            }
        }
        Divider()
        Button(n == 1 ? "Move to Trash" : "Move \(n) to Trash", role: .destructive) { FileOps.trash(urls) }
    }
}

/// Inspector and preview panel for a file on disk: what it is and where it
/// lives. No name, note or tags, since nothing is saved for it.
struct FileDetails: View {
    @EnvironmentObject var state: AppState
    let item: Item
    var showThumb = true

    var body: some View {
        let url = ExternalFiles.url(item.id)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if showThumb {
                    ThumbImage(item: item, maxPixel: 520) { img in
                        if let img {
                            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                        } else {
                            ZStack { Theme.cardBG; Image(systemName: "photo").foregroundStyle(Theme.textSecondary) }
                                .frame(height: 140)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                Text(url.lastPathComponent)
                    .font(.system(size: 13, weight: .semibold))
                    .textSelection(.enabled)
                VStack(alignment: .leading, spacing: 7) {
                    info("Kind", item.ext.uppercased() + (ExternalFiles.isDataless(item.id) ? " · in the cloud" : ""))
                    if item.width > 0 { info("Dimensions", "\(item.width) × \(item.height)") }
                    info("Size", ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file))
                    info("Modified", item.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                    info("Where", url.deletingLastPathComponent().path
                        .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button("Open") { NSWorkspace.shared.open(url) }
                    Button("Move to…") { FileOps.chooseFolderAndMove([url]) }
                    Menu("Add to Snag") {
                        Button("Uncategorized") { FileOps.addToLibrary([url], folderId: nil) }
                        ForEach(state.folders) { f in
                            Button(f.name) { FileOps.addToLibrary([url], folderId: f.id) }
                        }
                    }
                    .fixedSize()
                }
                .controlSize(.small)
                Text("This file isn't in your Snag library. Add it to Snag to keep a copy with tags and notes.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func info(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                .frame(width: 72, alignment: .leading)
            Text(value).font(.system(size: 11)).foregroundStyle(Color(white: 0.88))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
