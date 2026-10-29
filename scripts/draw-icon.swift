import AppKit
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(size) / 1024
    let transform = NSAffineTransform(); transform.scale(by: scale); transform.concat()
    let rect = NSRect(x: 72, y: 72, width: 880, height: 880)
    let shape = NSBezierPath(roundedRect: rect, xRadius: 196, yRadius: 196)
    NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.56, blue: 0.67, alpha: 1),
               ending: NSColor(calibratedRed: 0.06, green: 0.28, blue: 0.38, alpha: 1))!.draw(in: shape, angle: -75)
    let ring = NSBezierPath(ovalIn: NSRect(x: 246, y: 246, width: 532, height: 532))
    ring.lineWidth = 54; NSColor.white.withAlphaComponent(0.95).setStroke(); ring.stroke()
    let line = NSBezierPath(); line.move(to: NSPoint(x: 512, y: 512)); line.line(to: NSPoint(x: 655, y: 655))
    line.lineWidth = 56; line.lineCapStyle = .round; line.stroke()
    NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: 451, y: 451, width: 122, height: 122)).fill()
    NSColor(calibratedRed: 0.55, green: 0.95, blue: 0.79, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 703, y: 707, width: 120, height: 120)).fill()
    NSGraphicsContext.restoreGraphicsState()
    let data = bitmap.representation(using: .png, properties: [:])!
    let names: [String]
    switch size {
    case 16: names = ["icon_16x16.png"]
    case 32: names = ["icon_16x16@2x.png", "icon_32x32.png"]
    case 64: names = ["icon_32x32@2x.png"]
    case 128: names = ["icon_128x128.png"]
    case 256: names = ["icon_128x128@2x.png", "icon_256x256.png"]
    case 512: names = ["icon_256x256@2x.png", "icon_512x512.png"]
    default: names = ["icon_512x512@2x.png"]
    }
    for name in names { try data.write(to: directory.appendingPathComponent(name)) }
}
