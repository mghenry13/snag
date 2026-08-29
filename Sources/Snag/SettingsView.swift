import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var copied = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @ObservedObject private var r2 = R2Sync.shared
    @State private var r2AccountId = UserDefaults.standard.string(forKey: "snag.r2.accountId") ?? ""
    @State private var r2AccessKey = UserDefaults.standard.string(forKey: "snag.r2.accessKey") ?? ""
    @State private var r2SecretKey = UserDefaults.standard.string(forKey: "snag.r2.secretKey") ?? ""
    @State private var r2Bucket = UserDefaults.standard.string(forKey: "snag.r2.bucket") ?? "snag-assets"
    @State private var r2Saved = false
    @AppStorage("snag.linkCookieBrowser") private var linkCookieBrowser = ""
    @AppStorage("snag.linkCookieFile") private var linkCookieFile = ""

    private var mcpPath: String {
        // The MCP binary sits next to Snag.app in build/
        let sibling = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("snag-mcp")
        if FileManager.default.fileExists(atPath: sibling.path) { return sibling.path }
        return ("~/Claude/snag/build/snag-mcp" as NSString).expandingTildeInPath
    }

    private var registerCommand: String {
        "claude mcp add --scope user snag -- \(mcpPath)"
    }

    private let tools: [(String, String)] = [
        ("search_items", "Search the library by name, note, tag, or domain"),
        ("get_item", "One item's metadata plus its local file path"),
        ("list_folders", "The folder tree"),
        ("create_folder", "Make a folder (optionally nested)"),
        ("add_item", "Save a URL: images and videos download, pages become bookmarks"),
        ("move_item", "Move an item into a folder"),
        ("set_note", "Write the note field on an item"),
        ("add_tags", "Tag an item"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                Text("Settings").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { state.showSettings = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                        .padding(6)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18).padding(.vertical, 14)

            Rectangle().fill(Theme.divider).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // General
                    sectionLabel("General")
                    Toggle("Launch Snag at login", isOn: $launchAtLogin)
                        .font(.system(size: 12.5))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .onChange(of: launchAtLogin) { _, on in
                            if on { try? SMAppService.mainApp.register() }
                            else { try? SMAppService.mainApp.unregister() }
                        }
                    HStack(spacing: 6) {
                        Circle().fill(Color.green).frame(width: 7, height: 7)
                        Text("Local API running on 127.0.0.1:\(String(APIServer.port))")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }

                    // Chrome extension
                    sectionLabel("Chrome Extension")
                    Text("Right-click saves, Save URL, captures, and Ad Library video saving — in Chrome, Arc, or any Chromium browser.")
                        .font(.system(size: 12)).foregroundStyle(Color(white: 0.8))
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("1. Open chrome://extensions and turn on Developer mode")
                        Text("2. Click \"Load unpacked\" and pick the folder below")
                        Text("3. Pin Snag to the toolbar")
                    }
                    .font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([AppDelegate.extensionInstallURL])
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "puzzlepiece.extension").font(.system(size: 11))
                            Text("Reveal Extension Folder").font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.accent.opacity(0.4)))
                    }
                    .buttonStyle(.plain)

                    // R2 backup
                    sectionLabel("Cloud Backup (Cloudflare R2)")
                    Text("Optional. Leave empty to keep Snag fully local. With credentials, the library backs up to your own R2 bucket on launch and on demand.")
                        .font(.system(size: 12)).foregroundStyle(Color(white: 0.8))
                        .fixedSize(horizontal: false, vertical: true)
                    Group {
                        TextField("Cloudflare Account ID", text: $r2AccountId)
                        TextField("R2 Access Key ID", text: $r2AccessKey)
                        SecureField("R2 Secret Access Key", text: $r2SecretKey)
                        TextField("Bucket name", text: $r2Bucket)
                    }
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.fieldBG))
                    HStack(spacing: 8) {
                        Button {
                            var c = R2Sync.Config.load()
                            c.accountId = r2AccountId.trimmingCharacters(in: .whitespacesAndNewlines)
                            c.accessKey = r2AccessKey.trimmingCharacters(in: .whitespacesAndNewlines)
                            c.secretKey = r2SecretKey.trimmingCharacters(in: .whitespacesAndNewlines)
                            c.bucket = r2Bucket.trimmingCharacters(in: .whitespacesAndNewlines)
                            c.save()
                            r2Saved = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { r2Saved = false }
                        } label: {
                            Text(r2Saved ? "Saved" : "Save Credentials")
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 7).fill(r2Saved ? Color.green.opacity(0.3) : Theme.accent.opacity(0.4)))
                        }
                        .buttonStyle(.plain)
                        Button {
                            Task {
                                await R2Sync.shared.syncNow()
                                // One sync by hand is enough to start the
                                // background poll. No relaunch needed.
                                R2Sync.shared.startPolling()
                            }
                        } label: {
                            Text(r2.running ? "Syncing…" : "Sync Now")
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.fieldBG))
                        }
                        .buttonStyle(.plain)
                        .disabled(r2.running)
                        if !r2.status.isEmpty {
                            Text(r2.status)
                                .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }
                    }

                    // Links shared from the phone
                    sectionLabel("Links Saved From Your Phone")
                    Text("A link you share to Snag is saved as the actual video when the site allows it, and as a link card when it does not. Instagram will not serve a reel to a signed-out client, so pick the browser you are signed in to.")
                        .font(.system(size: 12)).foregroundStyle(Color(white: 0.8))
                        .fixedSize(horizontal: false, vertical: true)
                    Picker("", selection: $linkCookieBrowser) {
                        Text("Do not use browser cookies").tag("")
                        Text("Chrome").tag("chrome")
                        Text("Safari").tag("safari")
                        Text("Firefox").tag("firefox")
                        Text("Brave").tag("brave")
                        Text("Edge").tag("edge")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 240, alignment: .leading)
                    Text("Arc is not on the list because yt-dlp cannot unlock its cookies. For Arc, export a cookies.txt with a browser extension and give the path below. A file here wins over the picker.")
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("~/Downloads/cookies.txt (optional)", text: $linkCookieFile)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                    if LinkMedia.toolPath == nil {
                        Text("yt-dlp is not installed, so links stay as link cards. Install it with: brew install yt-dlp")
                            .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // MCP
                    sectionLabel("Claude MCP")
                    Text("Snag ships a local MCP server, so Claude can search and organize this library. It talks to the app's local API, so keep Snag running while you use it.")
                        .font(.system(size: 12)).foregroundStyle(Color(white: 0.8))
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Register it once with Claude Code:")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    HStack(spacing: 8) {
                        Text(registerCommand)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color(white: 0.88))
                            .lineLimit(2)
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(registerCommand, forType: .string)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                        } label: {
                            Text(copied ? "Copied" : "Copy")
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 5).fill(copied ? Color.green.opacity(0.3) : Theme.accent.opacity(0.4)))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.fieldBG))

                    Text("Already registered on this Mac. Check with `claude mcp list`, and remove with `claude mcp remove snag`.")
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Tools Claude gets")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(white: 0.85))
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(tools, id: \.0) { name, desc in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(name)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 96, alignment: .leading)
                                Text(desc)
                                    .font(.system(size: 11.5)).foregroundStyle(Color(white: 0.8))
                            }
                        }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))

                    Text("Try: \"Search my Snag for shirt mockups\" or \"Save this URL into my Inspiration folder in Snag.\"")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                        .italic()
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
            }
        }
        .frame(width: 520, height: 520)
        .background(Theme.panelBG)
    }

    @ViewBuilder
    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .kerning(0.6)
    }
}
