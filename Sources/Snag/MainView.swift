import SwiftUI
import AVKit
import UniformTypeIdentifiers

struct MainView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                SidebarView()
                    .frame(width: 230)
                    .background(Theme.sidebarBG)
                Rectangle().fill(Theme.divider).frame(width: 1)
                VStack(spacing: 0) {
                    ToolbarView()
                    Rectangle().fill(Theme.divider).frame(height: 1)
                    if state.filter == .allTags {
                        TagCloudView()
                    } else {
                        GridView()
                    }
                }
                .background(Theme.windowBG)
                Rectangle().fill(Theme.divider).frame(width: 1)
                InspectorView()
                    .frame(width: 252)
                    .background(Theme.inspectorBG)
            }
            if state.previewItem != nil {
                PreviewOverlay()
            }
        }
        .frame(minWidth: 1100, minHeight: 640)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Toolbar

struct ToolbarView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left").foregroundStyle(Theme.textSecondary)
                Image(systemName: "chevron.right").foregroundStyle(Theme.textSecondary.opacity(0.4))
            }
            .font(.system(size: 12, weight: .semibold))

            Text(state.filterTitle)
                .font(.system(size: 13, weight: .semibold))

            Spacer()

            HStack(spacing: 8) {
                Image(systemName: "minus")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textSecondary)
                Slider(value: $state.zoom, in: 120...340)
                    .frame(width: 110).controlSize(.mini)
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            Menu {
                Picker("Layout", selection: $state.layout) {
                    ForEach(GridLayout.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("Sort by", selection: $state.sortBy) {
                    ForEach(SortBy.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Toggle("Show Name", isOn: $state.showName)
            } label: {
                Image(systemName: "squareshape.split.2x2.dotted")
                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)

            if case .trash = state.filter {
                Button("Empty Trash") { state.emptyTrash() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                TextField("Search", text: $state.searchText)
                    .textFieldStyle(.plain).font(.system(size: 12.5))
                if !state.searchText.isEmpty {
                    Button { state.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.fieldBG))
            .frame(width: 210)
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
    }
}

// MARK: - Grid (waterfall / grid / list)

struct GridView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let items = state.visibleItems
        Group {
            if items.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.system(size: 34)).foregroundStyle(Theme.textSecondary.opacity(0.5))
                    Text(state.searchText.isEmpty ? "Nothing here yet. Drag anything in." : "No results")
                        .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                switch state.layout {
                case .waterfall: WaterfallView(items: items)
                case .grid: UniformGridView(items: items)
                case .list: ListLayoutView(items: items)
                }
            }
        }
        .onDrop(of: [UTType.fileURL, UTType.url, UTType.image], isTargeted: nil) { providers in
            var folderId: String? = nil
            if case .folder(let id) = state.filter { folderId = id }
            DropImporter.importProviders(providers, folderId: folderId) { _ in }
            return true
        }
    }
}

struct WaterfallView: View {
    @EnvironmentObject var state: AppState
    let items: [Item]

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 14
            let padding: CGFloat = 18
            let usable = geo.size.width - padding * 2
            let cols = max(2, Int((usable + spacing) / (state.zoom + spacing)))
            let colWidth = (usable - spacing * CGFloat(cols - 1)) / CGFloat(cols)
            let columns = distribute(items, into: cols, width: colWidth)
            ScrollView {
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(0..<cols, id: \.self) { c in
                        LazyVStack(spacing: 18) {
                            ForEach(columns[c]) { item in
                                ItemCard(item: item, width: colWidth)
                            }
                        }
                    }
                }
                .padding(padding)
            }
        }
    }

    private func distribute(_ items: [Item], into cols: Int, width: CGFloat) -> [[Item]] {
        var columns: [[Item]] = Array(repeating: [], count: cols)
        var heights = Array(repeating: CGFloat(0), count: cols)
        for item in items {
            let aspect = item.width > 0 && item.height > 0 ? CGFloat(item.height) / CGFloat(item.width) : 0.75
            let h = width * min(max(aspect, 0.3), 2.5) + 44
            let target = heights.firstIndex(of: heights.min() ?? 0) ?? 0
            columns[target].append(item)
            heights[target] += h
        }
        return columns
    }
}

struct UniformGridView: View {
    @EnvironmentObject var state: AppState
    let items: [Item]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: state.zoom, maximum: state.zoom * 1.6), spacing: 16)],
                      alignment: .leading, spacing: 20) {
                ForEach(items) { item in
                    ItemCard(item: item, width: nil, fixedHeight: state.zoom * 0.72)
                }
            }
            .padding(18)
        }
    }
}

