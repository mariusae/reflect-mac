import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ReflectCore

/// A blank PNG of a size, to judge.
private func png(_ width: Int, _ height: Int) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

@Suite struct CaptureCoverTests {
    @Test func bannerSizedPicturesAreGood() {
        #expect(CaptureCover.isGood(png(1200, 630)))
        #expect(CaptureCover.isGood(png(800, 800)))
    }

    @Test func iconsSlivesAndTowersAreNot() {
        #expect(!CaptureCover.isGood(png(64, 64)))
        #expect(!CaptureCover.isGood(png(1200, 100)))
        #expect(!CaptureCover.isGood(png(400, 1200)))
        #expect(!CaptureCover.isGood(Data("not a picture".utf8)))
    }

    @Test func sitesStockPicturesAreGeneric() {
        #expect(CaptureCover.looksGeneric("https://e.com/static/logo-share.png"))
        #expect(CaptureCover.looksGeneric("https://e.com/img/og-default.jpg"))
        #expect(CaptureCover.looksGeneric("https://e.com/brand/logos/wide.png"))
        #expect(!CaptureCover.looksGeneric("https://e.com/2026/10/lead-photo.jpg"))
    }

    @Test func pngIsKeptAsPng() {
        #expect(CaptureCover.fileExtension(png(10, 10)) == "png")
    }
}
