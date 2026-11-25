import SwiftUI

/// Every account the library has saved from, as cards: picture, name, where
/// they post, how much is saved from them, and their latest saves. Search,
/// sort and narrow by platform; click a card to see everything from it.
struct AccountBrowserView: View {
    @EnvironmentObject var state: AppState

    enum Sort: String, CaseIterable, Identifiable {
        case most = "Most Saved"
        case recent = "Recently Saved"
        case name = "Name"
        var id: String { rawValue }
    }

    @AppStorage("snag.accounts.sort") private var sortRaw = Sort.most.rawValue
    @State private var query = ""
    @State private var platform: Platform? = nil
    @State private var hovered: String? = nil

    private var sort: Sort { Sort(rawValue: sortRaw) ?? .most }

    /// One pass over the library: each account's items, newest first.
    private func itemsByAccount() -> [String: [Item]] {
        var out: [String: [Item]] = [:]
        for item in state.items {
            guard let acct = state.profile(for: item)?.accountId else { continue }
            out[acct, default: []].append(item)
        }
        for (k, v) in out { out[k] = v.sorted { $0.createdAt > $1.createdAt } }
        return out
    }

    var body: some View {
        let byAccount = itemsByAccount()
        let present = Platform.tabOrder.filter { p in
            state.accounts.contains { a in state.profiles(of: a.id).contains { $0.platformInfo == p } }
        }
        let shown = filtered(byAccount)

        VStack(spacing: 0) {
            controls(present: present, count: shown.count)
            Rectangle().fill(Theme.divider).frame(height: 1)
            if shown.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "person.2")
                        .font(.system(size: 30)).foregroundStyle(Theme.textSecondary.opacity(0.5))
                    Text(state.accounts.isEmpty
                         ? "No accounts yet. Saves from Instagram, TikTok, Pinterest and others add who posted them."
                         : "No accounts match")
                        .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding(30)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 16)],
                              spacing: 16) {
                        ForEach(shown) { account in
                            card(account, items: byAccount[account.id] ?? [])
                        }
                    }
                    .padding(18)
                }
            }
        }
    }

    private func filtered(_ byAccount: [String: [Item]]) -> [Account] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var list = state.accounts.filter { a in
            let profiles = state.profiles(of: a.id)
            if let platform, !profiles.contains(where: { $0.platformInfo == platform }) { return false }
            if q.isEmpty { return true }
            return a.name.lowercased().contains(q)
                || profiles.contains { $0.handle.lowercased().contains(q) || $0.name.lowercased().contains(q) }
        }
        switch sort {
        case .most:
            list.sort { (byAccount[$0.id]?.count ?? 0) > (byAccount[$1.id]?.count ?? 0) }
        case .recent:
            list.sort { (byAccount[$0.id]?.first?.createdAt ?? .distantPast) > (byAccount[$1.id]?.first?.createdAt ?? .distantPast) }
        case .name:
            list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return list
    }

    // MARK: - Search, platforms, sort

    @ViewBuilder
    private func controls(present: [Platform], count: Int) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                TextField("Search accounts", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 12))
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.fieldBG))
            .frame(maxWidth: 240)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    chip(nil, label: "All")
                    ForEach(present, id: \.self) { p in chip(p, label: p.label) }
                }
            }

            Spacer(minLength: 6)
            Text("\(count) account\(count == 1 ? "" : "s")")
                .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                .fixedSize()
            Menu {
                Picker("Sort", selection: $sortRaw) {
                    ForEach(Sort.allCases) { s in Text(s.rawValue).tag(s.rawValue) }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down").font(.system(size: 10))
                    Text(sort.rawValue).font(.system(size: 11.5))
                }
                .foregroundStyle(Color(white: 0.85))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
    }

    private func chip(_ p: Platform?, label: String) -> some View {
        let on = platform == p
        return Button { platform = p } label: {
            HStack(spacing: 5) {
                if let p { Circle().fill(Color(hex: p.color)).frame(width: 6, height: 6) }
                Text(label).font(.system(size: 11.5))
            }
            .foregroundStyle(on ? .white : Color(white: 0.8))
            .padding(.horizontal, 9).padding(.vertical, 4.5)
            .background(Capsule().fill(on ? Theme.accent.opacity(0.85) : Theme.fieldBG))
        }
        .buttonStyle(.plain)
    }

    // MARK: - A card

    @ViewBuilder
    private func card(_ account: Account, items: [Item]) -> some View {
        let profiles = state.profiles(of: account.id)
        let isHovered = hovered == account.id
        VStack(alignment: .leading, spacing: 0) {
            // Their latest saves.
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    if i < items.count {
                        ThumbImage(item: items[i], maxPixel: 240) { img in
                            ZStack {
                                Theme.fieldBG
                                if let img {
                                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    Image(systemName: items[i].itemType == .url ? "link" : "photo")
                                        .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity).frame(height: 96)
                        .clipped()
                    } else {
                        Theme.fieldBG.frame(maxWidth: .infinity).frame(height: 96)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 9) {
                    AvatarView(file: state.avatarFile(of: account.id), name: account.name, size: 38)
                        .overlay(Circle().strokeBorder(Theme.cardBG, lineWidth: 2.5))
                        .padding(.top, -24)
                    Spacer()
                    Text("\(items.count) saved")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
                }
                Text(account.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(white: 0.93))
                    .lineLimit(1)
                // Each place they post: badge and handle.
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(profiles.sorted { (Platform.tabOrder.firstIndex(of: $0.platformInfo) ?? 99) < (Platform.tabOrder.firstIndex(of: $1.platformInfo) ?? 99) }) { p in
                        HStack(spacing: 5) {
                            PlatformBadge(platform: p.platformInfo, height: 12)
                            Text(p.handleLabel ?? p.platformInfo.label)
                                .font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if isHovered, let u = p.url, let url = URL(string: u) {
                                Button { NSWorkspace.shared.open(url) } label: {
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
                                }
                                .buttonStyle(.plain)
                                .help("Open \(p.platformInfo.label) profile")
                            }
                        }
                    }
                }
                if let last = items.first?.createdAt {
                    Text("Last saved \(Self.relative(last))")
                        .font(.system(size: 10)).foregroundStyle(Theme.textSecondary.opacity(0.8))
                }
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 12)
        }
        .background(Theme.cardBG)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(isHovered ? Theme.accent.opacity(0.7) : Color.white.opacity(0.06), lineWidth: 1))
        .scaleEffect(isHovered ? 1.015 : 1)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? account.id : (hovered == account.id ? nil : hovered) }
        .onTapGesture {
            state.blurTextFocus()
            state.filter = .account(account.id)
        }
        .contextMenu { AccountMenu(account: account).environmentObject(state) }
        .help("Show everything from \(account.name)")
    }

    private static func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }
}
