import SwiftUI
import AppKit

/// Colors and small components shared with Managed (time-and-todo), which follows Things 3.
/// Solid surfaces, no vibrancy: translucent material turns muddy over bright pages.
enum Theme {
    static let content = dynamic(dark: 0x2E2E2F, light: 0xFFFFFF)
    static let sidebar = dynamic(dark: 0x2B2B2C, light: 0xF5F5F7)
    static let card = dynamic(dark: 0x353537, light: 0xFFFFFF)
    static let sidebarSelection = dynamic(dark: 0x3C3E42, light: 0xDCDCE0)
    static let selection = dynamic(dark: 0x2D3E6D, light: 0xCFE0FC)
    static let inactiveSelection = dynamic(dark: 0x393C3F, light: 0xE4E4E6)
    static let accent = dynamic(dark: 0x6C9DED, light: 0x3F82EA)
    static let secret = dynamic(dark: 0xF2CE3D, light: 0xC99A00)
    static let hairline = Color.primary.opacity(0.12)

    private static func dynamic(dark: UInt32, light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

enum Motion {
    static let standard = Animation.spring(response: 0.34, dampingFraction: 0.86)
}

/// Row highlight: muted indigo while the window is active, quiet gray otherwise.
struct SelectionFill: View {
    var cornerRadius: CGFloat = 7
    @Environment(\.appearsActive) private var appearsActive
    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(appearsActive ? Theme.selection : Theme.inactiveSelection)
    }
}

struct Pill: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            .lineLimit(1)
    }
}

/// A keyboard shortcut shown as a key cap.
struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
    }
}

/// Footer hint: key cap + what it does.
struct KeyHint: View {
    let keys: String
    let label: String
    var body: some View {
        HStack(spacing: 5) {
            KeyCap(text: keys)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Things-style card: solid fill, hairline border, barely-there shadow.
struct CardChrome: ViewModifier {
    let isSelected: Bool
    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 9).fill(Theme.card)
                    SelectionFill(cornerRadius: 9).opacity(isSelected ? 1 : 0)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.hairline, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
    }
}

extension View {
    func card(isSelected: Bool = false) -> some View { modifier(CardChrome(isSelected: isSelected)) }
}

struct SidebarRow: View {
    let title: String
    let symbol: String
    let tint: Color
    let isSelected: Bool
    var badge: Int = 0

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 20)
            Text(title).lineLimit(1)
            Spacer(minLength: 4)
            if badge > 0 {
                Text("\(badge)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background { if isSelected { RoundedRectangle(cornerRadius: 7).fill(Theme.sidebarSelection) } }
        .contentShape(Rectangle())
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
    }
}

/// The floating panels' shape: solid content color, radius 16, faint light edge.
struct PanelChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.content, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.1), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .tint(Theme.accent)
    }
}
