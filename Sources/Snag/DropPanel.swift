import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Watches macOS-wide drags. When the drag pasteboard holds files, images, or URLs,
/// the drop panel slides in at the right screen edge.
final class DragMonitor {
    private var globalDrag: Any?
    private var localDrag: Any?
    private var globalUp: Any?
    private var localUp: Any?
    private var lastChangeCount = NSPasteboard(name: .drag).changeCount
    private var panelShownForCurrentDrag = false
    let panel: DropPanelController

    init(panel: DropPanelController) {
        self.panel = panel
        globalDrag = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            self?.handleDrag()
        }
        localDrag = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] e in
            self?.handleDrag(); return e
        }
        globalUp = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            self?.handleUp()
        }
        localUp = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] e in
            self?.handleUp(); return e
        }
    }

    private func handleDrag() {
        let pb = NSPasteboard(name: .drag)
        guard pb.changeCount != lastChangeCount else {
            return // already evaluated this drag
        }
        lastChangeCount = pb.changeCount
        panelShownForCurrentDrag = false

        let types = pb.types ?? []
        let hasFile = types.contains(.fileURL)
        let hasImage = pb.canReadObject(forClasses: [NSImage.self], options: nil)
        let hasURL = types.contains(.URL)
        // Ignore drags that are only text.
        if hasFile || hasImage || hasURL {
            panelShownForCurrentDrag = true
            DispatchQueue.main.async { self.panel.show() }
        }
    }

    private func handleUp() {
        guard panelShownForCurrentDrag else { return }
        panelShownForCurrentDrag = false
        DispatchQueue.main.async { self.panel.scheduleHide(after: 1.0) }
    }
}

final class DropPanelController {
    private var panel: NSPanel!
    private var hideWork: DispatchWorkItem?
    let dropState = DropPanelState()

    init() {
        let width: CGFloat = 280
        let height: CGFloat = 460
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
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

    /// The screen the mouse cursor is on — NOT NSScreen.main, which is the
    /// screen with keyboard focus and breaks drags on external displays.
    private var mouseScreen: NSScreen? {
        let loc = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(loc, $0.frame, false) } ?? NSScreen.main
    }

    func show() {
        hideWork?.cancel()
        guard let screen = mouseScreen else { return }
        if panel.isVisible {
            // Already out — but jump displays if the drag started on another screen.
            if !screen.frame.intersects(panel.frame) {
                let f = screen.visibleFrame
                let size = panel.frame.size
                panel.setFrameOrigin(NSPoint(x: f.maxX - size.width - 16, y: f.midY - size.height / 2))
            }
            return
        }
        let f = screen.visibleFrame
        let size = panel.frame.size
        let target = NSPoint(x: f.maxX - size.width - 16, y: f.midY - size.height / 2)
        panel.setFrameOrigin(NSPoint(x: f.maxX + 4, y: target.y))
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrameOrigin(target)
        }
    }

    func scheduleHide(after seconds: Double) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.dropState.busy { self.scheduleHide(after: 1.0); return }
            self.hide()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() {
        let screen = NSScreen.screens.first { $0.frame.intersects(panel.frame) }
        guard panel.isVisible, let screen else { panel.orderOut(nil); return }
        let f = screen.visibleFrame
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().setFrameOrigin(NSPoint(x: f.maxX + 4, y: panel.frame.origin.y))
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
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
    @State private var targetedFolder: String? = nil  // "" = uncategorized

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .foregroundStyle(Theme.accent)
                Text("Drop into Snag").font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 12)

            if let msg = dropState.message {
                Text(msg)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(Theme.accent))
                    .padding(.bottom, 8)
            }

            ScrollView {
                VStack(spacing: 2) {
                    dropRow(id: "", name: "Uncategorized", icon: "tray", depth: 0, tint: nil)
                    ForEach(flattened(), id: \.folder.id) { entry in
                        dropRow(id: entry.folder.id, name: entry.folder.name, icon: "folder",
                                depth: entry.depth, tint: entry.folder.color)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panelBG))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.1)))
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

    @ViewBuilder
    private func dropRow(id: String, name: String, icon: String, depth: Int, tint: String?) -> some View {
        let isTarget = targetedFolder == id
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 12))
                .foregroundStyle(tint.map { Color(hex: $0) } ?? Color.secondary)
            Text(name).font(.system(size: 12.5)).lineLimit(1)
            Spacer()
        }
        .padding(.vertical, 7)
        .padding(.leading, 10 + CGFloat(depth) * 14)
        .padding(.trailing, 10)
        .background(RoundedRectangle(cornerRadius: 7).fill(isTarget ? Theme.accent.opacity(0.45) : Color.white.opacity(0.04)))
        .onDrop(of: [UTType.fileURL, UTType.url, UTType.image, UTType.movie],
                isTargeted: Binding(get: { targetedFolder == id },
                                    set: { targetedFolder = $0 ? id : (targetedFolder == id ? nil : targetedFolder) })) { providers in
            handleDrop(providers, folderId: id.isEmpty ? nil : id)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider], folderId: String?) -> Bool {
        dropState.busy = true
        DropImporter.importProviders(providers, folderId: folderId) { results in
            DispatchQueue.main.async {
                dropState.busy = false
                if results.isEmpty {
                    dropState.message = "Nothing to save"
                } else if results.allSatisfy({ $0.isDuplicate }) {
                    dropState.message = "Already saved"
                } else {
                    let folderName = folderId.flatMap { fid in AppState.shared.folders.first { $0.id == fid }?.name } ?? "Uncategorized"
                    dropState.message = "Saved to \(folderName)"
                }
            }
        }
        return true
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
