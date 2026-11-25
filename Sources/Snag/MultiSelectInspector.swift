import SwiftUI

/// The inspector when several items are selected: what is in the selection,
/// every Snag ID in it ready to copy in one click, and the actions that work
/// on all of them at once.
struct MultiSelectInspector: View {
    @EnvironmentObject var state: AppState
    let ids: Set<String>

    /// How the IDs are copied. References (`Snag item <id> "Name"`) are what a
    /// chat with the Snag MCP connected understands; the others are for
    /// scripts, spreadsheets and the API.
    enum IDFormat: String, CaseIterable, Identifiable {
        case references, lines, commas, json
        var id: String { rawValue }
        var label: String {
            switch self {
            case .references: return "References"
            case .lines: return "IDs, one per line"
            case .commas: return "IDs, comma-separated"
            case .json: return "JSON array"
            }
        }
        var short: String {
            switch self {
            case .references: return "References"
            case .lines: return "Lines"
            case .commas: return "Commas"
            case .json: return "JSON"
            }
        }
    }

    @AppStorage("multiSelectIDFormat") private var formatRaw = IDFormat.references.rawValue
    @State private var copied = false
    @State private var copiedRow: String? = nil
    @State private var itemsCopied = false
    @State private var newTag = ""
    @State private var hovered: String? = nil

    private var format: IDFormat { IDFormat(rawValue: formatRaw) ?? .references }

    /// The selection in the order the grid shows it, then anything selected
    /// that the current view no longer shows.
    private var selected: [Item] {
        let shown = state.visibleItems.filter { ids.contains($0.id) }
        let shownIds = Set(shown.map(\.id))
        let rest = ids.subtracting(shownIds).compactMap { state.lookup($0) }
            .sorted { $0.createdAt > $1.createdAt }
        return shown + rest
    }

