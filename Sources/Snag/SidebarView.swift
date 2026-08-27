import SwiftUI
import UniformTypeIdentifiers
import GRDB

struct SidebarView: View {
    @EnvironmentObject var state: AppState
    @State private var expanded: Set<String> = []
    @State private var newFolderName = ""
    @State private var showNewFolder = false
    @State private var dropTarget: String? = nil   // folder id, or "" for the root header

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Library header
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.accent)
                    .frame(width: 22, height: 22)
                    .overlay(Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(.white))
                Text("Snag").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { showNewFolder = true } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    smartRow(.all, icon: "square.grid.2x2", label: "All")
                    smartRow(.uncategorized, icon: "tray", label: "Uncategorized")
                    smartRow(.untagged, icon: "tag.slash", label: "Untagged")
                    smartRow(.recent, icon: "clock", label: "Recently Used")
                    smartRow(.random, icon: "shuffle", label: "Random")
                    smartRow(.allTags, icon: "tag", label: "All Tags")
                    smartRow(.trash, icon: "trash", label: "Trash")

                    Text(dropTarget == "" ? "Move to top level" : "Folders (\(state.folders.count))")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(dropTarget == "" ? Theme.accent : Theme.textSecondary)
                        .padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(dropTarget == "" ? Theme.accent.opacity(0.18) : .clear)
                                .padding(.horizontal, 8).padding(.top, 11)
                        )
                        .contentShape(Rectangle())
                        .onDrop(of: [UTType.text],
                                isTargeted: Binding(get: { dropTarget == "" },
                                                    set: { dropTarget = $0 ? "" : (dropTarget == "" ? nil : dropTarget) })) { providers in
                            // Drop a folder here to move it back to the top level.
                            for p in providers where p.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
                                _ = p.loadObject(ofClass: String.self) { str, _ in
                                    guard let s = str, s.hasPrefix("folder:") else { return }
                                    DispatchQueue.main.async {
                                        AppState.shared.nestFolder(String(s.dropFirst(7)), under: nil)
                                    }
                                }
                            }
                            return true
                        }

                    folderTree(parent: nil, depth: 0)

                    // Empty space below the tree: right-click target for New Folder.
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: 160)
                        .contentShape(Rectangle())
                }
                .padding(.bottom, 12)
                // Folder drag-and-drop feel: rows spring into their new order,
                // expand/collapse eases, drop highlights fade quickly.
                .animation(.spring(response: 0.32, dampingFraction: 0.85), value: state.folders)
                .animation(.spring(response: 0.28, dampingFraction: 0.9), value: expanded)
                .animation(.easeOut(duration: 0.13), value: dropTarget)
            }
            .contextMenu {
                Button("New Folder") { showNewFolder = true }
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                TextField("Filter", text: $state.folderFilterText)
                    .textFieldStyle(.plain).font(.system(size: 11.5))
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.fieldBG))
            .padding(10)
        }
        .sheet(isPresented: $showNewFolder) {
            VStack(spacing: 14) {
                Text("New Folder").font(.headline)
                TextField("Folder name", text: $newFolderName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit { commitNewFolder() }
                HStack {
                    Button("Cancel") { showNewFolder = false; newFolderName = "" }
                    Button("Create") { commitNewFolder() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(22)
        }
    }

    private func commitNewFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { state.createFolder(name: name) }
        newFolderName = ""; showNewFolder = false
    }

    @ViewBuilder
    private func smartRow(_ filter: SidebarFilter, icon: String, label: String) -> some View {
        let selected = state.filter == filter
        Button {
            state.filter = filter
            if filter == .random { state.randomSeed &+= 1 }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 16)
                    .foregroundStyle(selected ? .white : Theme.textSecondary)
                Text(label).font(.system(size: 12.5))
                    .foregroundStyle(selected ? .white : Color(white: 0.85))
                Spacer()
                Text("\(state.count(for: filter))")
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? .white.opacity(0.8) : Theme.textSecondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 5.5)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.accent.opacity(0.85) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private func folderTree(parent: String?, depth: Int) -> some View {
        let q = state.folderFilterText.trimmingCharacters(in: .whitespaces).lowercased()
        let children = state.childFolders(of: parent)
        ForEach(Array(children.enumerated()), id: \.element.id) { idx, folder in
            let visible = q.isEmpty || subtreeMatches(folder, q: q)
            if visible {
                if q.isEmpty {
                    insertionSlot(parent: parent, index: idx, depth: depth)
                }
                folderRow(folder, depth: depth)
                if expanded.contains(folder.id) || !q.isEmpty {
                    AnyView(folderTree(parent: folder.id, depth: depth + 1))
                }
            }
        }
        if q.isEmpty, !children.isEmpty {
            insertionSlot(parent: parent, index: children.count, depth: depth)
        }
    }

    /// Thin gap between folder rows. Dragging a folder over it shows an accent
    /// line; dropping reorders the folder to that spot (same parent as the list).
    private func insertionSlot(parent: String?, index: Int, depth: Int) -> some View {
        let slotId = "slot:\(parent ?? "root"):\(index)"
        let active = dropTarget == slotId
        return HStack(spacing: 3) {
            Circle()
                .fill(Theme.accent)
                .frame(width: 5, height: 5)
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Theme.accent)
                .frame(height: 2.5)
        }
        .opacity(active ? 1 : 0)
        .scaleEffect(x: active ? 1 : 0.5, y: 1, anchor: .leading)
        .padding(.leading, 18 + CGFloat(depth) * 14)
        .padding(.trailing, 14)
        .frame(height: active ? 10 : 7)
        .contentShape(Rectangle())
            .onDrop(of: [UTType.text],
                    isTargeted: Binding(get: { dropTarget == slotId },
                                        set: { dropTarget = $0 ? slotId : (dropTarget == slotId ? nil : dropTarget) })) { providers in
                for p in providers where p.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
                    _ = p.loadObject(ofClass: String.self) { str, _ in
                        guard let s = str, s.hasPrefix("folder:") else { return }
                        DispatchQueue.main.async {
                            AppState.shared.reorderFolder(String(s.dropFirst(7)), parent: parent, index: index)
                        }
                    }
                }
                return true
            }
    }

    private func subtreeMatches(_ folder: Folder, q: String) -> Bool {
        if folder.name.lowercased().contains(q) { return true }
        return state.childFolders(of: folder.id).contains { subtreeMatches($0, q: q) }
    }

    @ViewBuilder
    private func folderRow(_ folder: Folder, depth: Int) -> some View {
        let selected = state.filter == .folder(folder.id)
        let hasChildren = !state.childFolders(of: folder.id).isEmpty
        let isExpanded = expanded.contains(folder.id)
        HStack(spacing: 5) {
            Image(systemName: "folder")
                .font(.system(size: 12))
                .foregroundStyle(selected ? .white : (folder.color.map { Color(hex: $0) } ?? Theme.textSecondary))
            Text(folder.name).font(.system(size: 12.5)).lineLimit(1)
                .foregroundStyle(selected ? .white : Color(white: 0.85))
            if hasChildren {
                Button {
                    if isExpanded { expanded.remove(folder.id) } else { expanded.insert(folder.id) }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            let n = state.count(for: .folder(folder.id))
            if n > 0 {
                Text("\(n)").font(.system(size: 11))
                    .foregroundStyle(selected ? .white.opacity(0.8) : Theme.textSecondary)
            }
        }
        .padding(.vertical, 5)
        .padding(.leading, 10 + CGFloat(depth) * 14)
        .padding(.trailing, 10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Theme.accent.opacity(0.85)
                      : (dropTarget == folder.id ? Theme.accent.opacity(0.28) : .clear))
        )
        .overlay(
            // Selection rectangle: this folder is the drop target.
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Theme.accent, lineWidth: dropTarget == folder.id ? 1.8 : 0)
        )
        .contentShape(Rectangle())
        .onTapGesture { state.filter = .folder(folder.id) }
        .draggable("folder:" + folder.id)
        .padding(.horizontal, 8)
        .contextMenu {
            Button("New Subfolder") {
                state.createFolder(name: "New Folder", parentId: folder.id)
                expanded.insert(folder.id)
            }
            Button("Rename") { renameFolder(folder) }
            Menu("Color") {
                ForEach(FolderColor.allCases, id: \.self) { fc in
                    Button {
                        setColor(folder, fc.rawValue)
                    } label: {
                        Label {
                            Text(fc.label)
                        } icon: {
                            Image(nsImage: Self.swatchImage(hex: fc.rawValue))
                        }
                        .labelStyle(.titleAndIcon)
                    }
                }
                Divider()
                Button("None") { setColor(folder, nil) }
            }
            Button("Delete Folder", role: .destructive) { deleteFolder(folder) }
        }
        .onDrop(of: [UTType.text, UTType.fileURL, UTType.url, UTType.image],
                isTargeted: Binding(get: { dropTarget == folder.id },
                                    set: { dropTarget = $0 ? folder.id : (dropTarget == folder.id ? nil : dropTarget) })) { providers in
            // Plain text is either "folder:<id>" (nest a folder) or an item id (move an item).
            var handled = false
            for p in providers where p.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
                handled = true
                _ = p.loadObject(ofClass: String.self) { str, _ in
                    guard let s = str else { return }
                    DispatchQueue.main.async {
                        if s.hasPrefix("folder:") {
                            AppState.shared.nestFolder(String(s.dropFirst(7)), under: folder.id)
                        } else if AppState.shared.items.contains(where: { $0.id == s }) {
                            AppState.shared.moveItem(s, to: folder.id)
                        }
                    }
                }
            }
            if !handled {
                DropImporter.importProviders(providers, folderId: folder.id) { _ in }
                handled = true
            }
            return handled
        }
    }

    /// Colored dot for the Color menu. Menus render template images monochrome,
    /// so this draws a real bitmap with isTemplate false.
    static func swatchImage(hex: String) -> NSImage {
        var h = hex; if h.hasPrefix("#") { h.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: h).scanHexInt64(&v)
        let color = NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255.0,
                            green: CGFloat((v >> 8) & 0xFF) / 255.0,
                            blue: CGFloat(v & 0xFF) / 255.0, alpha: 1)
        let img = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).fill()
            return true
        }
        img.isTemplate = false
        return img
    }

    private func setColor(_ folder: Folder, _ hex: String?) {
        var f = folder
        f.color = hex
        try? Database.shared.dbQueue.write { db in try f.update(db) }
        Database.notifyChanged()
    }

    private func renameFolder(_ folder: Folder) {
        let alert = NSAlert()
        alert.messageText = "Rename Folder"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = folder.name
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            var f = folder
            f.name = field.stringValue.trimmingCharacters(in: .whitespaces)
            if !f.name.isEmpty {
                try? Database.shared.dbQueue.write { db in try f.update(db) }
                Database.notifyChanged()
            }
        }
    }

    private func deleteFolder(_ folder: Folder) {
        let ids = state.descendantIds(of: folder.id)
        try? Database.shared.dbQueue.write { db in
            // Items fall back to Uncategorized; subfolders are deleted too.
            try Item.filter(ids.contains(Column("folderId"))).updateAll(db, Column("folderId").set(to: nil as String?))
            try Folder.filter(ids.contains(Column("id"))).deleteAll(db)
        }
        if case .folder(let cur) = state.filter, ids.contains(cur) { state.filter = .all }
        Database.notifyChanged()
    }
}
