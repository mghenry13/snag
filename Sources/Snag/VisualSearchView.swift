import SwiftUI
import WebKit

/// Inline visual search and browsing: Pinterest (and Google Lens when the item
/// has a source URL) rendered inside Snag. Browse freely; right-click any image
/// in the page to save it straight into the library.
struct VisualSearchOverlay: View {
    @EnvironmentObject var state: AppState
    @StateObject private var store = WebViewStore()
    @State private var mode: Mode = .pinterest
    @State private var query: String = ""
    @State private var saveFolderId: String? = nil
    @State private var saveMessage: String? = nil

    enum Mode: String, CaseIterable {
        case pinterest = "Pinterest"
        case lens = "Google Lens"
    }

    var body: some View {
        if let item = state.visualSearchItem {
            ZStack {
                Color.black.opacity(0.6)
                    .ignoresSafeArea()
                    .onTapGesture { state.visualSearchItem = nil }

                VStack(spacing: 0) {
                    header(item)
                    Rectangle().fill(Theme.divider).frame(height: 1)
                    SnagWebView(url: currentURL(item), store: store,
                                saveFolderId: saveFolderId) { result in
                        switch result {
                        case .some(let r) where r.isDuplicate:
                            flash("Already in Snag")
                        case .some:
                            let name = saveFolderId.flatMap { fid in state.folders.first { $0.id == fid }?.name }
                            flash("Saved to \(name ?? "Snag")")
                        case .none:
                            flash("Could not save that image")
                        }
                    }
                    .background(Color.white)
                }
                .frame(width: 1020, height: 680)
                .background(RoundedRectangle(cornerRadius: 13).fill(Theme.panelBG))
                .clipShape(RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.white.opacity(0.12)))
                .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
                .overlay(alignment: .top) {
                    if let msg = saveMessage {
                        Text(msg)
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                            .padding(.horizontal, 13).padding(.vertical, 7)
                            .background(Capsule().fill(Theme.accent))
                            .padding(.top, 54)
                            .transition(.opacity)
                    }
                }
            }
            .id(item.id)
            .onAppear { query = item.name }
            .transition(.opacity)
        }
    }

    private func flash(_ text: String) {
        withAnimation(.easeOut(duration: 0.15)) { saveMessage = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeOut(duration: 0.25)) {
                if saveMessage == text { saveMessage = nil }
            }
        }
    }

    @ViewBuilder
    private func header(_ item: Item) -> some View {
        HStack(spacing: 10) {
            // Rabbit-hole navigation
            Button { store.webView?.goBack() } label: {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }.buttonStyle(.plain)
            Button { store.webView?.goForward() } label: {
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }.buttonStyle(.plain)

            ThumbImage(item: item, maxPixel: 96) { img in
                if let img {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Theme.cardBG
                }
            }
            .frame(width: 28, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, weight: .medium))
                .frame(maxWidth: 220)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.fieldBG))

            Picker("", selection: $mode) {
                ForEach(availableModes(item), id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)

            Spacer()

            // Where right-click saves land
            Menu {
                Button("Uncategorized") { saveFolderId = nil }
                ForEach(state.folders) { f in
                    Button(f.name) { saveFolderId = f.id }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "folder").font(.system(size: 10.5))
                    Text("Save into: \(folderName)").font(.system(size: 11.5))
                }
                .foregroundStyle(Color(white: 0.85))
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.fieldBG))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                NSWorkspace.shared.open(currentURL(item))
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Open in browser")

            Button {
                state.visualSearchItem = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    .padding(6)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .overlay(alignment: .bottomLeading) {
            Text("Right-click any image to save it into Snag")
                .font(.system(size: 9.5)).foregroundStyle(Theme.textSecondary.opacity(0.8))
                .padding(.leading, 66).padding(.bottom, -1)
        }
    }

    private var folderName: String {
        saveFolderId.flatMap { fid in state.folders.first { $0.id == fid }?.name } ?? "Uncategorized"
    }

    private func availableModes(_ item: Item) -> [Mode] {
        lensURL(item) != nil ? Mode.allCases : [.pinterest]
    }

    private func currentURL(_ item: Item) -> URL {
        switch mode {
        case .lens:
            if let lens = lensURL(item) { return lens }
            fallthrough
        case .pinterest:
            let q = (query.isEmpty ? item.name : query)
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            return URL(string: "https://www.pinterest.com/search/pins/?q=\(q)")!
        }
    }

    private func lensURL(_ item: Item) -> URL? {
        guard item.itemType == .image,
              let src = item.sourceURL, src.hasPrefix("http"),
              let q = src.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: "https://lens.google.com/uploadbyurl?url=\(q)")
    }
}

