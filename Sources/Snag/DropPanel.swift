import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Watches macOS-wide drags. When the drag pasteboard holds files, images, or URLs,
/// the drop panel slides in at the edge of the screen the mouse is on.
final class DragMonitor {
    private var globalDrag: Any?
    private var localDrag: Any?
    private var globalUp: Any?
    private var localUp: Any?
    private var lastChangeCount = NSPasteboard(name: .drag).changeCount
    let panel: DropPanelController

    init(panel: DropPanelController) {
        self.panel = panel
        installMonitors()
        // Global event monitors can die across sleep/wake — reinstall on wake.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.removeMonitors()
            self?.installMonitors()
        }
    }

    private func installMonitors() {
        globalDrag = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] e in
            self?.handleDrag(e)
        }
        localDrag = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] e in
            self?.handleDrag(e); return e
        }
        globalUp = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            self?.handleUp()
        }
        localUp = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] e in
            self?.handleUp(); return e
        }
    }

    private func removeMonitors() {
        for m in [globalDrag, localDrag, globalUp, localUp] {
            if let m { NSEvent.removeMonitor(m) }
        }
        globalDrag = nil; localDrag = nil; globalUp = nil; localUp = nil
    }

    /// Screen location of a drag event: global-monitor events have no window,
    /// so locationInWindow is already in screen coordinates.
    private func screenLocation(of event: NSEvent) -> NSPoint {
        if let w = event.window {
            return w.convertPoint(toScreen: event.locationInWindow)
        }
        return event.locationInWindow
    }

    private var dragDecided = false
    private var dragQualifies = false
    private var isLinkOnlyDrag = false
    private var loggedThisDrag = false
    private var dragStartLoc: NSPoint = .zero
    private var dragStartTime: TimeInterval = 0
    weak var mainWindow: NSWindow?

    /// Qualify ONLY on a real signal: a media file, a promised media file
    /// (browser drags), or an http link. Raw bitmap flavors are deliberately
    /// ignored — many apps put a TIFF snapshot of whatever is being dragged
    /// (text, table cells, layers) on the drag pasteboard, which used to make
    /// the panel appear for everything.
    private func dragHasPayload(_ pb: NSPasteboard) -> Bool {
        let types = pb.types ?? []
        let mediaExts = Library.imageExts.union(Library.videoExts)

        // Media files (Finder and friends)
        if types.contains(.fileURL),
           let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            if urls.contains(where: { mediaExts.contains($0.pathExtension.lowercased()) }) {
                return true
            }
            // File drags that are NOT media never qualify, even if a link or
            // preview bitmap rides along.
            if !urls.isEmpty { return false }
        }

        // Promised media (how browsers drag images out)
        if let promised = pb.string(forType: NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type")) {
            if let ut = UTType(promised), ut.conforms(to: .image) || ut.conforms(to: .movie) { return true }
            if mediaExts.contains(promised.lowercased()) { return true }
        }
        if let list = pb.propertyList(forType: NSPasteboard.PasteboardType("Apple files promise pasteboard type")) as? [String],
           list.contains(where: { mediaExts.contains($0.lowercased()) }) {
            return true
        }

        // Links (dragging a link, tab, or pin) — but ONLY from clean sources.
        // Apps attach https URLs to their internal drags (Notion blocks, Slack
        // messages...), which made the panel pop for everything again.
        if types.contains(.URL),
           !hasAppCustomFlavor(types),
           let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           urls.contains(where: { $0.scheme?.hasPrefix("http") == true }) {
            isLinkOnlyDrag = true
            return true
        }

        return false
    }

    /// Flavors outside the public/system/browser families mean an app's own
    /// internal drag, not something the user is trying to save.
    private func hasAppCustomFlavor(_ types: [NSPasteboard.PasteboardType]) -> Bool {
        let allowed = ["public.", "com.apple.", "dyn.", "org.chromium.",
                       "com.microsoft.edgemac", "org.mozilla.", "com.operasoftware.",
                       "CorePasteboardFlavorType", "Apple ", "NSFilenames",
                       "NSPromise", "WebURLs", "com.mh.snag."]
        for t in types {
            let raw = t.rawValue
            if !allowed.contains(where: { raw.hasPrefix($0) }) { return true }
        }
        return false
    }

    /// Snag's own reorder/nest drags must never summon the panel.
    private func isInternalDrag(_ pb: NSPasteboard) -> Bool {
        (pb.types ?? []).contains { $0.rawValue.hasPrefix("com.mh.snag.") }
    }

    /// Grab a preview of the dragged media (Eagle shows you what you're
    /// saving). Pasteboard reads happen here on the event thread; decode is
    /// pushed to a background queue.
    private func capturePreview(_ pb: NSPasteboard) {
        let fileURL = (pb.readObjects(forClasses: [NSURL.self],
                                      options: [.urlReadingFileURLsOnly: true]) as? [URL])?
            .first { Library.imageExts.contains($0.pathExtension.lowercased()) }
        let rawData = fileURL == nil
            ? (pb.data(forType: .png) ?? pb.data(forType: .tiff))
            : nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var img: NSImage? = nil
            var info: String? = nil
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 480,
            ]
            var source: CGImageSource? = nil
            if let fileURL { source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) }
            else if let rawData { source = CGImageSourceCreateWithData(rawData as CFData, nil) }
            if let source {
                if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                   let w = props[kCGImagePropertyPixelWidth] as? Int,
                   let h = props[kCGImagePropertyPixelHeight] as? Int {
                    info = "\(w) × \(h)"
                }
                if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) {
                    img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                }
            }
            DispatchQueue.main.async {
                self?.panel.dropState.dragPreview = img
                self?.panel.dropState.dragInfo = info
            }
        }
    }

    // Shake detection state
    private var lastDx: CGFloat = 0
    private var reversalTimes: [TimeInterval] = []
    private var dragTriggered = false

    private func handleDrag(_ event: NSEvent) {
        let loc = screenLocation(of: event)
        let pb = NSPasteboard(name: .drag)

        if pb.changeCount != lastChangeCount {
            // A new drag: reset everything.
            lastChangeCount = pb.changeCount
            DispatchQueue.main.async { AppState.shared.dragActive = true }
            dragTriggered = false
            lastDx = 0
            reversalTimes = []
            DispatchQueue.main.async { [weak self] in
                self?.panel.dropState.dragPreview = nil
                self?.panel.dropState.dragInfo = nil
            }
        }

        // Snag's own reorder/nest drags never summon the panel.
        if isInternalDrag(pb) { return }

        if dragTriggered {
            // Re-assert so the panel follows display changes mid-drag.
            DispatchQueue.main.async { self.panel.show(near: loc) }
            return
        }

        // DELIBERATE summons only — no content classification, no auto-pop.
        // 1) Push against the right screen edge.
        var edgeHit = false
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(loc, $0.frame, false) }) {
            edgeHit = loc.x >= screen.frame.maxX - 2
        }
        // 2) Shake the cursor: quick horizontal direction reversals.
        let dx = event.deltaX
        if abs(dx) > 4 {
            if lastDx != 0, (dx > 0) != (lastDx > 0) {
                reversalTimes.append(event.timestamp)
            }
            lastDx = dx
        }
        reversalTimes.removeAll { event.timestamp - $0 > 0.5 }
        let shake = reversalTimes.count >= 4

        if edgeHit || shake {
            dragTriggered = true
            capturePreview(pb)
            DispatchQueue.main.async { self.panel.show(near: loc) }
        }
    }

    private func handleUp() {
        reversalTimes = []
        lastDx = 0
        DispatchQueue.main.async { AppState.shared.dragActive = false }
        guard dragTriggered else { return }
        dragTriggered = false
        DispatchQueue.main.async { self.panel.scheduleHide(after: 1.0) }
    }
}

