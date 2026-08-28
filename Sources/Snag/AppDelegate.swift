import AppKit
import SwiftUI
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var statusItem: NSStatusItem!
    var dragMonitor: DragMonitor!
    var panelController: DropPanelController!
    let apiServer = APIServer()
    var keyMonitor: Any?
    var gestureMonitor: Any?
    var magnifyMonitor: Any?
    private var gestureAccum = CGPoint.zero
    private var gestureAxis = 0 // 0 undecided, 1 horizontal (switch), 2 vertical (zoom)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Dock icon straight from the bundle, sidestepping any stale icon cache.
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        Library.bootstrap()
        _ = Database.shared
        _ = AppState.shared

        // Main window
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "Snag"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(red: 0.09, green: 0.102, blue: 0.145, alpha: 1)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: MainView().environmentObject(AppState.shared))
        window.contentView = host
        window.center()
        window.makeKeyAndOrderFront(nil)

        // Menu bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "tray.and.arrow.down.fill", accessibilityDescription: "Snag")
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Snag", action: #selector(openMain), keyEquivalent: "o")
        menu.addItem(withTitle: "Show Drop Panel", action: #selector(showPanel), keyEquivalent: "")
        menu.addItem(.separator())
        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Snag", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        // Drop panel + macOS-wide drag watcher
        panelController = DropPanelController()
        dragMonitor = DragMonitor(panel: panelController)
        dragMonitor.mainWindow = window

        // Local API
        apiServer.start()

        // "Save to Snag" in the macOS Services (right-click) menu
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        // App menu (so cmd+Q, cmd+W, copy/paste work)
        buildMainMenu()

        // Right-hold mouse gestures in the preview: drag left/right switches
        // items, drag up/down zooms (Eagle's "right-click gesture").
        gestureMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .rightMouseDragged, .rightMouseUp]) { [weak self] event in
            guard let self, self.window.isKeyWindow,
                  AppState.shared.previewItemId != nil else { return event }
            let state = AppState.shared
            switch event.type {
            case .rightMouseDown:
                self.gestureAccum = .zero
                self.gestureAxis = 0
            case .rightMouseDragged:
                self.gestureAccum.x += event.deltaX
                self.gestureAccum.y += event.deltaY
                if self.gestureAxis == 0,
                   hypot(self.gestureAccum.x, self.gestureAccum.y) > 10 {
                    self.gestureAxis = abs(self.gestureAccum.x) > abs(self.gestureAccum.y) ? 1 : 2
                }
                if self.gestureAxis == 1, abs(self.gestureAccum.x) > 70 {
                    state.previewStep(self.gestureAccum.x > 0 ? 1 : -1)
                    self.gestureAccum = .zero
                } else if self.gestureAxis == 2 {
                    // Drag up (negative deltaY) zooms in.
                    state.previewZoom = min(3.0, max(0.5, state.previewZoom - event.deltaY * 0.012))
                }
            default:
                self.gestureAxis = 0
            }
            return nil // swallow right-clicks while the preview is open
        }

        // Trackpad pinch zooms the previewed image.
        magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify]) { [weak self] event in
            guard let self, self.window.isKeyWindow,
                  AppState.shared.previewItemId != nil else { return event }
            let state = AppState.shared
            state.previewZoom = min(3.0, max(0.5, state.previewZoom * (1 + event.magnification)))
            return nil
        }

        // Keyboard: space preview, arrows, esc
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.window.isKeyWindow else { return event }
            let state = AppState.shared
            // Escape closes overlays even while a text field is focused:
            // visual search first, then the preview.
            if event.keyCode == 53 {
                if state.visualSearchItem != nil {
                    self.window.makeFirstResponder(nil)
                    state.visualSearchItem = nil
                    return nil
                }
                if state.previewItemId != nil {
                    self.window.makeFirstResponder(nil)
                    state.previewItemId = nil
                    return nil
                }
                return event
            }
            let typing = NSApp.keyWindow?.firstResponder is NSTextView
            // Command shortcuts we own: Cmd+Z undoes a grid reorder, Cmd+K focuses search.
            if event.modifierFlags.contains(.command) {
                if event.keyCode == 6, !typing, state.canUndoReorder { // z
                    state.undoReorder(); return nil
                }
                if event.keyCode == 40 { // k
                    state.searchFocusToken &+= 1; return nil
                }
                return event
            }
            if typing { return event } // typing in a field
            switch event.keyCode {
            case 49: // space
                state.togglePreview(); return nil
            case 5: // g — back to the grid
                if state.previewItemId != nil { state.previewItemId = nil; return nil }
                return event
            case 123: state.previewStep(-1); return nil // left
            case 124: state.previewStep(1); return nil  // right
            case 18: state.setRating(1); return nil // 1-5 = star rating
            case 19: state.setRating(2); return nil
            case 20: state.setRating(3); return nil
            case 21: state.setRating(4); return nil
            case 23: state.setRating(5); return nil
            default: return event
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openMain(); return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // keep living in the menu bar
    }

    /// macOS Services handler: right-click a file, image, or URL anywhere → Save to Snag.
    @objc func saveToSnag(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        var saved = 0
        if let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            for url in urls {
                if (try? Library.importFile(at: url, folderId: nil)) != nil { saved += 1 }
            }
        } else if let str = pboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  str.hasPrefix("http") {
            Task { _ = try? await Library.importRemote(urlString: str, pageURL: nil, folderId: nil) }
            saved = 1
        }
        if saved == 0 {
            error.pointee = "Nothing Snag can save was selected" as NSString
        }
    }

    @objc func openSettings() {
        openMain()
        AppState.shared.showSettings = true
    }

    @objc func openMain() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc func showPanel() {
        panelController.show()
        panelController.scheduleHide(after: 6.0)
    }

    @objc func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                sender.state = .off
            } else {
                try SMAppService.mainApp.register()
                sender.state = .on
            }
        } catch {
            NSLog("Launch at login toggle failed: \(error)")
        }
    }

    private func buildMainMenu() {
        let main = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Snag", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Snag", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Snag", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        main.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        main.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenuItem.submenu = windowMenu
        main.addItem(windowMenuItem)

        NSApp.mainMenu = main
    }
}
