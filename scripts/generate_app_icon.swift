import CoreGraphics
import CoreText
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

private func usageAndExit() -> Never {
    fputs("usage: generate_app_icon.swift --out-dir /path/to/AppIcon.appiconset\n", stderr)
    exit(2)
}

private func argValue(_ name: String) -> String? {
    guard let idx = CommandLine.arguments.firstIndex(of: name) else { return nil }
    let next = CommandLine.arguments.index(after: idx)
    guard next < CommandLine.arguments.endIndex else { return nil }
    return CommandLine.arguments[next]
}

guard let outDir = argValue("--out-dir") else { usageAndExit() }
let outDirURL = URL(fileURLWithPath: outDir, isDirectory: true)

private func renderImage(side: Int) -> CGImage? {
    let size = CGSize(width: side, height: side)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

    guard let ctx = CGContext(
        data: nil,
        width: Int(size.width),
        height: Int(size.height),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        return nil
    }

    let rect = CGRect(origin: .zero, size: size)

    // Base: near-black.
    ctx.setFillColor(CGColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 1.0))
    ctx.fill(rect)

    // Diagonal indigo -> magenta gradient.
    let gradientColors: [CGColor] = [
        CGColor(red: 0.22, green: 0.22, blue: 0.60, alpha: 1.0), // indigo
        CGColor(red: 0.84, green: 0.18, blue: 0.62, alpha: 1.0)  // magenta
    ]
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors as CFArray, locations: [0.0, 1.0]) {
        ctx.saveGState()
        ctx.addRect(rect)
        ctx.clip()
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: CGFloat(side) * 0.14, y: CGFloat(side) * 0.88),
            end: CGPoint(x: CGFloat(side) * 0.88, y: CGFloat(side) * 0.14),
            options: []
        )
        ctx.restoreGState()
    }

    // Subtle vignette for contrast.
    if let vignette = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(red: 0, green: 0, blue: 0, alpha: 0.0),
            CGColor(red: 0, green: 0, blue: 0, alpha: 0.55)
        ] as CFArray,
        locations: [0.0, 1.0]
    ) {
        ctx.saveGState()
        ctx.addRect(rect)
        ctx.clip()
        ctx.drawRadialGradient(
            vignette,
            startCenter: CGPoint(x: CGFloat(side) / 2, y: CGFloat(side) / 2),
            startRadius: CGFloat(side) * 0.12,
            endCenter: CGPoint(x: CGFloat(side) / 2, y: CGFloat(side) / 2),
            endRadius: CGFloat(side) * 0.68,
            options: CGGradientDrawingOptions.drawsAfterEndLocation
        )
        ctx.restoreGState()
    }

    // Big centered "Z".
    let fontSize = CGFloat(side) * 0.70
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white.withAlphaComponent(0.96)
    ]
    let attributed = NSAttributedString(string: "Z", attributes: attrs)
    let line = CTLineCreateWithAttributedString(attributed)

    let bounds = CTLineGetBoundsWithOptions(line, [.useOpticalBounds])
    let x = (size.width - bounds.width) / 2 - bounds.minX
    let y = (size.height - bounds.height) / 2 - bounds.minY - CGFloat(side) * 0.04

    ctx.saveGState()
    ctx.setShouldAntialias(true)
    ctx.setAllowsAntialiasing(true)
    ctx.textMatrix = CGAffineTransform.identity
    ctx.translateBy(x: 0, y: size.height)
    ctx.scaleBy(x: 1, y: -1)
    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, ctx)
    ctx.restoreGState()

    return ctx.makeImage()
}

private func writePNG(image: CGImage, to url: URL) -> Bool {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        return false
    }
    CGImageDestinationAddImage(dest, image, [kCGImagePropertyPNGDictionary: [:]] as CFDictionary)
    return CGImageDestinationFinalize(dest)
}

let fm = FileManager.default
try? fm.createDirectory(at: outDirURL, withIntermediateDirectories: true)

let sizes = [16, 32, 64, 128, 256, 512, 1024]
var wrote: [String] = []

for side in sizes {
    guard let image = renderImage(side: side) else {
        fputs("Failed to render \(side)x\(side)\n", stderr)
        exit(1)
    }
    let url = outDirURL.appendingPathComponent("icon_\(side).png")
    guard writePNG(image: image, to: url) else {
        fputs("Failed to write \(url.path)\n", stderr)
        exit(1)
    }
    wrote.append(url.lastPathComponent)
}

print("Wrote \(wrote.count) files to \(outDirURL.path): " + wrote.joined(separator: ", "))