final class DropPanelController {
    private var panel: NSPanel!
    private(set) var isSticky = false
    private var hideWork: DispatchWorkItem?
    private var watchdog: Timer?
    private var busyRetries = 0
    private var hidePending = false
    let dropState = DropPanelState()

    private let panelSize = NSSize(width: 480, height: 360)

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered, defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        dropState.dismissAfterSave = { [weak self] in
            guard let self else { return }
            self.isSticky = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.hide() }
        }
        let view = DropPanelView(dropState: dropState)
            .environmentObject(AppState.shared)
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = panel.contentView!.bounds
        host.autoresizingMask = [.width, .height]
        panel.contentView!.addSubview(host)
    }

    private func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    /// Show the panel at the right edge of the screen containing `point`.
    /// Safe to call repeatedly — it repositions if the mouse changed displays.
    /// Position the panel just beside the cursor: to the right when there is
    /// room, flipped to the left otherwise, vertically centered on the mouse
    /// and clamped inside that screen.
    private func origin(beside loc: NSPoint, on screen: NSScreen) -> NSPoint {
        let f = screen.visibleFrame
        let gap: CGFloat = 28
        var x = loc.x + gap
        if x + panelSize.width > f.maxX - 8 {
            x = loc.x - gap - panelSize.width
        }
        x = max(f.minX + 8, min(x, f.maxX - panelSize.width - 8))
        var y = loc.y - panelSize.height / 2
        y = max(f.minY + 8, min(y, f.maxY - panelSize.height - 8))
        return NSPoint(x: x, y: y)
    }

    /// sticky = summoned by hotkey/menu: stays up until toggled or closed.
    func show(near point: NSPoint? = nil, sticky: Bool = false) {
        if sticky { isSticky = true }
        hideWork?.cancel()
        hidePending = false
        let loc = point ?? NSEvent.mouseLocation
        guard let screen = screen(containing: loc) else { return }
        let target = origin(beside: loc, on: screen)

        // The watchdog must be armed on EVERY show call, including the
        // already-visible path — a new drag inside the hide grace cancels the
        // pending hide, and only the watchdog can close the panel after that.
        startWatchdog()

        if panel.isVisible {
            // Keep the panel where it landed for this drag; only jump if the
            // mouse moved to a different display.
            if !screen.frame.intersects(panel.frame) {
                panel.setFrame(NSRect(origin: target, size: panelSize), display: true)
            }
            return
        }
        panel.alphaValue = 0
        panel.setFrame(NSRect(origin: NSPoint(x: target.x, y: target.y - 12), size: panelSize), display: false)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(target)
        }
    }

    /// Fail-safe: while the panel is up, watch the PHYSICAL left button.
    /// The timer lives for the panel's whole visible lifetime; whenever the
    /// button is up and no hide is pending, one gets scheduled. This survives
    /// swallowed mouse-ups AND hides canceled by follow-up drags.
    private func startWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.panel.isVisible else {
                self.watchdog?.invalidate(); self.watchdog = nil
                return
            }
            if !self.isSticky, NSEvent.pressedMouseButtons & 1 == 0, !self.hidePending {
                self.scheduleHide(after: 0.9)
            }
        }
    }

    func toggleSticky() {
        if panel.isVisible {
            isSticky = false
            hide()
        } else {
            show(sticky: true)
        }
    }

    func scheduleHide(after seconds: Double) {
        guard !isSticky else { return }
        hideWork?.cancel()
        hidePending = true
        busyRetries = 0
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.dropState.busy, self.busyRetries < 15 {
                self.busyRetries += 1
                let retry = DispatchWorkItem { [weak self] in self?.scheduleHideRetry() }
                self.hideWork = retry
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: retry)
                return
            }
            self.hide()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func scheduleHideRetry() {
        if dropState.busy, busyRetries < 15 {
            busyRetries += 1
            let retry = DispatchWorkItem { [weak self] in self?.scheduleHideRetry() }
            hideWork = retry
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: retry)
            return
        }
        hide()
    }

    func hide() {
        hidePending = false
        isSticky = false
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            self.panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
            self?.panel.alphaValue = 1
            self?.dropState.message = nil
            self?.dropState.dragPreview = nil
            self?.dropState.dragInfo = nil
        })
    }
}

