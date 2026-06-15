// Renders the app icon (1024x1024, no alpha) — a terminal prompt on a dark
// field. Pure CoreText/ImageIO so it runs headless. Usage:
//   swift make-icon.swift <output.png>
import CoreGraphics
import CoreText
import ImageIO
import Foundation
import UniformTypeIdentifiers

let size = 1024
let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"

guard let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else { exit(1) }

// Background.
ctx.setFillColor(CGColor(red: 0.043, green: 0.05, blue: 0.07, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

// Prompt glyph.
let font = CTFontCreateWithName("Menlo-Bold" as CFString, 540, nil)
let color = CGColor(red: 0.36, green: 0.92, blue: 0.55, alpha: 1)
let attrs = [
    kCTFontAttributeName: font,
    kCTForegroundColorAttributeName: color,
] as CFDictionary
let attr = CFAttributedStringCreate(nil, "$_" as CFString, attrs)!
let line = CTLineCreateWithAttributedString(attr)
let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
ctx.textPosition = CGPoint(
    x: (CGFloat(size) - bounds.width) / 2 - bounds.minX,
    y: (CGFloat(size) - bounds.height) / 2 - bounds.minY
)
CTLineDraw(line, ctx)

guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
else { exit(1) }
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(path)")
