import AppKit

/// The web's paper and accent colours, for the window, the loading view and the space
/// around the page (§7).
@MainActor
enum Paper {
    static let background = dynamic(light: 0xF3F4F0, dark: 0x14171C, name: "BookshelfPaper")
    static let accent = dynamic(light: 0x22348C, dark: 0xA9B8FF, name: "BookshelfAccent")

    private static func dynamic(light: UInt32, dark: UInt32, name: String) -> NSColor {
        NSColor(name: name) { appearance in
            rgb(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        }
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// A view filled with the paper colour, resolved for the current appearance on every draw.
class PaperView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Paper.background.setFill()
        dirtyRect.fill()
    }
}

extension NSTextField {
    static func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        return field
    }
}
