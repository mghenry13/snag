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
            if state.visualSearchItem != nil {
                VisualSearchOverlay()
            }
        }
        .frame(minWidth: 1100, minHeight: 640)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $state.showSettings) {
            SettingsView().environmentObject(state)
        }
    }
}

// MARK: - Toolbar

struct ToolbarView: View {
    @EnvironmentObject var state: AppState
    @FocusState private var searchFocused: Bool

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
                Toggle("Show Star Rating", isOn: $state.showRating)
            } label: {
                Image(systemName: "squareshape.split.2x2.dotted")
                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)

            Menu {
                // Flat list — no "Media Type" submenu to step through.
                ForEach(MediaFilter.allCases, id: \.self) { f in
                    Button {
                        state.mediaFilter = f
                    } label: {
                        Label(state.mediaFilter == f ? "✓ \(f.rawValue)" : f.rawValue,
                              systemImage: f.icon)
                    }
                }
            } label: {
                Image(systemName: state.mediaFilter.icon)
                    .font(.system(size: 13))
                    .foregroundStyle(state.mediaFilter == .all ? Theme.textSecondary : Theme.accent)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)

            Menu {
                Picker("Rating", selection: $state.minRating) {
                    Text("Any rating").tag(0)
                    ForEach(1...5, id: \.self) { n in
                        Text(String(repeating: "★", count: n) + (n < 5 ? " and up" : "")).tag(n)
                    }
                }
            } label: {
                Image(systemName: state.minRating > 0 ? "star.fill" : "star")
                    .font(.system(size: 13))
                    .foregroundStyle(state.minRating > 0 ? Theme.starYellow : Theme.textSecondary)
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
                    .focused($searchFocused)
                    .onChange(of: state.searchFocusToken) { _, _ in searchFocused = true }
                    .onChange(of: state.searchBlurToken) { _, _ in searchFocused = false }
                    // Escape inside the field: macOS's input system eats the
                    // key before event monitors, so handle it HERE.
                    .onExitCommand {
                        searchFocused = false
                        state.blurTextFocus()
                    }
                    .onSubmit {
                        searchFocused = false
                        state.blurTextFocus()
                    }
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
        // External file/browser drops on empty grid areas are caught by the
        // window-level catcher (AppDelegate) — a background catcher HERE would
        // compete with the per-card catchers and steal reorder drops.
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
                    let selected = state.selectedItemIds.contains(item.id)
                    HStack(spacing: 10) {
                        ThumbImage(item: item, maxPixel: 96) { img in
                            if let img {
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
                    .onTapGesture {
                        state.select(item.id, additive: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
                    }
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

    private var isSelected: Bool { state.selectedItemIds.contains(item.id) }
    @State private var insertTargeted = false
    @State private var hoverPlayer: AVPlayer? = nil
    @State private var videoHovering = false
    @State private var thumbWidth: CGFloat = 200
    @State private var hoverFrac: CGFloat = 0
    @State private var hoverSeconds: Double = 0

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                thumbnail
                if videoHovering, let hoverPlayer {
                    VideoScrubLayer(player: hoverPlayer)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .allowsHitTesting(false)
                    // Scrub bar along the bottom + timecode chip. Always muted.
                    VStack(spacing: 0) {
                        Spacer()
                        HStack {
                            Spacer()
                            Text(timecode(hoverSeconds))
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.95))
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.55)))
                                .padding(.trailing, 6).padding(.bottom, 7)
                        }
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.white.opacity(0.25))
                            Rectangle().fill(.white.opacity(0.9))
                                .frame(width: max(0, thumbWidth * hoverFrac))
                        }
                        .frame(height: 3)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .allowsHitTesting(false)
                }
                if isSelected {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Theme.accent, lineWidth: 2.5)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Theme.accent.opacity(0.10))
                        )
                        .allowsHitTesting(false)
                }
                if let chip {
                    Text(chip)
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 4.5).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.45)))
                        .padding(5)
                }
            }
            .background {
                // Geometry tracking costs a layout pass — only videos need it.
                if item.itemType == .video {
                    GeometryReader { g in
                        Color.clear.onAppear { thumbWidth = g.size.width }
                            .onChange(of: g.size.width) { _, w in thumbWidth = w }
                    }
                }
            }
            .onContinuousHover(coordinateSpace: .local) { phase in
                guard item.itemType == .video else { return }
                switch phase {
                case .active(let p):
                    if hoverPlayer == nil {
                        let pl = AVPlayer(url: Library.fileURL(for: item))
                        pl.isMuted = true
                        hoverPlayer = pl
                    }
                    videoHovering = true
                    // Hover-scrub: x position maps to the timeline. Silent.
                    if let dur = hoverPlayer?.currentItem?.duration, dur.isNumeric, dur.seconds > 0 {
                        let frac = max(0, min(1, p.x / max(thumbWidth, 1)))
                        hoverFrac = frac
                        hoverSeconds = dur.seconds * frac
                        let tol = CMTime(seconds: 0.15, preferredTimescale: 600)
                        hoverPlayer?.seek(to: CMTime(seconds: dur.seconds * frac, preferredTimescale: 600),
                                          toleranceBefore: tol, toleranceAfter: tol)
                    }
                case .ended:
                    videoHovering = false
                    hoverPlayer?.pause()
                    hoverPlayer = nil
                }
            }
            if state.showRating {
                HStack(spacing: 1.5) {
                    ForEach(1...5, id: \.self) { star in
                        Image(systemName: star <= item.rating ? "star.fill" : "star")
                            .font(.system(size: 9))
                            .foregroundStyle(star <= item.rating
                                             ? Theme.starYellow
                                             : Theme.textSecondary.opacity(0.4))
                            .onTapGesture {
                                var it = item
                                it.rating = (it.rating == star) ? 0 : star
                                state.update(it)
                            }
                    }
                }
                .padding(.top, 1)
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
        .onTapGesture {
            state.select(item.id, additive: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            state.select(item.id, additive: false)
            state.previewItemId = item.id
        })
        .contextMenu { ItemMenu(item: item) }
        .onDrag {
            // Handoff for in-app drops; the provider carries the real file so
            // dropping into Finder/Figma/Mail still delivers a copy.
            AppState.shared.draggingItemId = item.id
            AppState.shared.draggingFolderId = nil
            AppState.shared.dragActive = true
            let provider = NSItemProvider()
            let file = Library.fileURL(for: item)
            let safeName = item.name.replacingOccurrences(of: "/", with: "-")
            provider.suggestedName = "\(safeName).\(item.ext)"
            // Register under the file's OWN type (public.jpeg, public.mpeg-4…).
            // NSItemProvider(contentsOf:) advertises a URL, so receiving apps
            // dropped a link instead of the picture.
            let contentType = UTType(filenameExtension: item.ext) ?? .data
            let ext = item.ext
            provider.registerFileRepresentation(forTypeIdentifier: contentType.identifier,
                                                fileOptions: [], visibility: .all) { completion in
                // Hand over a copy named for the item, so the receiver keeps a
                // readable filename instead of the library's UUID.
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("SnagDrag-\(UUID().uuidString)")
                do {
                    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                    let dest = tmp.appendingPathComponent("\(safeName).\(ext)")
                    try FileManager.default.copyItem(at: file, to: dest)
                    completion(dest, false, nil)
                } catch {
                    completion(nil, false, error)
                }
                return nil
            }
            let id = item.id
            provider.registerDataRepresentation(forTypeIdentifier: UTType.snagItem.identifier,
                                                visibility: .all) { completion in
                completion(try? JSONEncoder().encode(["id": id]), nil)
                return nil
            }
            return provider
        }
        .overlay(alignment: .leading) {
            // Insert-before indicator for manual reordering
            if insertTargeted {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Theme.accent)
                    .frame(width: 3)
                    .offset(x: -8)
            }
        }
        // AppKit catcher so item drags (which carry file promises for
        // drag-out) land HERE for reorder instead of on the grid importer.
        // Always mounted: views added mid-drag are not reliably consulted
        // by an active drag session, and LazyVStack bounds the count anyway.
        .background(DropCatcher(
            folderId: {
                if case .folder(let id) = state.filter { return id }
                return nil
            }(),
            onTargeted: { t in insertTargeted = t },
            onInternalItem: { id in AppState.shared.reorderItem(id, before: item.id) }
        ))
    }

    private func timecode(_ s: Double) -> String {
        let m = Int(s) / 60
        let sec = s - Double(m * 60)
        return String(format: "%d:%05.2f", m, sec)
    }

    /// Subtle corner chip: real file type for media, URL only for bookmarks.
    private var chip: String? {
        switch item.itemType {
        case .url: return "URL"
        case .video, .image: return item.ext.uppercased()
        }
    }

    private var caption: String {
        if item.itemType == .url { return item.domain ?? "" }
        if item.width > 0 { return "\(item.width) × \(item.height)" }
        return item.ext.uppercased()
    }

    @ViewBuilder
    private var thumbnail: some View {
        // Selection is drawn on the OUTER stack instead: the hover-scrub
        // video layer sits above the thumbnail and would cover a ring drawn
        // in here, so selected videos looked unselected while hovered.
        let border = RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
        ThumbImage(item: item, maxPixel: 640) { img in
            if let img {
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
                .frame(width: width, height: fixedHeight ?? placeholderHeight)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(border)
            }
        }
    }

    /// Keep waterfall placeholders at the item's real aspect so nothing jumps when decodes land.
    private var placeholderHeight: CGFloat {
        guard let width else { return 140 }
        if item.width > 0 && item.height > 0 {
            let aspect = CGFloat(item.height) / CGFloat(item.width)
            return width * min(max(aspect, 0.3), 2.5)
        }
        return width * 0.72
    }
}

