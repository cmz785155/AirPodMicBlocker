// 生成 AirPodMicBlocker 的应用图标（.iconset → .icns）
// 用法：swiftc -O MakeIcon.swift -o makeicon -framework AppKit && ./makeicon <输出目录>
import AppKit
import Foundation

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
}

let symbolCache = NSLock()
var symbolStore: [String: NSImage] = [:]

/// 渲染 SF Symbol 到指定矩形（返回位图）
func drawSymbol(_ name: String, in rect: CGRect, tint: NSColor) {
    symbolCache.lock(); defer { symbolCache.unlock() }
    let img: NSImage
    if let cached = symbolStore[name] {
        img = cached
    } else {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
        let pointSize = rect.width * 0.86
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        let made = base.withSymbolConfiguration(cfg) ?? base
        made.isTemplate = false
        symbolStore[name] = made
        img = made
    }
    img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
}

func renderIcon(pixels: Int) -> Data? {
    let side = CGFloat(pixels)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil,
                              width: Int(side), height: Int(side),
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

    let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ns

    let full = NSRect(x: 0, y: 0, width: side, height: side)
    let radius = side * 0.2237
    let body = NSBezierPath(roundedRect: full, xRadius: radius, yRadius: radius)

    // 渐变底色：蓝 → 紫，自上而下
    ctx.saveGState()
    body.addClip()
    let gradient = NSGradient(colors: [
        color(0x4C8DFF), color(0x2F6FE4), color(0x6C4DF6)
    ])!
    gradient.draw(in: full, angle: -90)
    // 顶部柔光
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.28),
                         NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: 0, y: side * 0.42, width: side, height: side * 0.58), angle: -90)
    ctx.restoreGState()

    // 主体 AirPods
    let glyph = side * 0.58
    drawSymbol("airpods",
               in: NSRect(x: (side - glyph) / 2, y: side * 0.28, width: glyph, height: glyph),
               tint: .white)

    // 右下角徽章：麦克风已禁用
    let badge = side * 0.36
    let badgeRect = NSRect(x: side - badge * 0.86, y: side * 0.09,
                           width: badge, height: badge)
    let circle = NSBezierPath(ovalIn: badgeRect)
    NSColor.white.withAlphaComponent(0.20).setFill()
    circle.fill()
    NSColor.white.withAlphaComponent(0.95).setStroke()
    circle.lineWidth = max(1, side * 0.008)
    circle.stroke()

    let inner = badge * 0.58
    drawSymbol("mic.slash.fill",
               in: NSRect(x: badgeRect.midX - inner / 2, y: badgeRect.midY - inner / 2,
                          width: inner, height: inner),
               tint: .white)

    // 外描边
    NSColor.white.withAlphaComponent(0.14).setStroke()
    body.lineWidth = max(1, side * 0.006)
    body.stroke()

    NSGraphicsContext.restoreGraphicsState()

    guard let cg = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: cg)
    return rep.representation(using: .png, properties: [:])
}

// main
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./AirPodMicBlocker.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let variants: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png")
]

for (px, name) in variants {
    guard let png = renderIcon(pixels: px) else { print("✗ \(name)"); continue }
    try? png.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
    print("✓ \(name)  \(px)×\(px)")
}
print("iconset 已生成：\(outDir)")