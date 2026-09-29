// Turns Resources/icon-source.png (icon on a black background) into Resources/AppIcon.icns.
// Finds the icon's rounded square, drops the black, and fits it to Apple's
// 1024 grid (824pt body, transparent margin) so it matches other Dock icons.
//   swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let src = root.appendingPathComponent("Resources/icon-source.png")
guard let image = NSImage(contentsOf: src), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("can't read \(src.path)")
}

// Find the bounding box of non-black pixels.
let w = cg.width, h = cg.height
var pixels = [UInt8](repeating: 0, count: w * h * 4)
let rgb = CGColorSpaceCreateDeviceRGB()
let scan = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                     space: rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
scan.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
// Count bright pixels per row and column; only rows/columns that are mostly icon count,
// so stray specks in the background don't widen the box.
var rowHits = [Int](repeating: 0, count: h), colHits = [Int](repeating: 0, count: w)
for y in 0..<h { for x in 0..<w {
    let i = (y * w + x) * 4
    if Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2]) > 60 { rowHits[y] += 1; colHits[x] += 1 }
}}
let rows = rowHits.indices.filter { rowHits[$0] > w / 3 }
let cols = colHits.indices.filter { colHits[$0] > h / 3 }
guard let minY = rows.first, let maxY = rows.last, let minX = cols.first, let maxX = cols.last else {
    fatalError("couldn't find the icon in the image")
}
// Crop to the art's exact bounds (not a padded square), so it fills the icon shape;
// macOS 26 puts icons that don't fill it on a gray plate. Bitmap rows are top-down,
// which matches CGImage cropping coordinates.
guard let body = cg.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)) else {
    fatalError("crop failed")
}
print("icon body found at \(minX),\(minY) size \(maxX - minX + 1)x\(maxY - minY + 1)")

// The art's edge color, sampled just inside its left edge at mid-height. Filling the
// icon shape with it first makes every pixel opaque, even where the art's soft edges or
// rounder corners are see-through; macOS 26 plates icons that don't fill the shape.
let edgeColor: CGColor = {
    let x = minX + (maxX - minX) / 25, y = (minY + maxY) / 2
    let i = (y * w + x) * 4
    let a = max(CGFloat(pixels[i + 3]) / 255, 0.01)   // pixels are premultiplied
    return CGColor(srgbRed: CGFloat(pixels[i]) / 255 / a, green: CGFloat(pixels[i + 1]) / 255 / a,
                   blue: CGFloat(pixels[i + 2]) / 255 / a, alpha: 1)
}()

// Render onto the 1024 grid, clipped to a rounded rect slightly inside the art's own edge.
func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let inset = s * 100 / 1024
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let clip = rect.insetBy(dx: rect.width * 0.012, dy: rect.width * 0.012)
    ctx.addPath(CGPath(roundedRect: clip, cornerWidth: clip.width * 0.235, cornerHeight: clip.width * 0.235, transform: nil))
    ctx.clip()
    ctx.setFillColor(edgeColor)
    ctx.fill(rect)
    ctx.draw(body, in: rect)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! render(1024).write(to: root.appendingPathComponent("Resources/AppIcon-preview.png"))

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
