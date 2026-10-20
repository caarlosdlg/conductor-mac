import AppKit

// Genera Conductor.iconset: cuadrado redondeado con degradado y un rayo.
func render(_ px: Int) -> Data {
    let size = CGFloat(px)
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let rect = NSRect(x: size * 0.06, y: size * 0.06, width: size * 0.88, height: size * 0.88)
    let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.2, yRadius: size * 0.2)
    NSGradient(colors: [NSColor(red: 0.42, green: 0.25, blue: 0.95, alpha: 1), NSColor(red: 0.95, green: 0.30, blue: 0.62, alpha: 1)])!
        .draw(in: path, angle: -60)
    if let sym = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: size * 0.5, weight: .bold)) {
        let tinted = NSImage(size: sym.size, flipped: false) { r in
            sym.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true
        }
        let s = tinted.size
        tinted.draw(at: NSPoint(x: (size - s.width) / 2, y: (size - s.height) / 2), from: .zero, operation: .sourceOver, fraction: 1)
    }
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

let dir = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for (name, px) in [("16", 16), ("16@2x", 32), ("32", 32), ("32@2x", 64), ("128", 128), ("128@2x", 256), ("256", 256), ("256@2x", 512), ("512", 512), ("512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(dir)/icon_\(name.replacingOccurrences(of: "@2x", with: ""))x\(name.replacingOccurrences(of: "@2x", with: ""))\(name.contains("@2x") ? "@2x" : "").png"))
}
