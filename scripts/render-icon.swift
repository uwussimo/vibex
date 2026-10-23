// Cuts the icon plate out of docs/icon-art.png and places it on Apple's macOS icon grid: an 824pt
// continuous rounded square centred on a 1024 canvas, with the standard soft drop shadow.
// Usage: swift scripts/render-icon.swift docs/icon-art.png docs/icon-1024.png
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3, let art = NSImage(contentsOfFile: arguments[1]),
      let source = art.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("usage: render-icon <art.png> <out.png>\n".utf8))
    exit(1)
}

// Where the plate sits in the 1254px art, measured from its edges.
let plate = CGRect(x: 277, y: 259, width: 700, height: 700)
let canvas = 1024, size: CGFloat = 824
let target = CGRect(x: (CGFloat(canvas) - size) / 2, y: (CGFloat(canvas) - size) / 2 + 10, width: size, height: size)

let context = CGContext(
    data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
context.interpolationQuality = .high
// Clip a hair inside the plate so none of the art's black background shows at the corners.
let shape = CGPath(roundedRect: target.insetBy(dx: 2, dy: 2), cornerWidth: 186, cornerHeight: 186, transform: nil)

context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.45))
context.addPath(shape)
context.setFillColor(CGColor(gray: 0.08, alpha: 1))
context.fillPath()
context.restoreGState()

context.addPath(shape)
context.clip()
// CGImage crops use top-left pixel coordinates; the context draws bottom-up.
let crop = source.cropping(to: plate)!
context.draw(crop, in: target)

let output = NSBitmapImageRep(cgImage: context.makeImage()!)
try! output.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: arguments[2]))
