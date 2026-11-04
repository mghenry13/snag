import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A round profile picture, or the account's initials when none is saved yet.
struct AvatarView: View {
    let file: String?
    let name: String
    var size: CGFloat = 18

    var body: some View {
        Group {
            if let img = AvatarCache.shared.image(file) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Circle().fill(Color(white: 0.28))
                    Text(initials).font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(Color(white: 0.85))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var initials: String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(2)
        let s = words.compactMap { $0.first.map(String.init) }.joined().uppercased()
        return s.isEmpty ? "?" : s
    }
}

/// A platform's short badge in its colour.
struct PlatformBadge: View {
    let platform: Platform
    var height: CGFloat = 14

    var body: some View {
        Text(platform.badge)
            .font(.system(size: height * 0.55, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 3)
            .frame(minWidth: height + 2, minHeight: height)
            .background(RoundedRectangle(cornerRadius: 3.5).fill(Color(hex: platform.color)))
    }
}

enum AccountActions {
    /// Ask for a new name; nil when cancelled.
    @MainActor
    static func promptRename(_ account: Account) {
        let alert = NSAlert()
        alert.messageText = "Rename Account"
        alert.informativeText = "The name shown for all of this account's profiles."
        let field = NSTextField(string: account.name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            Accounts.rename(account.id, to: field.stringValue)
        }
    }

    @MainActor
    static func confirmMerge(_ from: Account, into: Account) {
        let state = AppState.shared
        let alert = NSAlert()
        alert.messageText = "Merge “\(from.name)” into “\(into.name)”?"
        let platforms = state.profiles(of: from.id).map { "\($0.platformInfo.label) \($0.handleLabel ?? $0.displayName)" }
        alert.informativeText = "Its profiles (\(platforms.joined(separator: ", "))) will be listed under \(into.name). You can split them out again later."
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            if case .account(let shown) = state.filter, shown == from.id { state.filter = .account(into.id) }
            Accounts.merge(from.id, into: into.id)
        }
    }
}

/// The right-click menu shared by an account's sidebar row and its header.
struct AccountMenu: View {
    @EnvironmentObject var state: AppState
    let account: Account

    var body: some View {
        let profiles = state.profiles(of: account.id)
        Button("Rename…") { AccountActions.promptRename(account) }
        Menu("Merge Into") {
            ForEach(state.accounts.filter { $0.id != account.id }
                        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { other in
                Button("\(other.name)  ·  \(state.profiles(of: other.id).map(\.platformInfo.badge).joined(separator: " "))") {
                    AccountActions.confirmMerge(account, into: other)
                }
            }
        }
        if profiles.count > 1 {
            Menu("Split Out") {
                ForEach(profiles) { p in
                    Button("\(p.platformInfo.label): \(p.handleLabel ?? p.displayName)") { Accounts.split(profileId: p.id) }
                }
            }
        }
        let linked = profiles.filter { $0.url != nil }
        if !linked.isEmpty {
            Divider()
            ForEach(linked) { p in
                Button("Open \(p.platformInfo.label) Profile") {
                    if let u = p.url, let url = URL(string: u) { NSWorkspace.shared.open(url) }
                }
            }
        }
    }
}

/// Above the grid while an account is shown: who it is, where they post, and
/// one tab per platform to narrow the grid to it.
struct AccountHeader: View {
    @EnvironmentObject var state: AppState
    let account: Account

    var body: some View {
        let profiles = state.profiles(of: account.id)
        let tabs = state.platformCounts(of: account.id)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                AvatarView(file: state.avatarFile(of: account.id), name: account.name, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(account.name).font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    HStack(spacing: 6) {
                        ForEach(profiles) { p in
                            Button {
                                if let u = p.url, let url = URL(string: u) { NSWorkspace.shared.open(url) }
                            } label: {
                                HStack(spacing: 4) {
                                    PlatformBadge(platform: p.platformInfo, height: 13)
                                    Text(p.handleLabel ?? p.displayName).font(.system(size: 11))
                                        .foregroundStyle(Color(white: 0.75)).lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                            .help(p.url.map { "Open \($0)" } ?? p.platformInfo.label)
                        }
                    }
                }
                Spacer()
                Menu {
                    AccountMenu(account: account)
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 15))
                        .foregroundStyle(Theme.textSecondary)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            if tabs.count > 1 {
                HStack(spacing: 6) {
                    tab(nil, label: "All", count: state.count(for: .account(account.id)))
                    ForEach(tabs, id: \.0) { pl, n in tab(pl.rawValue, label: pl.label, count: n) }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func tab(_ platform: String?, label: String, count: Int) -> some View {
        let selected = state.accountPlatform == platform
        Button { state.accountPlatform = platform } label: {
            HStack(spacing: 5) {
                Text(label).font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                Text("\(count)").font(.system(size: 10.5)).foregroundStyle(selected ? .white.opacity(0.8) : Theme.textSecondary)
            }
            .foregroundStyle(selected ? .white : Color(white: 0.8))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(selected ? Theme.accent.opacity(0.85) : Color(white: 0.18)))
        }
        .buttonStyle(.plain)
    }
}

extension UTType {
    /// An account row being dragged onto another to merge them.
    static let snagAccount = UTType(exportedAs: "com.mh.snag.account")
}
