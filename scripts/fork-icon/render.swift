#!/usr/bin/env swift
// Draws the fork's app icon and packs it into ForkGhost.icns (next to this file), which
// fork-release.sh bakes into the bundle. Re-run after changing the drawing and commit the
// result; nothing renders at build time.
//
//   swift scripts/fork-icon/render.swift
//
// The drawing: Ghostty's ghost cut from straight lines — every diagonal is 45° — in one
// flat amber on black, with a prompt for a face (chevron eye, block-cursor eye). No
// gradients, no opacity, no curves inside the tile. Units are a 512 tile = 16×16 modules.
import AppKit

typealias Pt = (x: CGFloat, y: CGFloat)

/// `bold` is the small-size cut: bigger body, bigger face, features ≥ 2px at 32px.
struct Cut {
    var x0, x1, y0, y1, shoulder: CGFloat
    var chevron: [Pt]
    var caret: CGRect
    var fringe: CGFloat

    static let full = Cut(
        x0: 96, x1: 416, y0: 64, y1: 448, shoulder: 80,
        chevron: [(160, 176), (208, 176), (272, 240), (208, 304), (160, 304), (224, 240)],
        caret: CGRect(x: 288, y: 176, width: 64, height: 128),
        fringe: 6)
    static let bold = Cut(
        x0: 80, x1: 432, y0: 56, y1: 456, shoulder: 96,
        chevron: [(144, 176), (208, 176), (272, 240), (208, 304), (144, 304), (208, 240)],
        caret: CGRect(x: 304, y: 176, width: 64, height: 128),
        fringe: 0)

    /// Body + both eyes as one path; fill it even-odd and the eyes are holes.
    var path: CGPath {
        let w = x1 - x0, foot = w * 0.15, gap = w * 0.275 // 3 feet + 2 notches = w
        var body: [Pt] = [(x0 + shoulder, y0), (x1 - shoulder, y0), (x1, y0 + shoulder), (x1, y1)]
        var x = x1
        for _ in 0..<2 {
            x -= foot
            body += [(x, y1), (x - gap / 2, y1 - gap / 2), (x - gap, y1)]
            x -= gap
        }
        body += [(x0, y1), (x0, y0 + shoulder)]

        let p = CGMutablePath()
        for poly in [body, chevron] {
            p.addLines(between: poly.map { CGPoint(x: $0.x, y: $0.y) })
            p.closeSubpath()
        }
        p.addRect(caret)
        return p
    }
}

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func render(px: Int, cut: Cut) -> Data {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // y-down, then the standard macOS icon grid: an 824 tile centred on a 1024 canvas.
    let s = CGFloat(px) / 1024
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: s, y: -s)
    ctx.translateBy(x: 100, y: 100)
    ctx.scaleBy(x: 824.0 / 512, y: 824.0 / 512)

    // The hairline edge keeps a black tile from dissolving into a dark Dock or wallpaper.
    let tile = CGPath(roundedRect: CGRect(x: 3, y: 3, width: 506, height: 506),
                      cornerWidth: 116, cornerHeight: 116, transform: nil)
    ctx.addPath(tile); ctx.setFillColor(rgb(0x000000)); ctx.fillPath()
    ctx.addPath(tile); ctx.setStrokeColor(rgb(0x494747)); ctx.setLineWidth(6); ctx.strokePath()

    func fill(_ color: UInt32, dx: CGFloat = 0, blend: CGBlendMode = .normal) {
        ctx.saveGState()
        ctx.translateBy(x: dx, y: dx)
        ctx.setBlendMode(blend)
        ctx.addPath(cut.path); ctx.setFillColor(rgb(color)); ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
    }
    if cut.fringe > 0 {
        // Misregistration, like a CRT that needs degaussing: amber FFBF00 is a red plane
        // plus a green plane (it has no blue). Slip the red up-left and screen the green
        // over it — the overlap sums back to amber, the slivers stay pure red and green.
        fill(0xFF0000, dx: -cut.fringe)
        fill(0x00BF00, blend: .screen)
    } else {
        fill(0xFFBF00)
    }
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

// Which sizes exist matters as much as what is in them. macOS 26+ re-masks an .icns to the
// system shape, but any 16px or 32px representation (16, 16@2x, 32) is instead shrunk onto
// a grey plate, whatever it contains. So the smallest one here is 32@2x: it is not plated,
// Retina 16pt/32pt requests scale down from it (hence the bold cut), and 1x requests scale
// down from 128.
let reps: [(name: String, px: Int, cut: Cut)] = [
    ("32x32@2x", 64, .bold),
    ("128x128", 128, .full), ("128x128@2x", 256, .full),
    ("256x256", 256, .full), ("256x256@2x", 512, .full),
    ("512x512", 512, .full), ("512x512@2x", 1024, .full),
]

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("fork-icon-\(ProcessInfo.processInfo.processIdentifier)")
    .appendingPathComponent("ForkGhost.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset.deletingLastPathComponent()) }
for rep in reps {
    try render(px: rep.px, cut: rep.cut).write(to: iconset.appendingPathComponent("icon_\(rep.name).png"))
}

let out = here.appendingPathComponent("ForkGhost.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
print("✓ \(out.path)")