final class DropPanelState: ObservableObject {
    @Published var busy = false
    @Published var message: String? = nil
    /// Set by the controller: flash the toast, then close the panel.
    var dismissAfterSave: (() -> Void)? = nil
    // Eagle-style: preview of the item mid-drag, so you see what you're saving
    @Published var dragPreview: NSImage? = nil
    @Published var dragInfo: String? = nil
}

struct DropPanelView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var dropState: DropPanelState
    @State private var targetedFolder: String? = nil  // "" = big dropzone (uncategorized)

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 10) {
                bigDropZone
                recentZone
            }
            .frame(width: 210)
            .padding(10)

            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
                .padding(.vertical, 12)

            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(flattened(), id: \.folder.id) { entry in
                            dropRow(entry.folder, depth: entry.depth)
                        }
                        if state.folders.isEmpty {
                            Text("No folders yet")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.top, 24)
                        }
                    }
                    .padding(8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            if let msg = dropState.message {
                Text(msg)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(Theme.accent))
                    .padding(.top, 12)
            }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panelBG))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.1)))
    }

    // MARK: - Big drop zone (straight into Snag, uncategorized)

    private var bigDropZone: some View {
        let targeted = targetedFolder == ""
        return VStack(spacing: 12) {
            Spacer()
            if let preview = dropState.dragPreview {
                // What you're about to save, Eagle-style
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 178, maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                    .scaleEffect(targeted ? 1.04 : 1.0)
                    .animation(.easeOut(duration: 0.15), value: targeted)
                if let info = dropState.dragInfo {
                    Text(info)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 11)
                        .fill(Color.white.opacity(targeted ? 0.10 : 0.04))
                    Image(systemName: "folder")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(Theme.textSecondary.opacity(targeted ? 1 : 0.7))
                        .offset(y: -10)
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 19))
                        .foregroundStyle(targeted ? Theme.accent : Theme.textSecondary)
                        .offset(x: 26, y: 12)
                }
                .frame(height: 150)
            }
            Text(targeted ? "Drop to save" : "Drag and drop files here")
                .font(.system(size: 12))
                .foregroundStyle(targeted ? Color.white : Theme.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(targeted ? Theme.accent : Color.white.opacity(0.14),
                              style: StrokeStyle(lineWidth: targeted ? 2 : 1.5, dash: [6, 5]))
        )
        .contentShape(Rectangle())
        .background(DropCatcher(
            folderId: nil,
            onTargeted: { t in targetedFolder = t ? "" : (targetedFolder == "" ? nil : targetedFolder) },
            onBusy: { dropState.busy = true },
            onResults: { finishDrop($0, folderId: nil) },
            onInternalItem: { id in
                AppState.shared.moveItem(id, to: nil)
                finishDrop([], folderId: nil)
                dropState.message = "Moved to Uncategorized"
                dropState.dismissAfterSave?()
            }
        ))
    }

    /// One zone for the single most recently used folder.
    @ViewBuilder
    private var recentZone: some View {
        if let folder = state.recentFolderIds.first
            .flatMap({ id in state.folders.first { $0.id == id } }) {
            let key = "recent:" + folder.id
            let targeted = targetedFolder == key
            VStack(spacing: 5) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 19))
                    .foregroundStyle(folder.color.map { Color(hex: $0) } ?? Theme.textSecondary)
                Text(folder.name)
                    .font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                    .foregroundStyle(targeted ? .white : Color(white: 0.85))
                Text("Most recent")
                    .font(.system(size: 9)).foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 90)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(targeted ? 0.10 : 0.04)))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(targeted ? Theme.accent : Color.white.opacity(0.14),
                                  style: StrokeStyle(lineWidth: targeted ? 2 : 1.5, dash: [6, 5]))
            )
            .contentShape(Rectangle())
            .background(DropCatcher(
                folderId: folder.id,
                onTargeted: { t in targetedFolder = t ? key : (targetedFolder == key ? nil : targetedFolder) },
                onBusy: { dropState.busy = true },
                onResults: { finishDrop($0, folderId: folder.id) },
                onInternalItem: { id in
                    AppState.shared.moveItem(id, to: folder.id)
                    dropState.message = "Moved to \(folder.name)"
                    dropState.dismissAfterSave?()
                }
            ))
        }
    }

    // MARK: - Folder rows

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .kerning(0.5)
            .foregroundStyle(Theme.textSecondary.opacity(0.8))
            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2)
    }

    private func recentFolders() -> [Folder] {
        let byId = Dictionary(uniqueKeysWithValues: state.folders.map { ($0.id, $0) })
        return state.recentFolderIds.compactMap { byId[$0] }.prefix(4).map { $0 }
    }

    private struct FlatFolder { let folder: Folder; let depth: Int }

    private func flattened(parent: String? = nil, depth: Int = 0) -> [FlatFolder] {
        var out: [FlatFolder] = []
        for f in state.childFolders(of: parent) {
            out.append(FlatFolder(folder: f, depth: depth))
            out.append(contentsOf: flattened(parent: f.id, depth: depth + 1))
        }
        return out
    }

    private func targetBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { targetedFolder == id },
                set: { targetedFolder = $0 ? id : (targetedFolder == id ? nil : targetedFolder) })
    }

    @ViewBuilder
    private func dropRow(_ folder: Folder, depth: Int) -> some View {
        let isTarget = targetedFolder == folder.id
        HStack(spacing: 7) {
            Image(systemName: "folder")
                .font(.system(size: 12))
                .foregroundStyle(folder.color.map { Color(hex: $0) } ?? Color.secondary)
            Text(folder.name).font(.system(size: 12.5)).lineLimit(1)
            Spacer()
        }
        .padding(.vertical, 7)
        .padding(.leading, 10 + CGFloat(depth) * 14)
        .padding(.trailing, 10)
        .background(RoundedRectangle(cornerRadius: 7).fill(isTarget ? Theme.accent.opacity(0.45) : Color.white.opacity(0.04)))
        .background(DropCatcher(
            folderId: folder.id,
            onTargeted: { t in targetedFolder = t ? folder.id : (targetedFolder == folder.id ? nil : targetedFolder) },
            onBusy: { dropState.busy = true },
            onResults: { finishDrop($0, folderId: folder.id) }
        ))
    }

    private func finishDrop(_ results: [ImportResult], folderId: String?) {
        dropState.busy = false
        if results.isEmpty {
            dropState.message = "Nothing to save"
            return // stay up so the drop can be retried
        }
        if results.allSatisfy({ $0.isDuplicate }) {
            dropState.message = "Already saved"
        } else {
            let folderName = folderId.flatMap { fid in AppState.shared.folders.first { $0.id == fid }?.name }
            dropState.message = "Saved to \(folderName ?? "Snag")"
        }
        // Saved: the panel's job is done — flash the toast, then leave.
        dropState.dismissAfterSave?()
    }
}