struct ItemMenu: View {
    @EnvironmentObject var state: AppState
    let item: Item

    var body: some View {
        let sel = state.selectedItemIds
        let bulk = sel.count > 1 && sel.contains(item.id)
        if item.deletedAt == nil, bulk {
            Button("Export \(sel.count) Items…") { exportItems(Array(sel)) }
            Menu("Move \(sel.count) to Folder") {
                Button("Uncategorized") { state.moveItems(sel, to: nil) }
                ForEach(state.folders) { f in
                    Button(f.name) { state.moveItems(sel, to: f.id) }
                }
            }
            Divider()
            Button("Move \(sel.count) to Trash", role: .destructive) { state.trashItems(sel) }
        } else if item.deletedAt == nil {
            Button("Preview") { state.select(item.id, additive: false); state.previewItemId = item.id }
            Menu("Move to Folder") {
                Button("Uncategorized") { state.moveItem(item.id, to: nil) }
                ForEach(state.folders) { f in
                    Button(f.name) { state.moveItem(item.id, to: f.id) }
                }
            }
            Button("Find Similar") {
                state.select(item.id, additive: false)
                state.visualSearchItem = item
            }
            ShareLink("Share…", item: item.itemType == .url
                      ? (item.sourceURL.flatMap { URL(string: $0) } ?? Library.fileURL(for: item))
                      : Library.fileURL(for: item))
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

    /// Copy the originals of the given items into a folder the user picks.
    private func exportItems(_ ids: [String]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        // runModal, not begin: a non-modal panel from a background/inactive
        // app can never come forward, which read as "export does nothing".
        NSApp.activate(ignoringOtherApps: true)
        let resp = panel.runModal()
        if resp == .OK, let dir = panel.url {
            var failed = 0
            for id in ids {
                guard let it = AppState.shared.items.first(where: { $0.id == id }) else { continue }
                let safeName = it.name.replacingOccurrences(of: "/", with: "-")
                var dest = dir.appendingPathComponent("\(safeName).\(it.ext)")
                var n = 2
                while FileManager.default.fileExists(atPath: dest.path) {
                    dest = dir.appendingPathComponent("\(safeName) \(n).\(it.ext)")
                    n += 1
                }
                do {
                    try FileManager.default.copyItem(at: Library.fileURL(for: it), to: dest)
                } catch {
                    failed += 1
                }
            }
            if failed > 0 {
                let a = NSAlert()
                a.messageText = "\(failed) of \(ids.count) items could not be exported."
                a.informativeText = "Their files may be missing from the library folder."
                a.runModal()
            }
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


/// Muted video layer for hover-scrub in the grid. Plain AVPlayerLayer:
/// no controls, no audio, none of the _AVKit_SwiftUI metadata crash.
final class VideoScrubNSView: NSView {
    let playerLayer = AVPlayerLayer()

    // Fully transparent to the mouse — otherwise this view eats the
    // mouse-down and video cards can no longer start drags.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

struct VideoScrubLayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> VideoScrubNSView {
        let v = VideoScrubNSView(frame: .zero)
        v.playerLayer.player = player
        return v
    }

    func updateNSView(_ v: VideoScrubNSView, context: Context) {
        if v.playerLayer.player !== player {
            v.playerLayer.player = player
        }
    }
}
