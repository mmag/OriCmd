// Draws the OriCmd app icon and writes the AppIcon.appiconset PNGs.
// Usage: swift scripts/make-icon.swift
import AppKit

let output = URL(filePath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
                 : "OriCmd/Assets.xcassets/AppIcon.appiconset")

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

/// Draws the icon into a 1024×1024 coordinate space.
func drawIcon() {
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 28
    shadow.shadowColor = color(0, 0, 0, 0.35)
    shadow.set()
    color(0.08, 0.14, 0.30).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(starting: color(0.20, 0.36, 0.70), ending: color(0.06, 0.11, 0.26))!.draw(in: shape, angle: -90)

    // Two panels side by side.
    let gap: CGFloat = 28
    let inset: CGFloat = 72
    let panelTop = body.maxY - 118
    let panelBottom = body.minY + 170
    let panelWidth = (body.width - inset * 2 - gap) / 2
    for side in 0..<2 {
        let panel = NSRect(x: body.minX + inset + CGFloat(side) * (panelWidth + gap), y: panelBottom,
                           width: panelWidth, height: panelTop - panelBottom)
        let panelShape = NSBezierPath(roundedRect: panel, xRadius: 26, yRadius: 26)
        color(0.97, 0.97, 0.98).setFill()
        panelShape.fill()

        NSGraphicsContext.saveGraphicsState()
        panelShape.addClip()
        // Path bar: highlighted in the active (left) panel.
        (side == 0 ? color(0.16, 0.46, 0.96) : color(0.78, 0.80, 0.84)).setFill()
        NSRect(x: panel.minX, y: panel.maxY - 58, width: panel.width, height: 58).fill()

        for row in 0..<6 {
            let y = panel.maxY - 58 - 30 - CGFloat(row) * 54
            let rowRect = NSRect(x: panel.minX, y: y - 14, width: panel.width, height: 46)
            let isCursor = side == 0 && row == 2
            if isCursor {
                color(0.16, 0.46, 0.96).setFill()
                rowRect.fill()
            }
            let isMarked = side == 0 && row == 4
            let lineColor = isCursor ? color(1, 1, 1, 0.95) : (isMarked ? color(0.90, 0.16, 0.16) : color(0.55, 0.58, 0.64))
            lineColor.setFill()
            let widths: [CGFloat] = [0.62, 0.48, 0.70, 0.40, 0.56, 0.66]
            let width = (panel.width - 64) * widths[(row + side * 3) % widths.count]
            NSBezierPath(roundedRect: NSRect(x: panel.minX + 30, y: y, width: width, height: 18),
                         xRadius: 9, yRadius: 9).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    // Function key bar.
    let keys = 4
    let keyGap: CGFloat = 18
    let keyWidth = (body.width - inset * 2 - keyGap * CGFloat(keys - 1)) / CGFloat(keys)
    for key in 0..<keys {
        let rect = NSRect(x: body.minX + inset + CGFloat(key) * (keyWidth + keyGap), y: body.minY + 78,
                          width: keyWidth, height: 56)
        color(1, 1, 1, key == 1 ? 0.55 : 0.28).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16).fill()
    }
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(pixels) / 1024
    NSGraphicsContext.current!.cgContext.scaleBy(x: scale, y: scale)
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try png(pixels: points * scale).write(to: output.appending(path: name))
        images.append(["size": "\(points)x\(points)", "idiom": "mac", "filename": name, "scale": "\(scale)x"])
    }
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appending(path: "Contents.json"))
print("Wrote \(images.count) icons to \(output.path)")
