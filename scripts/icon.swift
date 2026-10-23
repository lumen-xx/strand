import AppKit
// Draws the 1024 px master icon, then scales it into an iconset. Usage: swift scripts/icon.swift <outputDir>
let directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("Strand.iconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

func master() -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill(); shape.fill()
    ctx.restoreGState()
    shape.addClip()
    NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.09, blue: 0.30, alpha: 1), NSColor(calibratedRed: 0.02, green: 0.04, blue: 0.14, alpha: 1)])!.draw(in: tile, angle: -60)
    // soft glow behind the cable
    NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.55, blue: 1, alpha: 0.55), .clear])!.draw(fromCenter: NSPoint(x: 512, y: 430), radius: 0, toCenter: NSPoint(x: 512, y: 430), radius: 380, options: [])
    // User-supplied mark, rendered as a white alpha mask on the original background.
    let asset = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("assets/connectivity.png")
    let image = NSImage(contentsOf: asset)!
    var proposed = NSRect(origin: .zero, size: image.size)
    let mask = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)!
    ctx.saveGState()
    ctx.clip(to: CGRect(x: 242, y: 242, width: 540, height: 540), mask: mask)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fill(tile)
    ctx.restoreGState()
    // top sheen
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.14), .clear])!.draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let source = master()
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
    }
}
try source.representation(using: .png, properties: [:])!.write(to: directory.deletingLastPathComponent().appendingPathComponent("master.png"))
