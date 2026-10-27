import AppKit

/// 图标：深色圆角底 + 三根竖条（跟状态栏那枚同一个形状）。
/// 跑法：swift scripts/make-icon.swift  → assets/AppIcon.icns
let sizes = [16, 32, 64, 128, 256, 512, 1024]
let assets = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("assets")
let iconset = assets.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func drawIcon(side: CGFloat) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    rep.size = NSSize(width: side, height: side)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let inset = side * 0.098
    let body = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let radius = body.width * 0.224
    let path = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.20, green: 0.24, blue: 0.42, alpha: 1),
        NSColor(srgbRed: 0.11, green: 0.12, blue: 0.22, alpha: 1)
    ])
    gradient?.draw(in: path, angle: -90)

    // 顶部一层很淡的高光，别让它看起来像一块纯色
    NSColor.white.withAlphaComponent(0.06).setFill()
    NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius).fill()

    let bars: [CGFloat] = [0.34, 0.60, 0.44]
    let barWidth = body.width * 0.108
    let gap = body.width * 0.072
    let totalWidth = barWidth * 3 + gap * 2
    let startX = body.midX - totalWidth / 2
    let tallest = body.height * 0.60

    let accent = NSColor(srgbRed: 0.56, green: 0.66, blue: 1.0, alpha: 1)
    for (index, ratio) in bars.enumerated() {
        let height = tallest * ratio
        let rect = NSRect(
            x: startX + CGFloat(index) * (barWidth + gap),
            y: body.midY - height / 2,
            width: barWidth,
            height: height
        )
        let barPath = NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2)
        accent.setFill()
        barPath.fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for side in sizes {
    guard let data = drawIcon(side: CGFloat(side)) else { continue }
    let name = side <= 512 ? "icon_\(side)x\(side).png" : "icon_512x512@2x.png"
    try? data.write(to: iconset.appendingPathComponent(name))
    if side <= 512 {
        let retina = "icon_\(side)x\(side)@2x.png"
        if let big = drawIcon(side: CGFloat(side) * 2) {
            try? big.write(to: iconset.appendingPathComponent(retina))
        }
    }
}
print("iconset 写在 \(iconset.path)，接着跑 iconutil")
