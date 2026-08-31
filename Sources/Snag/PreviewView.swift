import SwiftUI
import AVKit

// GatherOS-style focus view: ambient blurred backdrop from the image itself,
// floating tilt-on-hover card, side peeks for prev/next, glass details panel.
struct PreviewOverlay: View {
    @EnvironmentObject var state: AppState
    @State private var fullImage: NSImage? = nil
    @State private var player: AVPlayer? = nil

    var body: some View {
        if let item = state.previewItem {
            // Show the (instant) grid thumbnail while the full-res decode lands.
            let full = fullImage ?? ThumbCache.shared.cached(item, maxPixel: 640)
                ?? ThumbCache.shared.cached(item, maxPixel: 480)
            ZStack {
                ambientBackground(full)

                VStack(spacing: 0) {
                    topBar(item)
                    Spacer(minLength: 0)
                    HStack(spacing: 0) {
                        Spacer(minLength: 24)
                        centerCard(item, full: full)
                            .padding(.trailing, 300) // clear the details panel
                        Spacer(minLength: 24)
                    }
                    Spacer(minLength: 0)
                    navHint
                        .padding(.bottom, 14)
                        .padding(.trailing, 300)
                }

                detailsPanel(item)
            }
            .id(item.id)
            .task(id: item.id) {
                if item.itemType == .video {
                    // One player per item — recreating it on every render
                    // (the old bug) resets playback before it starts.
                    let p = AVPlayer(url: Library.fileURL(for: item))
                    player = p
                    p.play()
                } else {
                    player?.pause()
                    player = nil
                }
                let loaded = await ThumbCache.shared.load(
                    item, maxPixel: 2800, original: item.itemType == .image)
                if !Task.isCancelled { fullImage = loaded }
            }
            .onChange(of: state.previewItemId) { _, _ in
                state.previewZoom = 1.0
                fullImage = nil
                player?.pause()
                player = nil
            }
            .onDisappear {
                player?.pause()
                player = nil
            }
            .transition(.opacity)
        }
    }

    // MARK: - Ambient backdrop (image, blur 60, saturate 1.2, scale 1.18, 62% black)

    @ViewBuilder
    private func ambientBackground(_ full: NSImage?) -> some View {
        GeometryReader { geo in
            Group {
                if let full {
                    Image(nsImage: full)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    Theme.windowBG
                }
            }
            .saturation(1.2)
            .blur(radius: 60, opaque: true)
            .scaleEffect(1.18)
            .clipped()
            .overlay(Color.black.opacity(0.62))
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { state.previewItemId = nil }
    }

    // MARK: - Top bar

    @ViewBuilder
    private func topBar(_ item: Item) -> some View {
        let vis = state.visibleItems
        let idx = (vis.firstIndex { $0.id == item.id } ?? 0) + 1
        HStack(spacing: 12) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
            Text("\(idx) / \(vis.count)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))

            Spacer()

            Text("\(Int(state.previewZoom * 100))%")
                .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.7))
            Slider(value: $state.previewZoom, in: 0.5...3.0)
                .frame(width: 110).controlSize(.mini)

            Rectangle().fill(.white.opacity(0.22)).frame(width: 1, height: 16)

            // Share sheet: Messages, Mail, AirDrop... bookmarks share the
            // link, media shares the file itself.
            ShareLink(item: shareURL(item)) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            topIcon("square.and.arrow.down") { exportItem(item) }
            topIcon("trash") {
                state.trashItem(item)
                state.previewItemId = nil
            }
            topIcon("xmark") { state.previewItemId = nil }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10).padding(.bottom, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
        }
    }

    private func topIcon(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Center card (hover tilt + lift)

    @ViewBuilder
    private func centerCard(_ item: Item, full: NSImage?) -> some View {
        Group {
            if item.itemType == .video {
                PlayerHostView(player: player)
                    .aspectRatio(item.width > 0 ? CGFloat(item.width) / CGFloat(item.height) : 16/9,
                                 contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else if let full {
                Image(nsImage: full)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "link").font(.system(size: 32)).foregroundStyle(.white.opacity(0.8))
                    Text(item.name).font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                        .multilineTextAlignment(.center).frame(maxWidth: 380)
                    if let s = item.sourceURL, let url = URL(string: s) {
                        Button("Open Link") { NSWorkspace.shared.open(url) }
                    }
                }
                .padding(50)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.078, green: 0.078, blue: 0.086).opacity(0.55)))
            }
        }
        .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
        .shadow(color: .black.opacity(0.45), radius: 40, y: 30)
        .scaleEffect(state.previewZoom)
        .animation(.easeOut(duration: 0.15), value: state.previewZoom)
        .padding(.vertical, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Bottom hint

    private var navHint: some View {
        HStack(spacing: 6) {
            keyCap("←"); keyCap("→")
            Text("to navigate")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
        }
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(Capsule().fill(Color(red: 0.078, green: 0.078, blue: 0.086).opacity(0.55)))
    }

    private func keyCap(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
            .frame(width: 17, height: 17)
            .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.14)))
    }

    // MARK: - Details panel (glass, GatherOS style)

    @ViewBuilder
    private func detailsPanel(_ item: Item) -> some View {
        HStack {
            Spacer()
            DetailsPanel(item: item)
                .frame(width: 268)
                .padding(.top, 52).padding(.trailing, 16).padding(.bottom, 16)
        }
    }


    private func shareURL(_ item: Item) -> URL {
        if item.itemType == .url, let s = item.sourceURL, let url = URL(string: s) {
            return url
        }
        return Library.fileURL(for: item)
    }

    private func exportItem(_ item: Item) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(item.name.replacingOccurrences(of: "/", with: "-")).\(item.ext)"
        // runModal, not begin — see exportItems in MainView.
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: Library.fileURL(for: item), to: dest)
        } catch {
            let a = NSAlert(error: error)
            a.runModal()
        }
    }
}

