// Draws the OriCmd app icon and writes the AppIcon.appiconset PNGs.
// Usage: swift scripts/make-icon.swift [classic|arrow|origami] [output folder]
//        swift scripts/make-icon.swift preview [output.png]   — all variants side by side
import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())
let variant = arguments.first ?? "classic"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func rounded(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

/// The macOS icon shape: a superellipse ("squircle") on the standard 824 pt grid.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)

func squircle(_ rect: NSRect, exponent: CGFloat = 5) -> NSBezierPath {
    let path = NSBezierPath()
    let (a, b) = (rect.width / 2, rect.height / 2)
    let steps = 720
    for step in 0...steps {
        let t = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let (c, s) = (cos(t), sin(t))
        let x = a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / exponent)
        let y = b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / exponent)
        let point = NSPoint(x: rect.midX + x, y: rect.midY + y)
        step == 0 ? path.move(to: point) : path.line(to: point)
    }
    path.close()
    return path
}

func withShadow(offset: CGFloat, blur: CGFloat, alpha: CGFloat, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -offset)
    shadow.shadowBlurRadius = blur
    shadow.shadowColor = NSColor(white: 0, alpha: alpha)
    shadow.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

func clipped(_ path: NSBezierPath, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

/// The squircle with a gradient, a soft top highlight and the drop shadow.
@discardableResult
func background(_ top: NSColor, _ bottom: NSColor) -> NSBezierPath {
    let shape = squircle(body)
    withShadow(offset: 12, blur: 30, alpha: 0.35) {
        bottom.setFill()
        shape.fill()
    }
    NSGradient(starting: top, ending: bottom)!.draw(in: shape, angle: -90)
    clipped(shape) {
        let glow = NSGradient(colors: [NSColor(white: 1, alpha: 0.22), NSColor(white: 1, alpha: 0)])!
        glow.draw(fromCenter: NSPoint(x: body.midX, y: body.maxY + 60), radius: 0,
                  toCenter: NSPoint(x: body.midX, y: body.maxY + 60), radius: 620, options: [])
    }
    // A thin inner rim, as on the system icons.
    NSColor(white: 1, alpha: 0.18).setStroke()
    let rim = squircle(body.insetBy(dx: 3, dy: 3))
    rim.lineWidth = 4
    rim.stroke()
    return shape
}

func line(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ fill: NSColor) {
    fill.setFill()
    rounded(NSRect(x: x, y: y, width: width, height: height), height / 2).fill()
}

// MARK: - A: two panels and the copy arrow

func drawArrow() {
    background(color(0x3D7BF5), color(0x0C1D4F))

    let panelY: CGFloat = 330
    let panelHeight: CGFloat = 450
    let panels = [NSRect(x: 176, y: panelY, width: 318, height: panelHeight),
                  NSRect(x: 530, y: panelY, width: 318, height: panelHeight)]
    for (index, panel) in panels.enumerated() {
        let shape = rounded(panel, 38)
        withShadow(offset: 8, blur: 22, alpha: 0.30) {
            color(0xF4F7FC).setFill()
            shape.fill()
        }
        NSGradient(starting: color(0xFFFFFF), ending: color(0xE3E9F4))!.draw(in: shape, angle: -90)
        clipped(shape) {
            (index == 0 ? color(0x2F6BF0) : color(0xC3CCDA)).setFill()
            NSRect(x: panel.minX, y: panel.maxY - 70, width: panel.width, height: 70).fill()
            let widths: [CGFloat] = [0.66, 0.50, 0.74, 0.44, 0.60]
            for row in 0..<5 {
                let y = panel.maxY - 70 - 64 - CGFloat(row) * 66
                let isCursor = index == 0 && row == 1
                if isCursor {
                    color(0x2F6BF0).setFill()
                    NSRect(x: panel.minX, y: y - 18, width: panel.width, height: 56).fill()
                }
                let isMarked = index == 0 && row == 3
                let fill = isCursor ? color(0xFFFFFF, 0.95) : isMarked ? color(0xE5484D) : color(0x8C95A6)
                line(panel.minX + 34, y, (panel.width - 68) * widths[(row + index * 2) % widths.count], 20, fill)
            }
        }
    }

    // The F5 arrow from the left panel into the right one.
    let arrow = NSBezierPath()
    let midY: CGFloat = 470
    let shaft: CGFloat = 50, head: CGFloat = 112
    arrow.move(to: NSPoint(x: 360, y: midY + shaft))
    arrow.line(to: NSPoint(x: 590, y: midY + shaft))
    arrow.line(to: NSPoint(x: 590, y: midY + head))
    arrow.line(to: NSPoint(x: 740, y: midY))
    arrow.line(to: NSPoint(x: 590, y: midY - head))
    arrow.line(to: NSPoint(x: 590, y: midY - shaft))
    arrow.line(to: NSPoint(x: 360, y: midY - shaft))
    arrow.close()
    arrow.lineJoinStyle = .round
    withShadow(offset: 10, blur: 24, alpha: 0.40) {
        color(0xFF8A00).setFill()
        arrow.fill()
    }
    NSGradient(starting: color(0xFFC53D), ending: color(0xFF6A00))!.draw(in: arrow, angle: -90)
    color(0xFFFFFF, 0.9).setStroke()
    arrow.lineWidth = 12
    arrow.stroke()

    // Function key bar.
    for key in 0..<4 {
        let rect = NSRect(x: 176 + CGFloat(key) * 172, y: 200, width: 154, height: 68)
        color(0xFFFFFF, key == 1 ? 0.60 : 0.24).setFill()
        rounded(rect, 20).fill()
    }
}

// MARK: - B: the classic blue commander, as a Mac window

func roundedFont(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    return font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? font
}

func glowing(_ glow: NSColor, blur: CGFloat, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowOffset = .zero
    shadow.shadowBlurRadius = blur
    shadow.shadowColor = glow
    shadow.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

func drawClassic() {
    background(color(0x3A78FF), color(0x0B1D63))

    // The window: a dark screen with a title bar and traffic lights.
    let window = NSRect(x: 158, y: 282, width: 708, height: 548)
    let windowShape = rounded(window, 46)
    withShadow(offset: 14, blur: 28, alpha: 0.45) {
        color(0x071342).setFill()
        windowShape.fill()
    }
    NSGradient(starting: color(0x0D1F66), ending: color(0x050D33))!.draw(in: windowShape, angle: -90)
    clipped(windowShape) {
        NSGradient(starting: color(0xFFFFFF, 0.14), ending: color(0xFFFFFF, 0.04))!
            .draw(in: NSRect(x: window.minX, y: window.maxY - 64, width: window.width, height: 64), angle: -90)
    }
    color(0xFFFFFF, 0.22).setStroke()
    let bezel = rounded(window.insetBy(dx: 1.5, dy: 1.5), 45)
    bezel.lineWidth = 3
    bezel.stroke()
    for (index, hex) in [UInt32(0xFF5F57), 0xFEBC2E, 0x28C840].enumerated() {
        let center = NSPoint(x: window.minX + 44 + CGFloat(index) * 38, y: window.maxY - 32)
        color(hex).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 12, y: center.y - 12, width: 24, height: 24)).fill()
    }

    // Two panels with the double frame, glowing like the old screens.
    let panelBottom = window.minY + 22
    let panelHeight = window.height - 64 - 22 - 14
    for (index, x) in [window.minX + 22, window.midX + 8].enumerated() {
        let panel = NSRect(x: x, y: panelBottom, width: window.width / 2 - 30, height: panelHeight)
        let shape = rounded(panel, 26)
        NSGradient(starting: color(0x1747D0), ending: color(0x0C2B96))!.draw(in: shape, angle: -90)
        let cyan = color(0x7DEBFA)
        glowing(color(0x38D6F5, 0.9), blur: 14) {
            cyan.withAlphaComponent(0.75).setStroke()
            let outer = rounded(panel.insetBy(dx: 12, dy: 12), 17)
            outer.lineWidth = 5
            outer.stroke()
            cyan.setStroke()
            let inner = rounded(panel.insetBy(dx: 26, dy: 26), 10)
            inner.lineWidth = 5
            inner.stroke()
        }
        clipped(rounded(panel.insetBy(dx: 34, dy: 34), 6)) {
            let widths: [CGFloat] = [0.70, 0.52, 0.80, 0.46, 0.64, 0.58]
            for row in 0..<6 {
                let y = panel.maxY - 74 - CGFloat(row) * 60
                let isCursor = index == 0 && row == 2
                if isCursor {
                    let bar = rounded(NSRect(x: panel.minX + 40, y: y - 15, width: panel.width - 80, height: 52), 12)
                    NSGradient(starting: color(0x8CF3FF), ending: color(0x2CC6E8))!.draw(in: bar, angle: -90)
                }
                let isMarked = index == 0 && (row == 4 || row == 5)
                let fill = isCursor ? color(0x06103A) : isMarked ? color(0xFFD84D) : cyan.withAlphaComponent(0.85)
                line(panel.minX + 58, y, (panel.width - 116) * widths[(row + index * 3) % widths.count], 22, fill)
            }
        }
    }

    // Function keys as keycaps; F5 (copy) is lit.
    let keyFont = roundedFont(40, .bold)
    for (index, label) in ["F5", "F6", "F7", "F8"].enumerated() {
        let key = NSRect(x: window.minX + CGFloat(index) * 182, y: 168, width: 162, height: 82)
        let shape = rounded(key, 24)
        let lit = index == 0
        withShadow(offset: 6, blur: 10, alpha: 0.40) {
            (lit ? color(0x2CC6E8) : color(0x1B2E78)).setFill()
            shape.fill()
        }
        NSGradient(starting: lit ? color(0x9AF5FF) : color(0x3452B0),
                   ending: lit ? color(0x22B8DD) : color(0x16266A))!.draw(in: shape, angle: -90)
        color(0xFFFFFF, lit ? 0.6 : 0.25).setStroke()
        let edge = rounded(key.insetBy(dx: 1.5, dy: 1.5), 23)
        edge.lineWidth = 3
        edge.stroke()
        let text = NSAttributedString(string: label, attributes: [
            .font: keyFont, .foregroundColor: lit ? color(0x06103A) : color(0xFFFFFF, 0.9),
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: key.midX - size.width / 2, y: key.midY - size.height / 2 + 1))
    }
}

