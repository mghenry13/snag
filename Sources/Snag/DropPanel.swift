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
    private var loggedThisDrag = false
    private var dragStartLoc: NSPoint = .zero
    private var dragStartTime: TimeInterval = 0
    weak var mainWindow: NSWindow?

    /// True only when the drag clearly carries an image or a video: media data
    /// flavors, media file URLs, media file promises (browser drags), or a web
    /// URL that points at a media file. Text, links, tabs, and other files
    /// never summon the panel.
    private func dragHasPayload(_ pb: NSPasteboard) -> Bool {
        let types = pb.types ?? []
        let mediaExts = Library.imageExts.union(Library.videoExts)

        // Direct image/video data on the pasteboard
        for t in types {
            if let ut = UTType(t.rawValue),
               ut.conforms(to: .image) || ut.conforms(to: .movie) || ut.conforms(to: .audiovisualContent) {
                return true
            }
        }

        // File URLs: qualify only when at least one is a media file
        if types.contains(.fileURL),
           let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL],
           urls.contains(where: { mediaExts.contains($0.pathExtension.lowercased()) }) {
            return true
        }

        // Promised files: the promised content type or extension must be media
        if let promised = pb.string(forType: NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type")) {
            if let ut = UTType(promised), ut.conforms(to: .image) || ut.conforms(to: .movie) { return true }
            if mediaExts.contains(promised.lowercased()) { return true }
        }
        if let list = pb.propertyList(forType: NSPasteboard.PasteboardType("Apple files promise pasteboard type")) as? [String],
           list.contains(where: { mediaExts.contains($0.lowercased()) }) {
            return true
        }

        // Bare web URLs: only when the URL itself is a media file
        if types.contains(.URL),
           let s = pb.string(forType: .URL)
            ?? (pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?.first?.absoluteString,
           let url = URL(string: s),
           mediaExts.contains(url.pathExtension.lowercased()) {
            return true
        }
        return false
    }

    /// Snag's own reorder/nest drags must never summon the panel.
    private func isInternalDrag(_ pb: NSPasteboard) -> Bool {
        (pb.types ?? []).contains { $0.rawValue.hasPrefix("com.mh.snag.") }
    }

    private func handleDrag(_ event: NSEvent) {
        let loc = screenLocation(of: event)
        let pb = NSPasteboard(name: .drag)

        if pb.changeCount != lastChangeCount {
            // A new drag: reset and evaluate fresh.
            lastChangeCount = pb.changeCount
            dragDecided = false
            dragQualifies = false
            loggedThisDrag = false
            dragStartLoc = loc
            dragStartTime = event.timestamp
        }
        // Keep evaluating until the drag shows content — some apps write the
        // drag pasteboard a few events after the drag begins.
        if !dragDecided {
            if isInternalDrag(pb) {
                dragDecided = true
                dragQualifies = false
            } else if dragHasPayload(pb) {
                dragDecided = true
                dragQualifies = true
            }
            if !loggedThisDrag, let types = pb.types, !types.isEmpty {
                loggedThisDrag = true
                NSLog("Snag drag types: \(types.map(\.rawValue).joined(separator: ", "))")
            }
        }
        guard dragQualifies else { return }

        // A small pull filters accidental micro-drags; nothing else gates it.
        let moved = hypot(loc.x - dragStartLoc.x, loc.y - dragStartLoc.y)
        guard moved > 25 else { return }

        // Re-assert every drag event so the panel tracks display changes mid-drag.
        DispatchQueue.main.async { self.panel.show(near: loc) }
    }

    private func handleUp() {
        dragDecided = false
        guard dragQualifies else { return }
        dragQualifies = false
        DispatchQueue.main.async { self.panel.scheduleHide(after: 1.0) }
    }
}

final class DropPanelController {
    private var panel: NSPanel!
    private var hideWork: DispatchWorkItem?
    private var watchdog: Timer?
    private var busyRetries = 0
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

    func show(near point: NSPoint? = nil) {
        hideWork?.cancel()
        let loc = point ?? NSEvent.mouseLocation
        guard let screen = screen(containing: loc) else { return }
        let target = origin(beside: loc, on: screen)

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
        startWatchdog()
    }

    /// Fail-safe: while the panel is up, watch the PHYSICAL left button. The
    /// moment it is released, hide — even when the mouse-up event never
    /// reaches our monitors (drag sessions and sleep/wake can eat it).
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.panel.isVisible else {
                self.watchdog?.invalidate(); self.watchdog = nil
                return
            }
            if NSEvent.pressedMouseButtons & 1 == 0 {
                self.watchdog?.invalidate(); self.watchdog = nil
                self.scheduleHide(after: 0.9)
            }
        }
    }

    func scheduleHide(after seconds: Double) {
        hideWork?.cancel()
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
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            self.panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
            self?.panel.alphaValue = 1
            self?.dropState.message = nil
        })
    }
}

final class DropPanelState: ObservableObject {
    @Published var busy = false
    @Published var message: String? = nil
}

struct DropPanelView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var dropState: DropPanelState
    @State private var targetedFolder: String? = nil  // "" = big dropzone (uncategorized)

    var body: some View {
        HStack(spacing: 0) {
            bigDropZone
                .frame(width: 210)
                .padding(10)

            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
                .padding(.vertical, 12)

            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 2) {
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
        return VStack(spacing: 14) {
            Spacer()
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
            Text("Drag and drop files here")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
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
            onResults: { finishDrop($0, folderId: nil) }
        ))
    }

    // MARK: - Folder rows

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
        } else if results.allSatisfy({ $0.isDuplicate }) {
            dropState.message = "Already saved"
        } else {
            let folderName = folderId.flatMap { fid in AppState.shared.folders.first { $0.id == fid }?.name }
            dropState.message = "Saved to \(folderName ?? "Snag")"
        }
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