struct DetailsPanel: View {
    @EnvironmentObject var state: AppState
    let item: Item
    @State private var nameDraft = ""
    @State private var noteDraft = ""
    @State private var newTag = ""
    @State private var showInfo = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Details")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Button { showInfo.toggle() } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(showInfo ? 0.9 : 0.5))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showInfo, arrowEdge: .bottom) {
                        VStack(spacing: 9) {
                            infoRow("Saved", relativeSaved)
                            if item.width > 0 {
                                infoRow("Dimensions", "\(item.width) × \(item.height)")
                            }
                            infoRow("Size", ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file))
                        }
                        .padding(.horizontal, 15).padding(.vertical, 13)
                        .frame(width: 195)
                        .environment(\.colorScheme, .dark)
                    }
                }

                // Mini preview with type badge (tilts toward the mouse)
                TiltThumb(item: item)

                // Palette dots (click to copy hex)
                if !item.palette.isEmpty {
                    PaletteRow(colors: item.palette, dotSize: 15)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.06)))
                }

                fieldLabel("Name")
                glassField {
                    TextField("Name", text: $nameDraft)
                        .textFieldStyle(.plain).font(.system(size: 12))
                        .onSubmit {
                            var it = item
                            it.name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !it.name.isEmpty { state.update(it) }
                        }
                }

                fieldLabel("URL")
                glassField {
                    HStack(spacing: 5) {
                        TextField("https://...", text: .constant(item.sourceURL ?? ""))
                            .textFieldStyle(.plain).font(.system(size: 11.5))
                            .disabled(true)
                        if let s = item.sourceURL, let url = URL(string: s) {
                            Button { NSWorkspace.shared.open(url) } label: {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                            }.buttonStyle(.plain)
                        }
                    }
                }

                glassField {
                    TextField("Add a note", text: $noteDraft, axis: .vertical)
                        .textFieldStyle(.plain).font(.system(size: 11.5))
                        .lineLimit(1...4)
                        .onSubmit {
                            var it = item; it.note = noteDraft; state.update(it)
                        }
                }

                fieldLabel("Folders", icon: "folder")
                Menu {
                    Button("Uncategorized") { state.moveItem(item.id, to: nil) }
                    ForEach(state.folders) { f in
                        Button(f.name) { state.moveItem(item.id, to: f.id) }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(folderName)
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.85))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold)).foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(.horizontal, 9).padding(.vertical, 4.5)
                    .background(Capsule().fill(.white.opacity(0.08)))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()

                fieldLabel("Tags", icon: "number")
                let tags = state.tagsByItem[item.id] ?? []
                if !tags.isEmpty {
                    FlowChipsGlass(tags: tags) { state.removeTag($0, from: item) }
                }
                glassField {
                    HStack(spacing: 5) {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                        TextField("Add", text: $newTag)
                            .textFieldStyle(.plain).font(.system(size: 11.5))
                            .onSubmit { state.addTag(newTag, to: item); newTag = "" }
                    }
                }

                // Properties
                VStack(spacing: 6) {
                    if item.width > 0 { propRow("Dimensions", "\(item.width) × \(item.height)") }
                    propRow("Size", ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file))
                    HStack {
                        Text("Rating").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.55))
                        Spacer()
                        HStack(spacing: 2) {
                            ForEach(1...5, id: \.self) { star in
                                Image(systemName: star <= item.rating ? "star.fill" : "star")
                                    .font(.system(size: 9))
                                    .foregroundStyle(star <= item.rating ? Theme.starYellow : .white.opacity(0.35))
                                    .onTapGesture {
                                        var it = item
                                        it.rating = (it.rating == star) ? 0 : star
                                        state.update(it)
                                    }
                            }
                        }
                    }
                }
                .padding(.top, 6)
            }
            .padding(13)
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 0.078, green: 0.078, blue: 0.086).opacity(0.55))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        )
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.08)))
        .environment(\.colorScheme, .dark)
        .onAppear { nameDraft = item.name; noteDraft = item.note }
        .onChange(of: item.id) { _, _ in nameDraft = item.name; noteDraft = item.note }
    }

    private var folderName: String {
        item.folderId.flatMap { fid in state.folders.first { $0.id == fid }?.name } ?? "Uncategorized"
    }

    private var relativeSaved: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: item.createdAt, relativeTo: Date())
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 11.5)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 11.5))
        }
    }

    @ViewBuilder
    private func fieldLabel(_ text: String, icon: String? = nil) -> some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon).font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
            }
            Text(text).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func glassField<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.08)))
    }

    @ViewBuilder
    private func propRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.55))
            Spacer()
            Text(value).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
        }
    }
}

