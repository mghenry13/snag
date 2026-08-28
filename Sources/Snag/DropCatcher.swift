import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// AppKit drop destination that accepts everything Snag can save — including
/// FILE PROMISES (how browsers drag images out), which SwiftUI's onDrop
/// cannot receive. Used as the drop surface for the panel and the grid.
final class DropCatcherView: NSView {
    var folderId: String? = nil
    var onTargeted: ((Bool) -> Void)? = nil
    var onBusy: (() -> Void)? = nil
    var onResults: (([ImportResult]) -> Void)? = nil

    private let promiseQueue = OperationQueue()

    override init(frame: NSRect) {
        super.init(frame: frame)
        var types: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .tiff, .png]
        types += NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        registerForDraggedTypes(types)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onTargeted?(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargeted?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onTargeted?(false)
        let pb = sender.draggingPasteboard
        let folderId = self.folderId

        // 1. File promises (browser image drags): receive into a temp dir first.
        if let receivers = pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver],
           !receivers.isEmpty {
            onBusy?()
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("SnagPromise-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            let group = DispatchGroup()
            var urls: [URL] = []
            let lock = NSLock()
            for r in receivers {
                group.enter()
                r.receivePromisedFiles(atDestination: dest, options: [:], operationQueue: promiseQueue) { url, error in
                    if error == nil {
                        lock.lock(); urls.append(url); lock.unlock()
                    }
                    group.leave()
                }
            }
            group.notify(queue: .global(qos: .userInitiated)) { [weak self] in
                var results: [ImportResult] = []
                for u in urls {
                    if let r = try? Library.importFile(at: u, folderId: folderId) { results.append(r) }
                }
                try? FileManager.default.removeItem(at: dest)
                DispatchQueue.main.async { self?.onResults?(results) }
            }
            return true
        }

        // 2. Real file URLs
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            onBusy?()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var results: [ImportResult] = []
                for u in urls {
                    if let r = try? Library.importFile(at: u, folderId: folderId) { results.append(r) }
                }
                DispatchQueue.main.async { self?.onResults?(results) }
            }
            return true
        }

        // 3. Web URLs (download or bookmark)
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let first = urls.first, first.scheme?.hasPrefix("http") == true {
            onBusy?()
            Task { [weak self] in
                let r = try? await Library.importRemote(urlString: first.absoluteString, pageURL: nil, folderId: folderId)
                await MainActor.run { self?.onResults?(r.map { [$0] } ?? []) }
            }
            return true
        }

        // 4. Raw image data
        if let img = NSImage(pasteboard: pb),
           let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            onBusy?()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let r = try? Library.importData(png, ext: "png", name: "Dropped Image", folderId: folderId)
                DispatchQueue.main.async { self?.onResults?(r.map { [$0] } ?? []) }
            }
            return true
        }

        DispatchQueue.main.async { [weak self] in self?.onResults?([]) }
        return false
    }
}

struct DropCatcher: NSViewRepresentable {
    var folderId: String?
    var onTargeted: (Bool) -> Void = { _ in }
    var onBusy: () -> Void = {}
    var onResults: ([ImportResult]) -> Void = { _ in }

    func makeNSView(context: Context) -> DropCatcherView {
        let v = DropCatcherView(frame: .zero)
        apply(to: v)
        return v
    }

    func updateNSView(_ v: DropCatcherView, context: Context) {
        apply(to: v)
    }

    private func apply(to v: DropCatcherView) {
        v.folderId = folderId
        v.onTargeted = onTargeted
        v.onBusy = onBusy
        v.onResults = onResults
    }
}
