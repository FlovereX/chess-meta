//
//  SyntheticBoardImage.swift
//  CameraAccessTests
//
//  Test-only deterministic generator of checkerboard frames with known ground truth.
//  Randomness comes from a seeded RNG only, so results never flake.
//

@testable import CameraAccess
import CoreGraphics
import Foundation

/// SplitMix64: tiny, fast, fully deterministic.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Roughly gaussian with unit variance (sum of four uniforms).
    mutating func nextGaussian() -> Double {
        var sum = 0.0
        for _ in 0..<4 { sum += Double.random(in: 0..<1, using: &self) }
        return (sum - 2) / 0.5774
    }
}

struct SyntheticBoardImage {
    /// Pixels per square in the flat (unwarped) board.
    var squareSize = 48
    var light: UInt8 = 200
    var dark: UInt8 = 70
    /// Wooden border around the 8x8 playing area, in flat pixels.
    var borderThickness = 0
    var borderTone: UInt8 = 140
    /// Round blobs on ranks 1, 2, 7, 8 (starting-position occupancy).
    var pieces = false
    var noiseSigma = 0.0
    var blurRadius = 0
    var seed: UInt64 = 1
    /// Gray level of the frame outside the board.
    var backgroundTone: UInt8 = 110

    /// Flat outer size (playing area + border) in pixels.
    var outerSize: Int { 8 * squareSize + 2 * borderThickness }

    /// Ground-truth border fraction (per side) of the outer quad.
    var borderFraction: Double { Double(borderThickness) / Double(outerSize) }