struct ListLayoutView: View {
    @EnvironmentObject var state: AppState
    let items: [Item]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(items) { item in
                    let selected = state.selectedItemId == item.id
                    HStack(spacing: 10) {
                        Group {
                            if let img = ThumbCache.shared.thumbnail(for: item) {
                                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                            } else {
                                ZStack { Theme.cardBG; Image(systemName: "photo").font(.system(size: 11)).foregroundStyle(Theme.textSecondary) }
                            }
                        }
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 5))

                        Text(item.name).font(.system(size: 12.5)).lineLimit(1)
                        Spacer()
                        if item.rating > 0 {
                            HStack(spacing: 1) {
                                ForEach(0..<item.rating, id: \.self) { _ in
                                    Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(Theme.starYellow)
                                }
                            }
                        }
                        Text(item.itemType == .url ? (item.domain ?? "URL") : "\(item.width) × \(item.height)")
                            .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                            .frame(width: 110, alignment: .trailing)
                        Text(ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file))
                            .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                            .frame(width: 70, alignment: .trailing)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.accent.opacity(0.35) : .clear))
                    .contentShape(Rectangle())
                    .onTapGesture { state.selectedItemId = item.id }
                    .contextMenu { ItemMenu(item: item) }
                }
            }
            .padding(10)
        }
    }
}

// MARK: - Card

struct ItemCard: View {
    @EnvironmentObject var state: AppState
    let item: Item
    var width: CGFloat? = nil
    var fixedHeight: CGFloat? = nil

    private var isSelected: Bool { state.selectedItemId == item.id }

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            ZStack(alignment: .topLeading) {
                thumbnail
                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2.5)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.55)))
                        .padding(7)
                }
            }
            if state.showName {
                Text(item.name)
                    .font(.system(size: 11.5)).lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(isSelected ? Color.white : Color(white: 0.85))
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(isSelected ? Theme.accent.opacity(0.85) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                Text(caption)
                    .font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { state.selectedItemId = item.id }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            state.selectedItemId = item.id
            state.previewItemId = item.id
        })
        .contextMenu { ItemMenu(item: item) }
        .draggable(item.id)
    }

    private var badge: String? {
        if item.itemType == .url { return item.isYouTube ? "Youtube" : "URL" }
        if item.ext == "svg" { return "SVG" }
        if item.itemType == .video { return item.ext.uppercased() }
        return nil
    }

    private var caption: String {
        if item.itemType == .url { return item.domain ?? "" }
        if item.width > 0 { return "\(item.width) × \(item.height)" }
        return item.ext.uppercased()
    }

    @ViewBuilder
    private var thumbnail: some View {
        let border = RoundedRectangle(cornerRadius: 8)
            .strokeBorder(isSelected ? Theme.accent : Color.white.opacity(0.07),
                          lineWidth: isSelected ? 2.5 : 1)
        if let img = ThumbCache.shared.thumbnail(for: item) {
            if let fixedHeight {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity).frame(height: fixedHeight)
                    .background(Theme.cardBG)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(border)
            } else {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: width)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(border)
            }
        } else {
            ZStack {
                Theme.cardBG
                VStack(spacing: 6) {
                    Image(systemName: item.itemType == .url ? "link" : "photo")
                        .font(.system(size: 22)).foregroundStyle(Theme.textSecondary)
                    Text(item.itemType == .url ? (item.domain ?? "URL") : item.ext.uppercased())
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(width: width, height: fixedHeight ?? (width.map { $0 * 0.72 } ?? 140))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(border)
        }
    }
}

struct ItemMenu: View {
    @EnvironmentObject var state: AppState
    let item: Item

