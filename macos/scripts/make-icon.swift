// The placeholder app icon (P1; the Icon Composer icon comes in P3, docs/MACOS_APP.md §11):
// three paper-white book spines leaning on each other, on the accent indigo, inside the
// macOS icon grid. Writes an .iconset folder for `iconutil -c icns`.
//
//   swift macos/scripts/make-icon.swift <out.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.removeItem(at: output)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// The artwork on a 1024-point canvas, scaled to `pixels`.
func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    // The macOS grid: an 824-point rounded square, centred.
    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    color(0x22348C).setFill()
    tile.fill()

    let paper = color(0xF3F4F0)
    let spines: [(x: CGFloat, width: CGFloat, height: CGFloat, angle: CGFloat)] = [
        (290, 110, 470, 0), (420, 96, 430, 0),
        (631, 104, 450, 15),  // leans on the second: its top-left corner meets that spine's top
    ]
    for spine in spines {
        context.saveGState()
        context.translateBy(x: spine.x, y: 250)
        context.rotate(by: spine.angle * .pi / 180)
        paper.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: spine.width, height: spine.height), xRadius: 14, yRadius: 14).fill()
        color(0x22348C).withAlphaComponent(0.35).setFill()
        for band in [spine.height - 70, spine.height - 100, 60] {
            NSRect(x: 16, y: band, width: spine.width - 32, height: 12).fill()
        }
        context.restoreGState()
    }
    paper.setFill()
    NSRect(x: 250, y: 236, width: 510, height: 16).fill()  // the shelf

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(pixels: size).write(to: output.appending(path: "icon_\(size)x\(size).png"))
    try render(pixels: size * 2).write(to: output.appending(path: "icon_\(size)x\(size)@2x.png"))
}
