// Renders Dictator's app icon: a saffron→rose rounded square with a white waveform.
import AppKit
let out = CommandLine.arguments[1]
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(red: 1, green: 0.6, blue: 0.2, alpha: 1), NSColor(red: 0.95, green: 0.3, blue: 0.5, alpha: 1)])!
    .draw(in: path, angle: -60)
NSColor.white.setFill()
let heights: [CGFloat] = [0.22, 0.42, 0.68, 0.5, 0.82, 0.5, 0.68, 0.42, 0.22]
let barW: CGFloat = 46, gap: CGFloat = 30
let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
for (i, h) in heights.enumerated() {
    let height = 560 * h
    let x = (size - total) / 2 + CGFloat(i) * (barW + gap)
    NSBezierPath(roundedRect: NSRect(x: x, y: (size - height) / 2, width: barW, height: height), xRadius: barW / 2, yRadius: barW / 2).fill()
}
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
