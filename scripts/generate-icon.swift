import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: generate-icon.swift <output.png>\n".utf8))
    exit(64)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)

image.lockFocus()

let canvas = NSRect(origin: .zero, size: size)
let outer = NSBezierPath(roundedRect: canvas.insetBy(dx: 28, dy: 28), xRadius: 220, yRadius: 220)
let ocean = NSGradient(colors: [
    NSColor(calibratedRed: 0.025, green: 0.055, blue: 0.090, alpha: 1),
    NSColor(calibratedRed: 0.015, green: 0.125, blue: 0.165, alpha: 1),
    NSColor(calibratedRed: 0.015, green: 0.220, blue: 0.250, alpha: 1),
])!
ocean.draw(in: outer, angle: -55)

let glow = NSBezierPath(ovalIn: NSRect(x: 160, y: 120, width: 704, height: 704))
NSColor(calibratedRed: 0.0, green: 0.88, blue: 0.83, alpha: 0.11).setFill()
glow.fill()

let cove = NSBezierPath()
cove.lineWidth = 104
cove.lineCapStyle = .round
cove.appendArc(
    withCenter: NSPoint(x: 512, y: 514),
    radius: 260,
    startAngle: 52,
    endAngle: 308,
    clockwise: false
)
NSColor(calibratedRed: 0.72, green: 1.0, blue: 0.96, alpha: 0.96).setStroke()
cove.stroke()

let innerCove = NSBezierPath()
innerCove.lineWidth = 26
innerCove.lineCapStyle = .round
innerCove.appendArc(
    withCenter: NSPoint(x: 512, y: 514),
    radius: 178,
    startAngle: 78,
    endAngle: 282,
    clockwise: false
)
NSColor(calibratedRed: 0.08, green: 0.72, blue: 0.76, alpha: 0.85).setStroke()
innerCove.stroke()

let statusRect = NSRect(x: 708, y: 690, width: 116, height: 116)
let status = NSBezierPath(ovalIn: statusRect)
NSColor(calibratedRed: 0.18, green: 1.0, blue: 0.56, alpha: 1).setFill()
status.fill()

let highlight = NSBezierPath(ovalIn: statusRect.insetBy(dx: 28, dy: 28))
NSColor(calibratedWhite: 1, alpha: 0.62).setFill()
highlight.fill()

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiff),
    let png = bitmap.representation(using: .png, properties: [:])
else {
    FileHandle.standardError.write(Data("failed to encode icon\n".utf8))
    exit(1)
}

try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try png.write(to: outputURL, options: .atomic)