// MARK: - C: origami — a sheet folded into two panels

func drawOrigami() {
    background(color(0x2BC0B4), color(0x0B4F6C))

    let top: CGFloat = 790, bottom: CGFloat = 250
    let left = NSBezierPath()
    left.move(to: NSPoint(x: 512, y: top - 40))
    left.line(to: NSPoint(x: 200, y: top))
    left.line(to: NSPoint(x: 200, y: bottom + 40))
    left.line(to: NSPoint(x: 512, y: bottom))
    left.close()
    let right = NSBezierPath()
    right.move(to: NSPoint(x: 512, y: top - 40))
    right.line(to: NSPoint(x: 824, y: top))
    right.line(to: NSPoint(x: 824, y: bottom + 40))
    right.line(to: NSPoint(x: 512, y: bottom))
    right.close()
    for path in [left, right] {
        path.lineJoinStyle = .round
    }
    withShadow(offset: 14, blur: 30, alpha: 0.35) {
        color(0xFFFFFF).setFill()
        left.fill()
        right.fill()
    }
    NSGradient(starting: color(0xFFFFFF), ending: color(0xDCE6EE))!.draw(in: left, angle: 0)
    NSGradient(starting: color(0xC9D6E0), ending: color(0xF3F7FA))!.draw(in: right, angle: 0)

    // Rows follow the slant of each half: they start at the outer edge and run
    // towards the fold (down on the left half, up on the right one).
    func rows(on path: NSBezierPath, fromX: CGFloat, slope: CGFloat, cursor: Int?, marked: Int?) {
        clipped(path) {
            let widths: [CGFloat] = [0.72, 0.54, 0.80, 0.48, 0.62]
            let angle = atan(slope) * 180 / .pi
            for row in 0..<5 {
                let baseY = top - 120 - CGFloat(row) * 84 + (slope < 0 ? 40 : 0)
                let transform = AffineTransform(translationByX: fromX, byY: baseY)
                var rotated = transform
                rotated.rotate(byDegrees: angle)
                if row == cursor {
                    let bar = NSBezierPath(rect: NSRect(x: -40, y: -20, width: 400, height: 64))
                    bar.transform(using: rotated)
                    color(0x1E9E95).setFill()
                    bar.fill()
                }
                let fill: NSColor = row == cursor ? color(0xFFFFFF) : row == marked ? color(0xE5484D) : color(0x7B8A99)
                let shape = rounded(NSRect(x: 36, y: 0, width: 240 * widths[row], height: 22), 11)
                shape.transform(using: rotated)
                fill.setFill()
                shape.fill()
            }
        }
    }
    rows(on: left, fromX: 200, slope: -40 / 312, cursor: 1, marked: 3)
    rows(on: right, fromX: 512, slope: 40 / 312, cursor: nil, marked: nil)

    // The fold.
    let fold = NSBezierPath()
    fold.move(to: NSPoint(x: 512, y: top - 40))
    fold.line(to: NSPoint(x: 512, y: bottom))
    fold.lineWidth = 6
    color(0x0B4F6C, 0.35).setStroke()
    fold.stroke()
}