// MARK: - WebView plumbing

final class WebViewStore: ObservableObject {
    var webView: SnagWKWebView?
}

struct SnagWebView: NSViewRepresentable {
    let url: URL
    let store: WebViewStore
    let saveFolderId: String?
    let onSaved: (ImportResult?) -> Void

    final class Coordinator {
        var lastRequested: URL?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SnagWKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let web = SnagWKWebView(frame: .zero, configuration: config)
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        web.saveFolderId = saveFolderId
        web.onSaved = onSaved
        context.coordinator.lastRequested = url
        web.load(URLRequest(url: url))
        store.webView = web
        return web
    }

    func updateNSView(_ web: SnagWKWebView, context: Context) {
        web.saveFolderId = saveFolderId
        web.onSaved = onSaved
        // Only reload when the REQUESTED url changes (mode/query switch);
        // never fight the user's in-page navigation.
        if context.coordinator.lastRequested != url {
            context.coordinator.lastRequested = url
            web.load(URLRequest(url: url))
        }
    }
}

/// WKWebView with a "Save to Snag" entry in its context menu. Finds the image
/// under the right-click and imports the best resolution Pinterest serves.
final class SnagWKWebView: WKWebView {
    var saveFolderId: String? = nil
    var onSaved: ((ImportResult?) -> Void)? = nil
    private var lastRightClick: NSPoint = .zero

    override func rightMouseDown(with event: NSEvent) {
        lastRightClick = convert(event.locationInWindow, from: nil)
        super.rightMouseDown(with: event)
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        let save = NSMenuItem(title: "Save to Snag", action: #selector(saveUnderCursor), keyEquivalent: "")
        save.target = self
        menu.insertItem(save, at: 0)
        menu.insertItem(.separator(), at: 1)
    }

    @objc private func saveUnderCursor() {
        let js = """
        (() => {
          const fromEl = (el) => {
            while (el) {
              if (el.tagName === 'IMG' && (el.currentSrc || el.src)) return el.currentSrc || el.src;
              if (el.tagName === 'VIDEO' && (el.currentSrc || el.src)) return el.currentSrc || el.src;
              const bg = getComputedStyle(el).backgroundImage;
              const m = bg && bg.match(/url\\("?([^")]+)"?\\)/);
              if (m) return m[1];
              el = el.parentElement;
            }
            return null;
          };
          // The whole stack under the point, so overlays (login walls) can't hide the image.
          const stack = document.elementsFromPoint(\(lastRightClick.x), \(lastRightClick.y));
          for (const el of stack) {
            if (el.tagName === 'IMG' || el.tagName === 'VIDEO') {
              const hit = fromEl(el);
              if (hit) return hit;
            }
          }
          for (const el of stack) {
            const imgs = el.querySelectorAll ? el.querySelectorAll('img') : [];
            for (const img of imgs) {
              const r = img.getBoundingClientRect();
              if (r.left <= \(lastRightClick.x) && \(lastRightClick.x) <= r.right &&
                  r.top <= \(lastRightClick.y) && \(lastRightClick.y) <= r.bottom &&
                  (img.currentSrc || img.src)) {
                return img.currentSrc || img.src;
              }
            }
          }
          return fromEl(stack[0] || null);
        })()
        """
        evaluateJavaScript(js) { [weak self] result, _ in
            guard let self else { return }
            guard let src = result as? String, src.hasPrefix("http") else {
                DispatchQueue.main.async { self.onSaved?(nil) }
                return
            }
            let pageURL = self.url?.absoluteString
            let folderId = self.saveFolderId
            Task {
                // pinimg thumbnails encode their size in the path; walk up to the
                // best resolution that actually exists.
                var candidates = [src]
                if src.contains("pinimg.com"), let range = src.range(of: #"/\d+x/"#, options: .regularExpression) {
                    let originals = src.replacingCharacters(in: range, with: "/originals/")
                    let big = src.replacingCharacters(in: range, with: "/736x/")
                    candidates = [originals, big, src]
                }
                var result: ImportResult? = nil
                for candidate in candidates {
                    if let r = try? await Library.importRemote(urlString: candidate, pageURL: pageURL, folderId: folderId) {
                        result = r
                        break
                    }
                }
                let final = result
                await MainActor.run { self.onSaved?(final) }
            }
        }
    }
}
