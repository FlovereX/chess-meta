//
//  BoardRectifier.swift
//  CameraAccess
//
//  Deterministic CPU perspective correction. Core is Foundation + CoreGraphics only;
//  the UIImage conversion lives in a small extension at the bottom.
//

import CoreGraphics
import Foundation

/// 8-bit grayscale image, row-major, origin top-left.
struct GrayImage: Sendable {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    subscript(x: Int, y: Int) -> UInt8 {
        pixels[y * width + x]
    }
}

extension GrayImage {
    /// Draws `cgImage` into a DeviceGray 8-bit context. Returns nil for empty images
    /// or if the context cannot be created.
    init?(cgImage: CGImage) {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: width * height)
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, pixels: buffer)
    }

    func toCGImage() -> CGImage? {
        guard width > 0, height > 0, pixels.count == width * height,
              let provider = CGDataProvider(data: Data(pixels) as CFData)
        else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

struct RectificationResult: Sendable {
    let image: GrayImage
    /// Fraction of output pixels whose source sample fell inside the input frame.
    let visibleFraction: Double
}

enum BoardRectifier {
    /// Gray level written for output pixels whose source sample is outside the frame.
    static let outOfBoundsFill: UInt8 = 128

    /// Inverse-mapping warp with bilinear sampling. `quad` is in PIXEL, top-left-origin
    /// space of `image` (see `Quad.init(_:imageSize:)`). The output covers the quad
    /// (expanded by `margin`, as a fraction of the quad's size per side) on an
    /// `outputSize` x `outputSize` grid. Samples outside the input are filled with
    /// `outOfBoundsFill` and counted into `visibleFraction`.
    static func rectify(
        _ image: GrayImage,
        quad: Quad,
        outputSize: Int,
        margin: Double = 0
    ) -> RectificationResult? {
        guard outputSize > 0, image.width > 1, image.height > 1,
              image.pixels.count == image.width * image.height,
              let h = Homography.unitSquare(to: quad)
        else { return nil }

        let m = h.m
        let m0 = m[0], m1 = m[1], m2 = m[2]
        let m3 = m[3], m4 = m[4], m5 = m[5]
        let m6 = m[6], m7 = m[7], m8 = m[8]
        let srcW = image.width
        let srcH = image.height
        let maxX = Double(srcW - 1)
        let maxY = Double(srcH - 1)
        let span = 1 + 2 * margin
        let inv = 1 / Double(outputSize)

        var out = [UInt8](repeating: outOfBoundsFill, count: outputSize * outputSize)
        var visible = 0

        image.pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for oy in 0..<outputSize {
                    let v = (Double(oy) + 0.5) * inv * span - margin
                    for ox in 0..<outputSize {
                        let u = (Double(ox) + 0.5) * inv * span - margin
                        let w = m6 * u + m7 * v + m8
                        guard abs(w) > 1e-12 else { continue }
                        // Source pixel centres sit at integer + 0.5.
                        let sx = (m0 * u + m1 * v + m2) / w - 0.5
                        let sy = (m3 * u + m4 * v + m5) / w - 0.5
                        // Range-check in Double first (NaN fails every comparison).
                        guard sx >= 0, sx <= maxX, sy >= 0, sy <= maxY else { continue }
                        let x0 = min(Int(sx), srcW - 2)
                        let y0 = min(Int(sy), srcH - 2)
                        let fx = sx - Double(x0)
                        let fy = sy - Double(y0)
                        let i = y0 * srcW + x0
                        let top = Double(src[i]) * (1 - fx) + Double(src[i + 1]) * fx
                        let bottom = Double(src[i + srcW]) * (1 - fx) + Double(src[i + srcW + 1]) * fx
                        let value = top * (1 - fy) + bottom * fy
                        dst[oy * outputSize + ox] = UInt8(max(0, min(255, value.rounded())))
                        visible += 1
                    }
                }
            }
        }

        return RectificationResult(
            image: GrayImage(width: outputSize, height: outputSize, pixels: out),
            visibleFraction: Double(visible) / Double(outputSize * outputSize)
        )
    }

    /// Rectifies only the PLAYING AREA (outer quad minus the geometry's border insets).
    static func rectifiedCrop(
        of image: GrayImage,
        geometry: BoardGeometry,
        outputSize: Int = 512
    ) -> RectificationResult? {
        rectify(image, quad: geometry.playingAreaQuad, outputSize: outputSize)
    }
}

#if canImport(UIKit)
import UIKit

extension GrayImage {
    func toUIImage() -> UIImage? {
        toCGImage().map { UIImage(cgImage: $0) }
    }
}
#endif
