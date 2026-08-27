import SwiftUI
import WebKit

/// Inline visual search: Pinterest results (and Google Lens when the item has a
/// source URL) rendered inside Snag, Eagle-plugin style.
struct VisualSearchOverlay: View {
    @EnvironmentObject var state: AppState
    @State private var mode: Mode = .pinterest
    @State private var query: String = ""

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
                    WebView(url: currentURL(item))
                        .background(Color.white)
                }
                .frame(width: 980, height: 660)
                .background(RoundedRectangle(cornerRadius: 13).fill(Theme.panelBG))
                .clipShape(RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.white.opacity(0.12)))
                .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
            }
            .id(item.id)
            .onAppear { query = item.name }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private func header(_ item: Item) -> some View {
        HStack(spacing: 10) {
            ThumbImage(item: item, maxPixel: 96) { img in
                if let img {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Theme.cardBG
                }
            }
            .frame(width: 30, height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Text("Similar to")
                .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
            TextField("Search", text: $query, onCommit: {})
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, weight: .medium))
                .frame(maxWidth: 260)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.fieldBG))

            Picker("", selection: $mode) {
                ForEach(availableModes(item), id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)

            Spacer()

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

struct WebView: NSViewRepresentable {
    let url: URL

    final class Coordinator {
        var lastRequested: URL?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        context.coordinator.lastRequested = url
        web.load(URLRequest(url: url))
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        // Only reload when the REQUESTED url changes (mode/query switch);
        // never fight the user's in-page navigation.
        if context.coordinator.lastRequested != url {
            context.coordinator.lastRequested = url
            web.load(URLRequest(url: url))
        }
    }
}