    /// The flat board, a1 (dark) at the bottom-left.
    func flatBoard() -> GrayImage {
        let size = outerSize
        var pixels = [UInt8](repeating: borderTone, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                let px = x - borderThickness
                let py = y - borderThickness
                guard px >= 0, py >= 0, px < 8 * squareSize, py < 8 * squareSize else { continue }
                let file = px / squareSize
                let row = py / squareSize          // 0 at the top
                let rank = 7 - row
                pixels[y * size + x] = (file + rank) % 2 == 0 ? dark : light
            }
        }
        if pieces {
            let radius = 0.2 * Double(squareSize)
            for row in [0, 1, 6, 7] {
                let tone: UInt8 = row >= 6 ? 235 : 30
                for file in 0..<8 {
                    let cx = Double(borderThickness) + (Double(file) + 0.5) * Double(squareSize)
                    let cy = Double(borderThickness) + (Double(row) + 0.5) * Double(squareSize)
                    for y in Int(cy - radius)...Int(cy + radius) {
                        for x in Int(cx - radius)...Int(cx + radius) {
                            let dx = Double(x) - cx
                            let dy = Double(y) - cy
                            if dx * dx + dy * dy <= radius * radius { pixels[y * size + x] = tone }
                        }
                    }
                }
            }
        }
        return GrayImage(width: size, height: size, pixels: pixels)
    }

    /// The outer quad of the board warped into a frame of the given size: blur, then
    /// noise, applied to the final frame.
    func render(frameWidth: Int, frameHeight: Int, quad: Quad) -> GrayImage {
        let flat = flatBoard()
        let fw = Double(flat.width)
        let fh = Double(flat.height)
        guard let toFlat = Homography(
            from: quad.points,
            to: [CGPoint(x: 0, y: 0), CGPoint(x: fw, y: 0), CGPoint(x: fw, y: fh), CGPoint(x: 0, y: fh)]
        ) else {
            preconditionFailure("degenerate quad in test fixture")
        }

        var pixels = [UInt8](repeating: backgroundTone, count: frameWidth * frameHeight)
        for y in 0..<frameHeight {
            for x in 0..<frameWidth {
                let p = toFlat.map(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5))
                let sx = Double(p.x) - 0.5
                let sy = Double(p.y) - 0.5
                guard sx >= 0, sy >= 0, sx <= fw - 1, sy <= fh - 1 else { continue }
                let x0 = min(Int(sx), flat.width - 2)
                let y0 = min(Int(sy), flat.height - 2)
                let ax = sx - Double(x0)
                let ay = sy - Double(y0)
                let top = Double(flat[x0, y0]) * (1 - ax) + Double(flat[x0 + 1, y0]) * ax
                let bottom = Double(flat[x0, y0 + 1]) * (1 - ax) + Double(flat[x0 + 1, y0 + 1]) * ax
                pixels[y * frameWidth + x] = UInt8((top * (1 - ay) + bottom * ay).rounded())
            }
        }

        var image = GrayImage(width: frameWidth, height: frameHeight, pixels: pixels)
        if blurRadius > 0 { image = Self.boxBlur(image, radius: blurRadius) }
        if noiseSigma > 0 { image = Self.addNoise(image, sigma: noiseSigma, seed: seed) }
        return image
    }

    // MARK: - Image operations

    static func boxBlur(_ image: GrayImage, radius: Int) -> GrayImage {
        let w = image.width
        let h = image.height
        var horizontal = [Double](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var sum = 0.0
                var count = 0.0
                for k in max(0, x - radius)...min(w - 1, x + radius) {
                    sum += Double(image.pixels[y * w + k])
                    count += 1
                }
                horizontal[y * w + x] = sum / count
            }
        }
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var sum = 0.0
                var count = 0.0
                for k in max(0, y - radius)...min(h - 1, y + radius) {
                    sum += horizontal[k * w + x]
                    count += 1
                }
                out[y * w + x] = UInt8((sum / count).rounded())
            }
        }
        return GrayImage(width: w, height: h, pixels: out)
    }

    static func addNoise(_ image: GrayImage, sigma: Double, seed: UInt64) -> GrayImage {
        var rng = SeededRNG(seed: seed)
        var out = image
        for i in 0..<out.pixels.count {
            let v = Double(out.pixels[i]) + sigma * rng.nextGaussian()
            out.pixels[i] = UInt8(max(0, min(255, v.rounded())))
        }
        return out
    }

    // MARK: - Quad helpers (pixel, top-left-origin)

    static func centeredQuad(size: Double, center: CGPoint) -> Quad {
        let h = size / 2
        return Quad(
            topLeft: CGPoint(x: center.x - h, y: center.y - h),
            topRight: CGPoint(x: center.x + h, y: center.y - h),
            bottomRight: CGPoint(x: center.x + h, y: center.y + h),
            bottomLeft: CGPoint(x: center.x - h, y: center.y + h)
        )
    }

    /// Narrows the top edge by `topShrink` pixels per side (camera looking down at an angle).
    static func keystone(_ quad: Quad, topShrink: Double) -> Quad {
        var q = quad
        q.topLeft.x += topShrink
        q.topRight.x -= topShrink
        return q
    }

    static func rotated(_ quad: Quad, degrees: Double) -> Quad {
        let pts = quad.points
        let cx = pts.map { Double($0.x) }.reduce(0, +) / 4
        let cy = pts.map { Double($0.y) }.reduce(0, +) / 4
        let a = degrees * .pi / 180
        func rotate(_ p: CGPoint) -> CGPoint {
            let dx = Double(p.x) - cx
            let dy = Double(p.y) - cy
            return CGPoint(x: cx + dx * cos(a) - dy * sin(a), y: cy + dx * sin(a) + dy * cos(a))
        }
        return Quad(
            topLeft: rotate(quad.topLeft),
            topRight: rotate(quad.topRight),
            bottomRight: rotate(quad.bottomRight),
            bottomLeft: rotate(quad.bottomLeft)
        )
    }

    /// Cyclically relabels the corners (what Vision does when the board is turned).
    static func relabelled(_ quad: Quad, quarterTurns: Int) -> Quad {
        var q = quad
        for _ in 0..<((quarterTurns % 4 + 4) % 4) {
            q = Quad(topLeft: q.topRight, topRight: q.bottomRight, bottomRight: q.bottomLeft, bottomLeft: q.topLeft)
        }
        return q
    }

    static func translated(_ quad: Quad, dx: Double, dy: Double) -> Quad {
        func move(_ p: CGPoint) -> CGPoint { CGPoint(x: Double(p.x) + dx, y: Double(p.y) + dy) }
        return Quad(
            topLeft: move(quad.topLeft),
            topRight: move(quad.topRight),
            bottomRight: move(quad.bottomRight),
            bottomLeft: move(quad.bottomLeft)
        )
    }

    // MARK: - Non-board images (already "rectified": the whole frame is the candidate)

    static func fullFrameQuad(_ image: GrayImage, margin: Double = 2) -> Quad {
        let w = Double(image.width)
        let h = Double(image.height)
        return Quad(
            topLeft: CGPoint(x: margin, y: margin),
            topRight: CGPoint(x: w - margin, y: margin),
            bottomRight: CGPoint(x: w - margin, y: h - margin),
            bottomLeft: CGPoint(x: margin, y: h - margin)
        )
    }

    static func make(size: Int = 512, _ value: (_ x: Int, _ y: Int) -> UInt8) -> GrayImage {
        var pixels = [UInt8](repeating: 0, count: size * size)
        for y in 0..<size {
            for x in 0..<size { pixels[y * size + x] = value(x, y) }
        }
        return GrayImage(width: size, height: size, pixels: pixels)
    }

    static func uniform(_ tone: UInt8 = 128) -> GrayImage { make { _, _ in tone } }

    static func horizontalGradient() -> GrayImage { make { x, _ in UInt8(x * 255 / 511) } }

    static func verticalStripes(count: Int = 8) -> GrayImage {
        make { x, _ in (x * count / 512) % 2 == 0 ? 60 : 200 }
    }

    static func noise(seed: UInt64 = 3) -> GrayImage {
        var rng = SeededRNG(seed: seed)
        return make { _, _ in UInt8.random(in: 0...255, using: &rng) }
    }

    /// Checker grid with `columns` x `rows` cells filling the frame.
    static func checker(
        columns: Int, rows: Int, light: UInt8 = 200, dark: UInt8 = 70, size: Int = 512
    ) -> GrayImage {
        make(size: size) { x, y in
            ((x * columns / size) + (y * rows / size)) % 2 == 0 ? dark : light
        }
    }

    /// Light panes separated by dark mullions: 2 columns x 3 rows, with a frame.
    static func windowPanes() -> GrayImage {
        make { x, y in
            let mullion = abs(x - 256) < 8 || abs(y - 171) < 8 || abs(y - 342) < 8
            let frame = x < 12 || y < 12 || x > 499 || y > 499
            return mullion || frame ? 60 : 190
        }
    }

    /// Page of text lines: thin dark rules on white.
    static func textLines(lineCount: Int = 40) -> GrayImage {
        make { _, y in
            let cell = 512 / lineCount
            return (y % cell) < cell * 3 / 10 ? 40 : 220
        }
    }
}