/// Shared NSItemProvider import used by the drop panel and the main window.
enum DropImporter {
    static func importProviders(_ providers: [NSItemProvider], folderId: String?,
                                completion: @escaping ([ImportResult]) -> Void) {
        let group = DispatchGroup()
        var results: [ImportResult] = []
        let lock = NSLock()
        func add(_ r: ImportResult?) {
            guard let r else { return }
            lock.lock(); results.append(r); lock.unlock()
        }

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                    defer { group.leave() }
                    var url: URL? = nil
                    if let d = data as? Data { url = URL(dataRepresentation: d, relativeTo: nil) }
                    else if let u = data as? URL { url = u }
                    guard let url else { return }
                    add(try? Library.importFile(at: url, folderId: folderId))
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { data, _ in
                    var url: URL? = nil
                    if let d = data as? Data { url = URL(dataRepresentation: d, relativeTo: nil) }
                    else if let u = data as? URL { url = u }
                    guard let url else { group.leave(); return }
                    Task {
                        add(try? await Library.importRemote(urlString: url.absoluteString, pageURL: nil, folderId: folderId))
                        group.leave()
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                group.enter()
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    defer { group.leave() }
                    guard let data else { return }
                    add(try? Library.importData(data, ext: "png", name: "Dropped Image", folderId: folderId))
                }
            }
        }
        group.notify(queue: .global(qos: .userInitiated)) {
            completion(results)
        }
    }
}
