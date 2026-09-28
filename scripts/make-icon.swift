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
var minX = w, minY = h, maxX = 0, maxY = 0
for y in 0..<h { for x in 0..<w {
    let i = (y * w + x) * 4
    if Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2]) > 60 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    }
}}
let side = max(maxX - minX, maxY - minY)
// Bitmap rows are stored top-down, which matches CGImage cropping coordinates.
guard let body = cg.cropping(to: CGRect(x: minX, y: minY, width: side, height: side)) else {
    fatalError("crop failed")
}
print("icon body found at \(minX),\(minY) size \(side)")

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
