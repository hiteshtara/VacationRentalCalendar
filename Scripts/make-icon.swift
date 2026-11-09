#!/usr/bin/env swift
//
// Draws the application icon and writes an .iconset, then leaves iconutil to
// pack it. Run via Scripts/make-icon.sh.
//
// The picture says what the app is for: a calendar whose dates are mostly taken
// — in the three platforms' colours — with one date deliberately left open and
// ringed in green. That open cell is the whole product: the night an Airbnb
// cancellation block would have swallowed, kept sellable.

import AppKit
import CoreGraphics
import Foundation

let outputDirectory = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "./build/AppIcon.iconset"

struct RGB {
    let r: CGFloat, g: CGFloat, b: CGFloat
    init(_ hex: UInt32) {
        r = CGFloat((hex >> 16) & 0xFF) / 255
        g = CGFloat((hex >> 8) & 0xFF) / 255
        b = CGFloat(hex & 0xFF) / 255
    }
    func cg(_ alpha: CGFloat = 1) -> CGColor {
        CGColor(red: r, green: g, blue: b, alpha: alpha)
    }
}

let inkDeep = RGB(0x16233D)
let inkMid = RGB(0x2E4172)
let pageWhite = RGB(0xF7F8FB)
let airbnbCoral = RGB(0xFF5A5F)
let vrboBlue = RGB(0x3C6DF0)
let bookingNavy = RGB(0x003580)
let openGreen = RGB(0x24B36B)

func roundedPath(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func drawIcon(size: CGFloat, into context: CGContext) {
    let s = size

    // --- Background squircle, inset slightly the way Apple's icon grid does ---
    let margin = s * 0.055
    let plate = CGRect(x: margin, y: margin, width: s - margin * 2, height: s - margin * 2)
    let plateRadius = plate.width * 0.235

    context.saveGState()
    context.addPath(roundedPath(plate, plateRadius))
    context.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [inkMid.cg(), inkDeep.cg()] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: plate.midX, y: plate.maxY),
        end: CGPoint(x: plate.midX, y: plate.minY),
        options: []
    )
    context.restoreGState()

    // --- Calendar page ---
    let pageWidth = s * 0.62
    let pageHeight = s * 0.58
    let page = CGRect(
        x: (s - pageWidth) / 2,
        y: (s - pageHeight) / 2 - s * 0.035,
        width: pageWidth,
        height: pageHeight
    )
    let pageRadius = pageWidth * 0.10

    // A soft drop shadow lifts the page off the plate at larger sizes.
    if s >= 64 {
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -s * 0.012),
            blur: s * 0.035,
            color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35)
        )
        context.addPath(roundedPath(page, pageRadius))
        context.setFillColor(pageWhite.cg())
        context.fillPath()
        context.restoreGState()
    } else {
        context.addPath(roundedPath(page, pageRadius))
        context.setFillColor(pageWhite.cg())
        context.fillPath()
    }

    // --- Header band ---
    let headerHeight = page.height * 0.235
    let header = CGRect(
        x: page.minX, y: page.maxY - headerHeight,
        width: page.width, height: headerHeight
    )
    context.saveGState()
    context.addPath(roundedPath(page, pageRadius))
    context.clip()
    context.setFillColor(inkDeep.cg())
    context.fill(header)
    context.restoreGState()

    // Binding rings, only where they will actually be visible.
    if s >= 64 {
        let ringRadius = headerHeight * 0.17
        let ringY = page.maxY - headerHeight * 0.02
        for fraction in [0.3, 0.7] as [CGFloat] {
            let centre = CGPoint(x: page.minX + page.width * fraction, y: ringY)
            context.setFillColor(pageWhite.cg(0.92))
            context.fillEllipse(in: CGRect(
                x: centre.x - ringRadius, y: centre.y - ringRadius,
                width: ringRadius * 2, height: ringRadius * 2
            ))
        }
    }

    // --- Day grid, 3 x 3 ---
    let gridInset = page.width * 0.105
    let gridTop = page.maxY - headerHeight - page.height * 0.085
    let gridWidth = page.width - gridInset * 2
    let gridHeight = gridTop - page.minY - page.height * 0.10
    let gap = gridWidth * 0.085
    let cell = (gridWidth - gap * 2) / 3
    let rowGap = (gridHeight - cell * 3) / 2

    // nil marks the date left deliberately open.
    let palette: [[RGB?]] = [
        [airbnbCoral, airbnbCoral, vrboBlue],
        [vrboBlue, bookingNavy, bookingNavy],
        [bookingNavy, nil, airbnbCoral],
    ]

    let cellRadius = cell * 0.26
    for (rowIndex, row) in palette.enumerated() {
        for (columnIndex, colour) in row.enumerated() {
            let rect = CGRect(
                x: gridInset + page.minX + CGFloat(columnIndex) * (cell + gap),
                y: gridTop - cell - CGFloat(rowIndex) * (cell + rowGap),
                width: cell,
                height: cell
            )
            if let colour {
                context.addPath(roundedPath(rect, cellRadius))
                context.setFillColor(colour.cg())
                context.fillPath()
            } else {
                // The open night: a ring, not a fill.
                let lineWidth = max(s * 0.012, cell * 0.17)
                let inset = lineWidth / 2
                context.addPath(roundedPath(rect.insetBy(dx: inset, dy: inset), cellRadius))
                context.setStrokeColor(openGreen.cg())
                context.setLineWidth(lineWidth)
                context.strokePath()
            }
        }
    }
}

// MARK: - Output

let specifications: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

try? FileManager.default.createDirectory(
    atPath: outputDirectory, withIntermediateDirectories: true
)

for specification in specifications {
    let pixels = specification.pixels
    guard let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        FileHandle.standardError.write(Data("could not create a \(pixels)px context\n".utf8))
        exit(1)
    }
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high
    drawIcon(size: CGFloat(pixels), into: context)

    guard let image = context.makeImage() else { exit(1) }
    let representation = NSBitmapImageRep(cgImage: image)
    representation.size = NSSize(width: pixels, height: pixels)
    guard let data = representation.representation(using: .png, properties: [:]) else { exit(1) }

    let path = "\(outputDirectory)/\(specification.name).png"
    try data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)  (\(pixels)x\(pixels), \(data.count) bytes)")
}