/// Details-panel preview thumbnail that tilts toward the mouse (GatherOS feel).
struct TiltThumb: View {
    let item: Item
    @State private var tilt: CGPoint = .zero
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                ThumbImage(item: item, maxPixel: 600) { img in
                    if let img {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width, height: geo.size.height)
                    } else {
                        ZStack {
                            Color.white.opacity(0.06)
                            Image(systemName: "link").foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                Text(item.itemType == .url ? "URL" : item.ext.uppercased())
                    .font(.system(size: 8.5, weight: .bold)).foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 5).padding(.vertical, 2.5)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.5)))
                    .padding(6)
            }
            .overlay(
                // Light sheen that follows the mouse, GatherOS-style
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        RadialGradient(
                            colors: [.white.opacity(hovering ? 0.22 : 0), .white.opacity(0)],
                            center: UnitPoint(x: 0.5 + tilt.x * 1.4, y: 0.5 + tilt.y * 1.4),
                            startRadius: 0,
                            endRadius: max(geo.size.width, 1) * 0.75
                        )
                    )
                    .allowsHitTesting(false)
            )
            .rotation3DEffect(.degrees(Double(tilt.x) * 9), axis: (x: 0, y: 1, z: 0))
            .rotation3DEffect(.degrees(Double(-tilt.y) * 9), axis: (x: 1, y: 0, z: 0))
            .shadow(color: .black.opacity(0.3), radius: 9, y: 6)
            .animation(.easeOut(duration: 0.12), value: tilt)
            .animation(.easeOut(duration: 0.18), value: hovering)
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    hovering = true
                    tilt = CGPoint(
                        x: (p.x / max(geo.size.width, 1)) - 0.5,
                        y: (p.y / max(geo.size.height, 1)) - 0.5
                    )
                case .ended:
                    hovering = false
                    tilt = .zero
                }
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
    }

    private var aspect: CGFloat {
        item.width > 0 && item.height > 0 ? CGFloat(item.width) / CGFloat(item.height) : 4/3
    }
}

struct FlowChipsGlass: View {
    let tags: [String]
    let onRemove: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(chunked(), id: \.self) { row in
                HStack(spacing: 5) {
                    ForEach(row, id: \.self) { tag in
                        HStack(spacing: 4) {
                            Circle().fill(tagColor(tag)).frame(width: 6, height: 6)
                            Text(tag).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.85))
                            Image(systemName: "xmark")
                                .font(.system(size: 6.5, weight: .bold)).foregroundStyle(.white.opacity(0.5))
                                .onTapGesture { onRemove(tag) }
                        }
                        .padding(.horizontal, 7).padding(.vertical, 3.5)
                        .background(Capsule().fill(.white.opacity(0.08)))
                    }
                }
            }
        }
    }

    private func chunked() -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var width: CGFloat = 0
        for tag in tags {
            let w = CGFloat(tag.count) * 6.5 + 40
            if width + w > 235, !row.isEmpty { rows.append(row); row = []; width = 0 }
            row.append(tag); width += w
        }
        if !row.isEmpty { rows.append(row) }
        return rows
    }
}


/// AppKit AVPlayerView host. SwiftUI's VideoPlayer (_AVKit_SwiftUI) aborts in
/// class-metadata setup on this macOS build — the plain AppKit view is stable.
struct PlayerHostView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .floating
        v.showsFullScreenToggleButton = false
        v.player = player
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player {
            v.player = player
        }
    }
}
