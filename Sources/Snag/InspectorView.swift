import SwiftUI

struct InspectorView: View {
    @EnvironmentObject var state: AppState
    @State private var titleDraft = ""
    @State private var noteDraft = ""
    @State private var newTag = ""

    var body: some View {
        Group {
            if let item = state.selectedItem {
                inspector(for: item)
            } else {
                VStack {
                    Spacer()
                    Text("Select an item")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private func inspector(for item: Item) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Preview
                ZStack(alignment: .topLeading) {
                    ThumbImage(item: item, maxPixel: 520) { img in
                        if let img {
                            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                        } else {
                            ZStack {
                                Theme.cardBG
                                Image(systemName: item.itemType == .url ? "link" : "photo")
                                    .font(.system(size: 26)).foregroundStyle(Theme.textSecondary)
                            }
                            .frame(height: 130)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    if item.itemType == .url {
                        Text("URL").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2.5)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.55)))
                            .padding(7)
                    }
                }

                // Palette (click a dot to copy its hex)
                if !item.palette.isEmpty {
                    PaletteRow(colors: item.palette)
                }

                // Title
                TextField("Title", text: $titleDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .lineLimit(1...3)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.fieldBG))
                    .onSubmit { commitTitle(item) }

                // Notes
                TextField("Notes...", text: $noteDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .lineLimit(2...6)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.fieldBG))
                    .onSubmit { commitNote(item) }

                // Source URL
                if let src = item.sourceURL {
                    HStack(spacing: 6) {
                        Text(src).font(.system(size: 11)).lineLimit(1)
                            .foregroundStyle(Color(white: 0.8))
                        Spacer()
                        Button {
                            if let url = URL(string: src) { NSWorkspace.shared.open(url) }
                        } label: {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        }.buttonStyle(.plain)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.fieldBG))
                }

                sectionHeader("Tags")
                let tags = state.tagsByItem[item.id] ?? []
                FlowChips(tags: tags) { tag in state.removeTag(tag, from: item) }
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    TextField("New tag", text: $newTag)
                        .textFieldStyle(.plain).font(.system(size: 11.5))
                        .onSubmit {
                            state.addTag(newTag, to: item); newTag = ""
                        }
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.fieldBG))

                sectionHeader("Folders")
                Menu {
                    Button("Uncategorized") { state.moveItem(item.id, to: nil) }
                    ForEach(state.folders) { f in
                        Button(f.name) { state.moveItem(item.id, to: f.id) }
                    }
                } label: {
                    HStack {
                        Image(systemName: "folder").font(.system(size: 11))
                        Text(folderName(item)).font(.system(size: 11.5))
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 8))
                    }
                    .foregroundStyle(Color(white: 0.85))
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.fieldBG))
                }
                .menuStyle(.borderlessButton)

                sectionHeader("Properties")
                VStack(spacing: 7) {
                    propRow("Rating") {
                        HStack(spacing: 2) {
                            ForEach(1...5, id: \.self) { star in
                                Image(systemName: star <= item.rating ? "star.fill" : "star")
                                    .font(.system(size: 10))
                                    .foregroundStyle(star <= item.rating ? Color.yellow : Theme.textSecondary)
                                    .onTapGesture {
                                        var it = item
                                        it.rating = (it.rating == star) ? 0 : star
                                        state.update(it)
                                    }
                            }
                        }
                    }
                    if item.width > 0 {
                        propRow("Dimensions") { Text("\(item.width) × \(item.height)") }
                    }
                    propRow("Size") { Text(byteString(item.sizeBytes)) }
                    propRow("Type") { Text(item.itemType == .url ? "URL" : item.ext.uppercased()) }
                    propRow("Date Imported") { Text(dateString(item.createdAt)) }
                    propRow("Date Modified") { Text(dateString(item.modifiedAt)) }
                }

                Button {
                    exportItem(item)
                } label: {
                    HStack {
                        Spacer()
                        Image(systemName: "square.and.arrow.up").font(.system(size: 11))
                        Text("Export").font(.system(size: 12, weight: .medium))
                        Spacer()
                    }
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.fieldBG))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .padding(14)
        }
        .id(item.id)
        .onAppear { titleDraft = item.name; noteDraft = item.note }
        .onChange(of: state.selectedItemId) { _, _ in
            if let it = state.selectedItem { titleDraft = it.name; noteDraft = it.note }
        }
    }

    private func commitTitle(_ item: Item) {
        var it = item
        it.name = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !it.name.isEmpty { state.update(it) }
    }
    private func commitNote(_ item: Item) {
        var it = item
        it.note = noteDraft
        state.update(it)
    }

    private func folderName(_ item: Item) -> String {
        item.folderId.flatMap { fid in state.folders.first { $0.id == fid }?.name } ?? "Uncategorized"
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .padding(.top, 4)
    }

    @ViewBuilder
    private func propRow<Content: View>(_ label: String, @ViewBuilder value: () -> Content) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            Spacer()
            value().font(.system(size: 11)).foregroundStyle(Color(white: 0.85))
        }
    }

    private func byteString(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
    private func dateString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd HH:mm"
        return f.string(from: d)
    }

    private func exportItem(_ item: Item) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(item.name).\(item.ext)"
        panel.begin { resp in
            guard resp == .OK, let dest = panel.url else { return }
            try? FileManager.default.copyItem(at: Library.fileURL(for: item), to: dest)
        }
    }
}

struct FlowChips: View {
    let tags: [String]
    let onRemove: (String) -> Void

    var body: some View {
        if tags.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(chunked(), id: \.self) { row in
                    HStack(spacing: 5) {
                        ForEach(row, id: \.self) { tag in
                            HStack(spacing: 3) {
                                Text(tag).font(.system(size: 10.5))
                                Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                                    .foregroundStyle(Theme.textSecondary)
                                    .onTapGesture { onRemove(tag) }
                            }
                            .padding(.horizontal, 7).padding(.vertical, 3.5)
                            .background(Capsule().fill(Theme.fieldBG))
                        }
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
            let w = CGFloat(tag.count) * 6.5 + 30
            if width + w > 220, !row.isEmpty { rows.append(row); row = []; width = 0 }
            row.append(tag); width += w
        }
        if !row.isEmpty { rows.append(row) }
        return rows
    }
}

extension Color {
    init(hex: String) {
        var h = hex
        if h.hasPrefix("#") { h.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: h).scanHexInt64(&value)
        self.init(red: Double((value >> 16) & 0xFF) / 255.0,
                  green: Double((value >> 8) & 0xFF) / 255.0,
                  blue: Double(value & 0xFF) / 255.0)
    }
}
