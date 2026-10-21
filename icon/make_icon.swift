// Renders the MicSwitch app icon (1024x1024 PNG).
// Usage: swift icon/make_icon.swift icon/icon.png

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Top-left origin, y grows downwards.
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func linearGradient(_ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                       colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

// MARK: Background squircle (macOS icon grid: 824pt tile, 100pt margin)

let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(rgb(0x2B1D7E))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
linearGradient([rgb(0x7B6CFF), rgb(0x4B32D6), rgb(0x22145F)],
               from: CGPoint(x: 300, y: 100), to: CGPoint(x: 724, y: 924))
// Soft glow behind the headphones.
let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                      colors: [rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0)] as CFArray, locations: nil)!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 470, y: 470), startRadius: 0,
                       endCenter: CGPoint(x: 470, y: 470), endRadius: 380, options: [])
ctx.restoreGState()

// MARK: Headphones

let hx: CGFloat = 470, hy: CGFloat = 500, hr: CGFloat = 212

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 24, color: rgb(0x0B0530, 0.45))
ctx.setStrokeColor(rgb(0xFFFFFF))
ctx.setFillColor(rgb(0xFFFFFF))
ctx.setLineWidth(58)
ctx.setLineCap(.round)
ctx.addArc(center: CGPoint(x: hx, y: hy), radius: hr, startAngle: .pi, endAngle: 0, clockwise: false)
ctx.strokePath()
for cx in [hx - hr, hx + hr] {
    let cup = CGRect(x: cx - 56, y: hy - 30, width: 112, height: 200)
    ctx.addPath(CGPath(roundedRect: cup, cornerWidth: 52, cornerHeight: 52, transform: nil))
    ctx.fillPath()
}
ctx.restoreGState()

// MARK: Mic badge

let bc = CGPoint(x: 728, y: 728), br: CGFloat = 138

// Cut-out ring in the tile colour so the badge reads as sitting on top.
ctx.setFillColor(rgb(0x2E1B8C))
ctx.fillEllipse(in: CGRect(x: bc.x - br - 22, y: bc.y - br - 22, width: (br + 22) * 2, height: (br + 22) * 2))

ctx.saveGState()
ctx.addEllipse(in: CGRect(x: bc.x - br, y: bc.y - br, width: br * 2, height: br * 2))
ctx.clip()
linearGradient([rgb(0x4AF0B0), rgb(0x10B981)],
               from: CGPoint(x: bc.x, y: bc.y - br), to: CGPoint(x: bc.x, y: bc.y + br))
ctx.restoreGState()

ctx.setFillColor(rgb(0xFFFFFF))
ctx.setStrokeColor(rgb(0xFFFFFF))
ctx.addPath(CGPath(roundedRect: CGRect(x: bc.x - 30, y: bc.y - 84, width: 60, height: 112),
                   cornerWidth: 30, cornerHeight: 30, transform: nil))
ctx.fillPath()
ctx.setLineWidth(17)
ctx.setLineCap(.round)
ctx.addArc(center: CGPoint(x: bc.x, y: bc.y - 4), radius: 58, startAngle: 0, endAngle: .pi, clockwise: false)
ctx.strokePath()
ctx.move(to: CGPoint(x: bc.x, y: bc.y + 54)); ctx.addLine(to: CGPoint(x: bc.x, y: bc.y + 84))
ctx.move(to: CGPoint(x: bc.x - 34, y: bc.y + 84)); ctx.addLine(to: CGPoint(x: bc.x + 34, y: bc.y + 84))
ctx.strokePath()

// MARK: Write PNG

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL,
                                           UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("Wrote \(out)")
