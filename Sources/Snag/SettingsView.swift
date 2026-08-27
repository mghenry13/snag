import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var copied = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

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
