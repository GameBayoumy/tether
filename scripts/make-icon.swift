// Renders the Tether app icon: usage `swift make-icon.swift <output.iconset>`
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: 824/1024 body, ~185/1024 corner radius. Ink room with a warm horizon.
    let inset = size * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let path = CGPath(roundedRect: body, cornerWidth: size * 185 / 1024, cornerHeight: size * 185 / 1024, transform: nil)
    ctx.addPath(path)
    ctx.clip()
    let colors = [NSColor(red: 0.047, green: 0.075, blue: 0.133, alpha: 1).cgColor,
                  NSColor(red: 0.016, green: 0.024, blue: 0.043, alpha: 1).cgColor] as CFArray
    ctx.drawLinearGradient(CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!,
                           start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.maxY), options: [])
    let gold = NSColor(red: 0.914, green: 0.761, blue: 0.478, alpha: 1)
    let glow = [gold.withAlphaComponent(0.35).cgColor, gold.withAlphaComponent(0).cgColor] as CFArray
    ctx.drawRadialGradient(CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: glow, locations: [0, 1])!,
                           startCenter: CGPoint(x: body.midX, y: body.minY + body.height * 0.22), startRadius: 0,
                           endCenter: CGPoint(x: body.midX, y: body.minY + body.height * 0.22), endRadius: body.width * 0.6, options: [])

    // The mark, in Core Graphics coordinates (y up), drawn into the centre 52% of the body.
    let w = body.width * 0.52
    let origin = CGPoint(x: body.midX - w / 2, y: body.midY - w / 2)
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * w, y: origin.y + (1 - y) * w) }
    ctx.setStrokeColor(gold.cgColor)
    ctx.setFillColor(gold.cgColor)
    ctx.setLineCap(.round)
    ctx.setLineWidth(w * 0.095)
    let ring = CGRect(x: origin.x + w * 0.06, y: origin.y + w * (1 - 0.58), width: w * 0.52, height: w * 0.52)
    ctx.strokeEllipse(in: ring)
    let start = pt(0.06 + 0.26 + 0.52 * 0.36, 0.06 + 0.26 + 0.52 * 0.36)
    let end = pt(0.86, 0.84)
    ctx.setLineWidth(w * 0.075)
    ctx.move(to: start)
    ctx.addQuadCurve(to: end, control: pt(0.56, 1.0))
    ctx.strokePath()
    let r = w * 0.085
    ctx.fillEllipse(in: CGRect(x: end.x - r, y: end.y - r, width: r * 2, height: r * 2))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: output.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: output.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
