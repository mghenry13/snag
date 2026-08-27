import SwiftUI
import AppKit

/// Palette dots; clicking one copies the hex and confirms with a toast.
struct PaletteRow: View {
    let colors: [String]
    var dotSize: CGFloat = 17
    @State private var copied: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                ForEach(colors, id: \.self) { hex in
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(hex, forType: .string)
                        withAnimation(.easeOut(duration: 0.12)) { copied = hex }
                        let stamped = hex
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                            withAnimation(.easeOut(duration: 0.2)) {
                                if copied == stamped { copied = nil }
                            }
                        }
                    } label: {
                        Circle().fill(Color(hex: hex))
                            .frame(width: dotSize, height: dotSize)
                            .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            if let copied {
                Text("Copied \(copied)")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.85)))
                    .transition(.opacity)
            }
        }
    }
}

// Navy-tinted dark theme matched to the Eagle screenshot.
enum Theme {
    static let windowBG = Color(red: 0.106, green: 0.118, blue: 0.169)     // #1B1E2B
    static let sidebarBG = Color(red: 0.090, green: 0.102, blue: 0.145)    // #171A25
    static let panelBG = Color(red: 0.098, green: 0.110, blue: 0.157)
    static let inspectorBG = Color(red: 0.090, green: 0.102, blue: 0.145)
    static let cardBG = Color(red: 0.137, green: 0.153, blue: 0.216)       // #232737
    static let fieldBG = Color(red: 0.153, green: 0.169, blue: 0.239)      // #272B3D
    static let accent = Color(red: 0.247, green: 0.431, blue: 0.968)       // #3F6EF7
    static let textSecondary = Color(red: 0.55, green: 0.58, blue: 0.66)
    static let divider = Color.white.opacity(0.07)
    static let starYellow = Color(red: 1.0, green: 0.78, blue: 0.20)
}
