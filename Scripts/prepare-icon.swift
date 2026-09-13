import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Package the approved artwork; iOS applies the home-screen corner mask.
guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift Scripts/prepare-icon.swift Branding/MoriSpace-icon.png")
}
let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(source, 0, nil),
      artwork.width == artwork.height else { fatalError("The source must be a square image") }
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let assets = root.appendingPathComponent("MoriPhotos/Assets.xcassets")
for (relativePath, side) in [("AppIcon.appiconset/AppIcon.png", 1024), ("AppBrand.imageset/AppBrand.png", 512)] {
    let output = assets.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        fatalError("Cannot create the opaque sRGB icon bitmap")
    }
    context.interpolationQuality = .high
    context.draw(artwork, in: CGRect(x: 0, y: 0, width: side, height: side))
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Cannot create PNG output")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Cannot save PNG output") }
    print("Prepared \(relativePath): \(side) × \(side), opaque sRGB")
}
