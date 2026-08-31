import AppKit
import SwiftUI
import ServiceManagement
import Carbon.HIToolbox
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var statusItem: NSStatusItem!
    var dragMonitor: DragMonitor!
    var panelController: DropPanelController!
    let apiServer = APIServer()
    var keyMonitor: Any?
    var gestureMonitor: Any?
    var magnifyMonitor: Any?
    let updaterController = SPUStandardUpdaterController(startingUpdater: true,
                                                         updaterDelegate: nil,
                                                         userDriverDelegate: nil)
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
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            self.backupDatabase()
            AppDelegate.installExtensionCopy()
        }

        // Optional cloud backup: only runs when R2 credentials are saved.
        if R2Sync.Config.load().isComplete {
            Task.detached(priority: .background) {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await R2Sync.shared.syncNow()
                // From here the Mac picks up phone saves on its own.
                R2Sync.shared.startPolling()
            }
        }

        // First run: enable launch-at-login so the drop panel is always
        // there. (The app being quit looks like "drag stopped working".)
        if !UserDefaults.standard.bool(forKey: "snag.loginItemOffered") {
            UserDefaults.standard.set(true, forKey: "snag.loginItemOffered")
            try? SMAppService.mainApp.register()
        }

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
        // Remember where the window was left, including which display.
        // Order matters: setFrameAutosaveName writes the CURRENT frame the
        // moment it is called, so restore first, then adopt the name.
        if !window.setFrameUsingName("SnagMainWindow") {
            window.center()
        }
        window.setFrameAutosaveName("SnagMainWindow")
        window.makeKeyAndOrderFront(nil)
        // The search field must not swallow keystrokes by default — typing
        // there happens only after a click or Cmd+K.
        DispatchQueue.main.async { self.window.makeFirstResponder(nil) }

        // Menu bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "tray.and.arrow.down.fill", accessibilityDescription: "Snag")
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Snag", action: #selector(openMain), keyEquivalent: "o")
        let updateItem = NSMenuItem(title: "Check for Updates…",
                                    action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                                    keyEquivalent: "")
        updateItem.target = updaterController
        menu.addItem(updateItem)
        menu.addItem(withTitle: "Show Drop Panel  ⌃⌥⌘B", action: #selector(showPanel), keyEquivalent: "")
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
        registerPanelHotkey()

        // Local API
        apiServer.start()

        // "Save to Snag" in the macOS Services (right-click) menu
        NSApp.servicesProvider = self
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            NSUpdateDynamicServices()
        }

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
                if self.isTextEditing {
                    state.blurTextFocus()
                    return nil
                }
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
            let typing = self.isTextEditing
            // Command shortcuts we own: Cmd+Z undoes a grid reorder, Cmd+K focuses search.
            if event.modifierFlags.contains(.command) {
                if event.keyCode == 6, !typing, state.canUndoReorder { // z
                    state.undoReorder(); return nil
                }
                if event.keyCode == 8, !typing { // c — copy asset(s)
                    if state.copySelectionToClipboard() > 0 { return nil }
                    return event
                }
                if event.keyCode == 40 { // k — toggle search focus
                    if self.isTextEditing {
                        state.blurTextFocus()
                    } else {
                        state.searchFocusToken &+= 1
                    }
                    return nil
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
            case 51, 117: // delete / forward delete -> trash the selection
                let ids = state.selectedItemIds.isEmpty
                    ? (state.selectedItem.map { Set([$0.id]) } ?? [])
                    : state.selectedItemIds
                guard !ids.isEmpty else { return event }
                if let pid = state.previewItemId, ids.contains(pid) {
                    state.previewItemId = nil
                }
                state.trashItems(ids)
                return nil
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

    /// One dated copy of the index per day, kept two weeks. The files are
    /// content-addressed and never overwritten, so the DB is the fragile part.
    private func backupDatabase() {
        let fm = FileManager.default
        let dir = Library.root.appendingPathComponent("backups")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let today = dir.appendingPathComponent("library-\(df.string(from: Date())).sqlite")
        if !fm.fileExists(atPath: today.path) {
            try? fm.copyItem(at: Library.root.appendingPathComponent("library.sqlite"), to: today)
        }
        if let old = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey]) {
            let cutoff = Date().addingTimeInterval(-14 * 86400)
            for url in old {
                if let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate,
                   created < cutoff {
                    try? fm.removeItem(at: url)
                }
            }
        }
    }

    /// SwiftUI's field editors are private classes (e.g.
    /// _SystemTextFieldFieldEditor) that are NOT NSTextView — detect text
    /// editing by class name so shortcuts never fire while typing.
    private var isTextEditing: Bool {
        guard let fr = NSApp.keyWindow?.firstResponder ?? window.firstResponder else { return false }
        if fr is NSText { return true }
        let name = String(describing: type(of: fr))
        return name.contains("Text") || name.contains("Editor")
    }

    /// Stable on-disk copy of the Chrome extension for "Load unpacked" —
    /// survives app updates, unlike a path inside the .app bundle.
    static var extensionInstallURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Snag/extension")
    }

    static func installExtensionCopy() {
        guard let bundled = Bundle.main.url(forResource: "extension", withExtension: nil) else { return }
        let dest = extensionInstallURL
        let fm = FileManager.default
        try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: dest)
        try? fm.copyItem(at: bundled, to: dest)
    }

    @objc func openSettings() {
        openMain()
        AppState.shared.activeSheet = .settings
    }

    @objc func openMain() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc func showPanel() {
        panelController.show(sticky: true)
    }

    @objc func toggleStickyPanel() {
        panelController.toggleSticky()
    }

    /// Global hotkey ⌃⌥⌘B via Carbon — works everywhere, needs no permissions.
    private func registerPanelHotkey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let me = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { me.toggleStickyPanel() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x534E_4147), id: 1) // 'SNAG'
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_B),
                                         UInt32(controlKey | optionKey | cmdKey),
                                         id, GetEventDispatcherTarget(), 0, &ref)
        NSLog("Snag hotkey register status: \(status)")
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
        let appUpdateItem = NSMenuItem(title: "Check for Updates…",
                                       action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                                       keyEquivalent: "")
        appUpdateItem.target = updaterController
        appMenu.addItem(appUpdateItem)
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
