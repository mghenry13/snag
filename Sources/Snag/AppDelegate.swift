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

    func applicationDidFinishLaunching(_ notification: Notification) {
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

        // Local API
        apiServer.start()

        // App menu (so cmd+Q, cmd+W, copy/paste work)
        buildMainMenu()

        // Keyboard: space preview, arrows, esc
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.window.isKeyWindow else { return event }
            if NSApp.keyWindow?.firstResponder is NSTextView { return event } // typing in a field
            let state = AppState.shared
            switch event.keyCode {
            case 49: // space
                state.togglePreview(); return nil
            case 53: // esc
                if state.previewItemId != nil { state.previewItemId = nil; return nil }
                return event
            case 123: state.previewStep(-1); return nil // left
            case 124: state.previewStep(1); return nil  // right
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