    var body: some View {
        if item.deletedAt == nil {
            Button("Preview") { state.selectedItemId = item.id; state.previewItemId = item.id }
            Menu("Move to Folder") {
                Button("Uncategorized") { state.moveItem(item.id, to: nil) }
                ForEach(state.folders) { f in
                    Button(f.name) { state.moveItem(item.id, to: f.id) }
                }
            }
            Menu("Find Similar") {
                Button("Search Pinterest") {
                    let q = item.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                    if let url = URL(string: "https://www.pinterest.com/search/pins/?q=\(q)") {
                        NSWorkspace.shared.open(url)
                    }
                }
                if let src = item.sourceURL, item.itemType == .image {
                    Button("Google Lens (by source)") {
                        let q = src.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                        if let url = URL(string: "https://lens.google.com/uploadbyurl?url=\(q)") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([Library.fileURL(for: item)])
            }
            if let s = item.sourceURL, let url = URL(string: s) {
                Button("Open Source Link") { NSWorkspace.shared.open(url) }
            }
            Divider()
            Button("Move to Trash", role: .destructive) { state.trashItem(item) }
        } else {
            Button("Restore") { state.restoreItem(item) }
        }
    }
}

// MARK: - Tag cloud (All Tags view)

struct TagCloudView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Tags (\(state.allTags.count))")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    .padding(.bottom, 4)
                let counts = tagCounts()
                FlowLayoutTags(tags: state.allTags.map(\.name)) { name in
                    Button {
                        state.filter = .all
                        state.searchText = name
                    } label: {
                        HStack(spacing: 5) {
                            Circle().fill(tagColor(name)).frame(width: 7, height: 7)
                            Text(name).font(.system(size: 12))
                            Text("\(counts[name] ?? 0)")
                                .font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5.5)
                        .background(Capsule().fill(Theme.fieldBG))
                    }
                    .buttonStyle(.plain)
                }
                if state.allTags.isEmpty {
                    Text("No tags yet. Add one in the inspector.")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                        .padding(.top, 30)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
        }
    }

    private func tagCounts() -> [String: Int] {
        var out: [String: Int] = [:]
        for names in state.tagsByItem.values {
            for n in names { out[n, default: 0] += 1 }
        }
        return out
    }
}

func tagColor(_ name: String) -> Color {
    let palette: [Color] = [
        Color(hex: "#E8B93E"), Color(hex: "#5BB98C"), Color(hex: "#4DA6C9"),
        Color(hex: "#B47ADE"), Color(hex: "#E8734A"), Color(hex: "#5B7DE8"),
        Color(hex: "#C95B76"), Color(hex: "#7BC950"),
    ]
    var h = 5381
    for c in name.unicodeScalars { h = ((h << 5) &+ h) &+ Int(c.value) }
    return palette[abs(h) % palette.count]
}

struct FlowLayoutTags<Content: View>: View {
    let tags: [String]
    @ViewBuilder let content: (String) -> Content

    var body: some View {
        var rows: [[String]] = []
        var row: [String] = []
        var width: CGFloat = 0
        for tag in tags {
            let w = CGFloat(tag.count) * 7 + 60
            if width + w > 640, !row.isEmpty { rows.append(row); row = []; width = 0 }
            row.append(tag); width += w
        }
        if !row.isEmpty { rows.append(row) }
        return VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                HStack(spacing: 7) { ForEach(r, id: \.self) { content($0) } }
            }
        }
    }
}

// MARK: - Spacebar preview

struct PreviewOverlay: View {
    @EnvironmentObject var state: AppState
    @State private var zoomLevel: CGFloat = 1.0

    var body: some View {
        if let item = state.previewItem {
            ZStack {
                Color.black.opacity(0.88)
                    .ignoresSafeArea()
                    .onTapGesture { state.previewItemId = nil }

                Group {
                    if item.itemType == .video {
                        VideoPlayer(player: AVPlayer(url: Library.fileURL(for: item)))
                    } else if let img = fullImage(item) {
                        ScrollView([.horizontal, .vertical], showsIndicators: false) {
                            Image(nsImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 900 * zoomLevel, height: 620 * zoomLevel)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "link").font(.system(size: 30)).foregroundStyle(.white)
                            Text(item.name).foregroundStyle(.white)
                            if let s = item.sourceURL, let url = URL(string: s) {
                                Button("Open Link") { NSWorkspace.shared.open(url) }
                            }
                        }
                    }
                }
                .padding(50)

                VStack {
                    HStack {
                        Spacer()
                        Button { state.previewItemId = nil } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                                .padding(9)
                                .background(Circle().fill(Color.white.opacity(0.12)))
                        }.buttonStyle(.plain)
                    }
                    .padding(16)
                    Spacer()
                    HStack(spacing: 10) {
                        Text("Space")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.14)))
                        navButton("chevron.left") { state.previewStep(-1) }
                        navButton("chevron.right") { state.previewStep(1) }
                        Slider(value: $zoomLevel, in: 0.5...3.5).frame(width: 110).controlSize(.mini)
                        Text("\(Int(zoomLevel * 100))%")
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.8))
                            .frame(width: 42, alignment: .leading)
                    }
                    .padding(.bottom, 26)
                }
            }
            .id(item.id)
            .onChange(of: state.previewItemId) { _, _ in zoomLevel = 1.0 }
        }
    }

    private func navButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.14)))
        }.buttonStyle(.plain)
    }

    private func fullImage(_ item: Item) -> NSImage? {
        NSImage(contentsOf: Library.fileURL(for: item)) ?? ThumbCache.shared.thumbnail(for: item)
    }
}
