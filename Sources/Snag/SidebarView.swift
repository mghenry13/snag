import SwiftUI
import UniformTypeIdentifiers
import GRDB

struct SidebarView: View {
    @EnvironmentObject var state: AppState
    @State private var expanded: Set<String> = []
    @State private var newFolderName = ""
    @State private var showNewFolder = false

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
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9)).foregroundStyle(Theme.textSecondary)
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

                    Text("Folders (\(state.folders.count))")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 5)

                    folderTree(parent: nil, depth: 0)
                }
                .padding(.bottom, 12)
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
        ForEach(state.childFolders(of: parent)) { folder in
            let visible = q.isEmpty || subtreeMatches(folder, q: q)
            if visible {
                folderRow(folder, depth: depth)
                if expanded.contains(folder.id) || !q.isEmpty {
                    AnyView(folderTree(parent: folder.id, depth: depth + 1))
                }
            }
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
            Button {
                if isExpanded { expanded.remove(folder.id) } else { expanded.insert(folder.id) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .opacity(hasChildren ? 1 : 0)
                    .frame(width: 12)
            }
            .buttonStyle(.plain)

            Image(systemName: "folder")
                .font(.system(size: 12))
                .foregroundStyle(selected ? .white : (folder.color.map { Color(hex: $0) } ?? Theme.textSecondary))
            Text(folder.name).font(.system(size: 12.5)).lineLimit(1)
                .foregroundStyle(selected ? .white : Color(white: 0.85))
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
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.accent.opacity(0.85) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { state.filter = .folder(folder.id) }
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
                        HStack {
                            Image(systemName: "circle.fill").foregroundStyle(Color(hex: fc.rawValue))
                            Text(fc.label)
                        }
                    }
                }
                Divider()
                Button("None") { setColor(folder, nil) }
            }
            Button("Delete Folder", role: .destructive) { deleteFolder(folder) }
        }
        .onDrop(of: [UTType.text, UTType.fileURL, UTType.url, UTType.image], isTargeted: nil) { providers in
            // Item id dragged from the grid arrives as plain text.
            var handled = false
            for p in providers where p.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
                handled = true
                _ = p.loadObject(ofClass: String.self) { str, _ in
                    if let id = str, AppState.shared.items.contains(where: { $0.id == id }) {
                        DispatchQueue.main.async { AppState.shared.moveItem(id, to: folder.id) }
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
