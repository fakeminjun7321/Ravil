import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else { fatalError("usage: make_icon.swift output.png") }
let size = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let bounds = NSRect(x: 42, y: 42, width: 940, height: 940)
let shape = NSBezierPath(roundedRect: bounds, xRadius: 220, yRadius: 220)
NSGradient(starting: NSColor(calibratedRed: 0.08, green: 0.16, blue: 0.33, alpha: 1),
           ending: NSColor(calibratedRed: 0.35, green: 0.23, blue: 0.67, alpha: 1))!
    .draw(in: shape, angle: 35)

let lines: [(CGFloat, CGFloat)] = [(265, 350), (360, 460), (455, 540), (550, 430), (645, 600), (740, 330)]
let stroke = NSBezierPath()
stroke.lineWidth = 24
stroke.lineCapStyle = .round
stroke.lineJoinStyle = .round
for (index, (x, y)) in lines.enumerated() {
    if index == 0 { stroke.move(to: NSPoint(x: x, y: y)) }
    else { stroke.line(to: NSPoint(x: x, y: y)) }
}
NSColor.white.withAlphaComponent(0.92).setStroke()
stroke.stroke()

let label = "R" as NSString
let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
label.draw(in: NSRect(x: 130, y: 270, width: 765, height: 660), withAttributes: [
    .font: NSFont.systemFont(ofSize: 605, weight: .bold),
    .foregroundColor: NSColor.white.withAlphaComponent(0.15),
    .paragraphStyle: paragraph
])
image.unlockFocus()

let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
let png = representation.representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