func drawIcon() {
    switch variant {
    case "arrow": drawArrow()
    case "origami": drawOrigami()
    default: drawClassic()
    }
}

// MARK: - Output

func image(pixels: Int, draw: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.imageInterpolation = .high
    let scale = CGFloat(pixels) / 1024
    NSGraphicsContext.current!.cgContext.scaleBy(x: scale, y: scale)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func png(_ rep: NSBitmapImageRep) -> Data {
    rep.representation(using: .png, properties: [:])!
}

if variant == "preview" {
    // Each variant large, then at Dock / Finder sizes, on light and dark backgrounds.
    let output = URL(filePath: arguments.count > 1 ? arguments[1] : "build/icon-preview.png")
    let variants = ["classic", "arrow", "origami"]
    let width = 1500, height = 1020
    let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
    color(0xF2F2F5).setFill()
    NSRect(x: 0, y: height / 2, width: width, height: height / 2).fill()
    color(0x1C1C1E).setFill()
    NSRect(x: 0, y: 0, width: width, height: height / 2).fill()
    for (index, name) in variants.enumerated() {
        let x = CGFloat(40 + index * 490)
        for (row, y) in [CGFloat(height / 2 + 40), 40].enumerated() {
            let large = CGFloat(420)
            for size in [large, 64, 32, 16] {
                let pixels = Int(size)
                let rep = renderVariant(name, pixels: pixels * 2)
                let origin: NSPoint
                switch size {
                case large: origin = NSPoint(x: x, y: y + 50)
                case 64: origin = NSPoint(x: x + 20, y: y)
                case 32: origin = NSPoint(x: x + 110, y: y + 16)
                default: origin = NSPoint(x: x + 170, y: y + 24)
                }
                rep.draw(in: NSRect(origin: origin, size: NSSize(width: size, height: size)), from: .zero,
                         operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            }
            let label = NSString(string: "\(index + 1). \(name)")
            label.draw(at: NSPoint(x: x + 250, y: y + 16), withAttributes: [
                .font: NSFont.systemFont(ofSize: 28, weight: .semibold),
                .foregroundColor: row == 0 ? color(0x1C1C1E) : color(0xF2F2F5),
            ])
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    try png(sheet).write(to: output)
    print("Wrote \(output.path)")
    exit(0)
}

func renderVariant(_ name: String, pixels: Int) -> NSBitmapImageRep {
    image(pixels: pixels) {
        switch name {
        case "arrow": drawArrow()
        case "origami": drawOrigami()
        default: drawClassic()
        }
    }
}

let output = URL(filePath: arguments.count > 1 ? arguments[1] : "OriCmd/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try png(image(pixels: points * scale, draw: drawIcon)).write(to: output.appending(path: name))
        images.append(["size": "\(points)x\(points)", "idiom": "mac", "filename": name, "scale": "\(scale)x"])
    }
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appending(path: "Contents.json"))
print("Wrote \(images.count) icons (\(variant)) to \(output.path)")
