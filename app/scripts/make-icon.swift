// Renders the app icon (1024x1024, no alpha): the bsns wordmark + a terminal
// prompt — "bsns.$_" — on the brand dark field. "bsns" uses the exact brand
// wordmark vector paths (League Spartan, from bsns-wordmark.json), the dot is
// the signal-green logo dot, and "$_" is the prompt in brand green. Pure
// CoreText/CoreGraphics so it runs headless. Usage:
//   swift make-icon.swift <output.png>
import CoreGraphics
import CoreText
import ImageIO
import Foundation
import UniformTypeIdentifiers

let size: CGFloat = 1024
let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"

// Brand tokens (packages/shared/src/brand/tokens.ts).
let inkDark = CGColor(red: 0.051, green: 0.051, blue: 0.051, alpha: 1)   // #0D0D0D
let paper   = CGColor(red: 0.973, green: 0.973, blue: 0.973, alpha: 1)   // #F8F8F8
let signal  = CGColor(red: 0.0,   green: 0.722, blue: 0.541, alpha: 1)   // #00B88A

// MARK: minimal SVG path parser (supports M m L l C c Z z — all the wordmark uses)

func parseSVGPath(_ d: String) -> CGPath {
    let p = CGMutablePath()
    let s = Array(d)
    var i = 0
    var cur = CGPoint.zero
    var start = CGPoint.zero

    func skipSep() {
        while i < s.count, s[i] == " " || s[i] == "," || s[i] == "\n" || s[i] == "\t" { i += 1 }
    }
    func number() -> CGFloat {
        skipSep()
        var str = ""
        if i < s.count, s[i] == "-" || s[i] == "+" { str.append(s[i]); i += 1 }
        while i < s.count, s[i].isNumber || s[i] == "." { str.append(s[i]); i += 1 }
        return CGFloat(Double(str) ?? 0)
    }

    var cmd: Character = " "
    while i < s.count {
        skipSep()
        if i >= s.count { break }
        if s[i].isLetter { cmd = s[i]; i += 1 }
        switch cmd {
        case "M", "m":
            let rel = cmd == "m"
            let x = number(), y = number()
            cur = rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
            p.move(to: cur); start = cur
            cmd = rel ? "l" : "L"        // subsequent pairs are implicit lineto
        case "L", "l":
            let rel = cmd == "l"
            let x = number(), y = number()
            cur = rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
            p.addLine(to: cur)
        case "C", "c":
            let rel = cmd == "c"
            let x1 = number(), y1 = number(), x2 = number(), y2 = number(), x = number(), y = number()
            let c1 = rel ? CGPoint(x: cur.x + x1, y: cur.y + y1) : CGPoint(x: x1, y: y1)
            let c2 = rel ? CGPoint(x: cur.x + x2, y: cur.y + y2) : CGPoint(x: x2, y: y2)
            let end = rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
            p.addCurve(to: end, control1: c1, control2: c2); cur = end
        case "Z", "z":
            p.closeSubpath(); cur = start
        default:
            i += 1                        // unknown: skip
        }
    }
    return p
}

// MARK: load wordmark paths (sibling JSON)

let jsonURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("bsns-wordmark.json")
guard let data = try? Data(contentsOf: jsonURL),
      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let letters = obj["letters"] as? [String],
      let dot = obj["dot"] as? String
else { FileHandle.standardError.write("missing bsns-wordmark.json\n".data(using: .utf8)!); exit(1) }

let letterPaths = letters.map(parseSVGPath)
let dotPath = parseSVGPath(dot)

// MARK: compose

guard let ctx = CGContext(
    data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else { exit(1) }

ctx.setFillColor(inkDark)
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

// The wordmark paths live in a 1310×438 (y-down) viewBox.
let vbW: CGFloat = 1310, vbH: CGFloat = 438
let scale: CGFloat = 0.455
let wmW = vbW * scale, wmH = vbH * scale

// "$_" prompt sized to roughly match the wordmark cap height.
let promptFont = CTFontCreateWithName("Menlo-Bold" as CFString, wmH * 1.04, nil)
let promptAttr = CFAttributedStringCreate(nil, "$_" as CFString,
    [kCTFontAttributeName: promptFont, kCTForegroundColorAttributeName: signal] as CFDictionary)!
let promptLine = CTLineCreateWithAttributedString(promptAttr)
let promptBounds = CTLineGetBoundsWithOptions(promptLine, .useOpticalBounds)

let gap: CGFloat = 46
let groupW = wmW + gap + promptBounds.width
let ox = (size - groupW) / 2
let oy = (size - wmH) / 2          // wordmark bottom-left in device space
let centerY = oy + wmH / 2

// Draw the wordmark (y-down viewBox → flip into device y-up).
ctx.saveGState()
ctx.translateBy(x: ox, y: oy)
ctx.scaleBy(x: scale, y: scale)
ctx.translateBy(x: 0, y: vbH)
ctx.scaleBy(x: 1, y: -1)
for letter in letterPaths { ctx.addPath(letter); ctx.setFillColor(paper); ctx.fillPath() }
ctx.addPath(dotPath); ctx.setFillColor(signal); ctx.fillPath()
ctx.restoreGState()

// Draw "$_" vertically centered on the wordmark, to its right.
ctx.textPosition = CGPoint(
    x: ox + wmW + gap - promptBounds.minX,
    y: centerY - (promptBounds.minY + promptBounds.height / 2)
)
CTLineDraw(promptLine, ctx)

guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
else { exit(1) }
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(path)")
