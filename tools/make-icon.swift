// Zeichnet das App-Icon (eigenes WLAN-Zeichen, kein Apple-SF-Symbol: deren Lizenz verbietet App-Icons).
// Nutzung: swiftc -o /tmp/draw tools/make-icon.swift && /tmp/draw /tmp/AppIcon.iconset && iconutil -c icns /tmp/AppIcon.iconset -o AppIcon.icns
import AppKit
// Eigenes WLAN-Zeichen: Punkt + drei Bögen (Viertelkreise, nach oben offen), runde Enden.
func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let blue = NSColor(srgbRed: 0, green: 0.48, blue: 1, alpha: 1)
    blue.setStroke(); blue.setFill()
    let center = NSPoint(x: s / 2, y: s * 0.22)
    let line = s * 0.085
    for r in [0.20, 0.36, 0.52] {
        let p = NSBezierPath()
        p.appendArc(withCenter: center, radius: s * r, startAngle: 45, endAngle: 135)
        p.lineWidth = line; p.lineCapStyle = .round
        p.stroke()
    }
    let d = s * 0.13
    NSBezierPath(ovalIn: NSRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (name, px) in [("16x16",16),("16x16@2x",32),("32x32",32),("32x32@2x",64),("128x128",128),("128x128@2x",256),
                   ("256x256",256),("256x256@2x",512),("512x512",512),("512x512@2x",1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