    var body: some View {
        let all = selected
        // Files from the Files browser aren't library items and have no Snag ID.
        let library = all.filter { !ExternalFiles.isExternal($0.id) }
        let files = all.count - library.count

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(all)
                mosaic(all)

                if !library.isEmpty {
                    idsSection(library, files: files)
                    tagsSection(library)
                    folderSection(library)
                }
                actions(all, library: library)
            }
            .padding(14)
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func header(_ all: [Item]) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(all.count) items selected")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(white: 0.92))
                Text(summary(all))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Deselect") {
                state.selectedItemIds = []
                state.selectedItemId = nil
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(Theme.textSecondary)
            .help("Clear the selection")
        }
    }

    private func summary(_ all: [Item]) -> String {
        var kinds: [String: Int] = [:]
        for it in all {
            let k = it.itemType == .url ? "URL" : (it.ext.isEmpty ? "File" : it.ext.uppercased())
            kinds[k, default: 0] += 1
        }
        let types = kinds.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(4).map { "\($0.value) \($0.key)" }.joined(separator: " · ")
        let bytes = all.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return types.isEmpty ? size : "\(types) — \(size)"
    }

    // MARK: - Thumbnails

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 4)
    private let shownThumbs = 12

    @ViewBuilder
    private func mosaic(_ all: [Item]) -> some View {
        let extra = all.count - shownThumbs
        let thumbs = Array(all.prefix(extra > 0 ? shownThumbs - 1 : shownThumbs))
        LazyVGrid(columns: columns, spacing: 5) {
            ForEach(thumbs) { item in thumb(item) }
            if extra > 0 {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(Theme.cardBG)
                    Text("+\(extra + 1)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .aspectRatio(1, contentMode: .fit)
            }
        }
    }

    @ViewBuilder
    private func thumb(_ item: Item) -> some View {
        ThumbImage(item: item, maxPixel: 160) { img in
            ZStack {
                Theme.cardBG
                if let img {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: item.itemType == .url ? "link" : "photo")
                        .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .topTrailing) {
            if hovered == item.id {
                // Take this one out of the selection.
                Button {
                    state.select(item.id, additive: true)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 15, height: 15)
                        .background(Circle().fill(Color.black.opacity(0.7)))
                }
                .buttonStyle(.plain)
                .padding(3)
                .help("Remove from selection")
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? item.id : (hovered == item.id ? nil : hovered) }
        .onTapGesture { state.select(item.id, additive: false) }
        .help(item.name.isEmpty ? item.id : item.name)
    }

    // MARK: - Snag IDs

    @ViewBuilder
    private func idsSection(_ items: [Item], files: Int) -> some View {
        HStack {
            sectionHeader("Snag IDs")
            Spacer()
            Menu {
                Picker("Copy as", selection: $formatRaw) {
                    ForEach(IDFormat.allCases) { f in Text(f.label).tag(f.rawValue) }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 3) {
                    Text(format.short).font(.system(size: 10.5))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 7))
                }
                .foregroundStyle(Theme.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("How the IDs are copied")
        }
        .padding(.top, 4)

        // Every ID; click a row to copy just that one.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in idRow(item) }
            }
        }
        .frame(maxHeight: 190)
        .fixedSize(horizontal: false, vertical: items.count < 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.fieldBG))
        .clipShape(RoundedRectangle(cornerRadius: 7))

        Button {
            copyIDs(items)
        } label: {
            HStack(spacing: 6) {
                Spacer()
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11, weight: .semibold))
                Text(copied ? "Copied \(items.count) IDs" : "Copy \(items.count) IDs")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(.white)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 7).fill(copied ? Color.green.opacity(0.75) : Theme.accent))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("c", modifiers: [.command, .shift])
        .help(format == .references
              ? "Copies lines like “Snag item <id> \"Name\"” to paste into a chat with the Snag MCP (⇧⌘C)"
              : "Copies the IDs as \(format.label.lowercased()) (⇧⌘C)")

        if files > 0 {
            Text("\(files) selected file\(files == 1 ? "" : "s") from Files \(files == 1 ? "isn't" : "aren't") in the library and \(files == 1 ? "has" : "have") no Snag ID.")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    @ViewBuilder
    private func idRow(_ item: Item) -> some View {
        let done = copiedRow == item.id
        Button {
            copy(text(for: [item]))
            copiedRow = item.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if copiedRow == item.id { copiedRow = nil }
            }
        } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.id)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Color(white: 0.85))
                        .lineLimit(1).truncationMode(.middle)
                    if !item.name.isEmpty {
                        Text(item.name)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: done ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9.5))
                    .foregroundStyle(done ? Color.green : Theme.textSecondary)
                    .opacity(done || hovered == "row:" + item.id ? 1 : 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(hovered == "row:" + item.id ? Color.white.opacity(0.05) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? "row:" + item.id : (hovered == "row:" + item.id ? nil : hovered) }
        .help("Copy this ID")
    }

    private func text(for items: [Item]) -> String {
        switch format {
        case .references: return items.map(SnagReference.line).joined(separator: "\n")
        case .lines: return items.map(\.id).joined(separator: "\n")
        case .commas: return items.map(\.id).joined(separator: ", ")
        case .json: return "[" + items.map { "\"\($0.id)\"" }.joined(separator: ", ") + "]"
        }
    }

    private func copy(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    private func copyIDs(_ items: [Item]) {
        copy(text(for: items))
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

    // MARK: - Tags and folder

    @ViewBuilder
    private func tagsSection(_ items: [Item]) -> some View {
        sectionHeader("Tags")
        // Tags every selected item already has; removing one removes it from all.
        let common = items.dropFirst().reduce(Set(state.tagsByItem[items[0].id] ?? [])) {
            $0.intersection(state.tagsByItem[$1.id] ?? [])
        }
        if !common.isEmpty {
            FlowChips(tags: common.sorted()) { tag in
                for it in items { state.removeTag(tag, from: it) }
            }
        }
        HStack(spacing: 6) {
            Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            TextField("Tag all \(items.count)", text: $newTag)
                .textFieldStyle(.plain).font(.system(size: 11.5))
                .onSubmit {
                    let tag = newTag
                    newTag = ""
                    for it in items { state.addTag(tag, to: it) }
                }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.fieldBG))
    }

    @ViewBuilder
    private func folderSection(_ items: [Item]) -> some View {
        sectionHeader("Folder")
        let folderIds = Set(items.map { $0.folderId ?? "" })
        let label: String = {
            guard folderIds.count == 1, let only = folderIds.first else { return "Mixed" }
            return only.isEmpty ? "Uncategorized"
                : (state.folders.first { $0.id == only }?.name ?? "Uncategorized")
        }()
        let set = Set(items.map(\.id))
        Menu {
            Button("Uncategorized") { state.moveItems(set, to: nil) }
            ForEach(state.folders) { f in
                Button(f.name) { state.moveItems(set, to: f.id) }
            }
        } label: {
            HStack {
                Image(systemName: "folder").font(.system(size: 11))
                Text(label).font(.system(size: 11.5))
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8))
            }
            .foregroundStyle(Color(white: 0.85))
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.fieldBG))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    // MARK: - Actions

    @ViewBuilder
    private func actions(_ all: [Item], library: [Item]) -> some View {
        HStack(spacing: 6) {
            actionButton(itemsCopied ? "Copied" : "Copy", icon: itemsCopied ? "checkmark" : "doc.on.clipboard") {
                state.copyToClipboard(all)
                itemsCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { itemsCopied = false }
            }
            .help("Copy the \(all.count) items themselves, to paste into another app")
            if !library.isEmpty {
                actionButton("Export", icon: "square.and.arrow.up") {
                    Exporter.exportMany(library)
                }
                .help("Export \(library.count) items")
            }
        }
        .padding(.top, 4)

        Button(role: .destructive) {
            state.trashItems(Set(all.map(\.id)))
        } label: {
            HStack {
                Spacer()
                Image(systemName: "trash").font(.system(size: 11))
                Text("Move \(all.count) to Trash").font(.system(size: 12, weight: .medium))
                Spacer()
            }
            .foregroundStyle(Color(red: 0.95, green: 0.45, blue: 0.45))
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.fieldBG))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func actionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Spacer()
                Image(systemName: icon).font(.system(size: 11))
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
            }
            .foregroundStyle(Color(white: 0.88))
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.fieldBG))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
    }
}
