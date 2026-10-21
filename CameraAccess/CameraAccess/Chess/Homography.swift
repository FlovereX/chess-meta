//
//  Homography.swift
//  CameraAccess
//
//  Pure geometry (Foundation + CoreGraphics only) so it unit-tests without glasses.
//

import CoreGraphics
import Foundation

/// A convex-or-not quadrilateral in a 2D space. Corner names describe the position
/// of the corner as seen in the image (top = smaller y in pixel space).
struct Quad: Sendable, Equatable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint

    /// Corners in clockwise order starting at the top-left.
    var points: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

    /// Edge lengths in the order top, right, bottom, left.
    var edgeLengths: [Double] {
        let p = points
        return (0..<4).map { i in
            let a = p[i]
            let b = p[(i + 1) % 4]
            return hypot(Double(b.x - a.x), Double(b.y - a.y))
        }
    }

    /// Absolute polygon area (shoelace formula).
    var area: Double {
        let p = points
        var sum = 0.0
        for i in 0..<4 {
            let a = p[i]
            let b = p[(i + 1) % 4]
            sum += Double(a.x) * Double(b.y) - Double(b.x) * Double(a.y)
        }
        return abs(sum) / 2
    }

    /// True when all four corners turn the same way (no zero-length turns).
    var isConvex: Bool {
        let p = points
        var sign = 0
        for i in 0..<4 {
            let a = p[i]
            let b = p[(i + 1) % 4]
            let c = p[(i + 2) % 4]
            let cross = Double(b.x - a.x) * Double(c.y - b.y) - Double(b.y - a.y) * Double(c.x - b.x)
            guard cross.isFinite, cross != 0 else { return false }
            let s = cross > 0 ? 1 : -1
            if sign == 0 {
                sign = s
            } else if s != sign {
                return false
            }
        }
        return true
    }

    /// Whether this quad is worth rectifying and scoring: convex, big enough, and
    /// without an extreme edge-length ratio. `imageSize` lets the minimum area be a
    /// fraction of the frame; without it only a degenerate (< 1 px²) area is rejected.
    func isPlausibleBoard(config: GridVerificationConfig, imageSize: CGSize? = nil) -> Bool {
        guard isConvex else { return false }
        let minArea: Double
        if let imageSize {
            minArea = config.minQuadAreaFraction * Double(imageSize.width) * Double(imageSize.height)
        } else {
            minArea = 1
        }
        guard area > minArea else { return false }
        let lengths = edgeLengths
        guard let shortest = lengths.min(), let longest = lengths.max(), shortest > 0 else { return false }
        return longest / shortest <= config.maxEdgeLengthRatio
    }
}

extension Quad {
    /// Converts Vision's NORMALIZED, BOTTOM-LEFT-origin corners into PIXEL,
    /// TOP-LEFT-origin coordinates: `x_px = x * width`, `y_px = (1 - y) * height`.
    /// This is the single place that flip happens.
    init(_ corners: BoardCorners, imageSize: CGSize) {
        let width = Double(imageSize.width)
        let height = Double(imageSize.height)
        func pixel(_ p: BoardPoint) -> CGPoint {
            CGPoint(x: p.x * width, y: (1 - p.y) * height)
        }
        self.init(
            topLeft: pixel(corners.topLeft),
            topRight: pixel(corners.topRight),
            bottomRight: pixel(corners.bottomRight),
            bottomLeft: pixel(corners.bottomLeft)
        )
    }
}

/// A 3x3 projective transform (row-major, Double).
struct Homography: Sendable, Equatable {
    let m: [Double]

    static let identity = Homography(matrix: [1, 0, 0, 0, 1, 0, 0, 0, 1])

    private static let pivotEpsilon = 1e-10
    private static let collinearEpsilon = 1e-6

    init(matrix: [Double]) {
        precondition(matrix.count == 9, "Homography needs 9 elements")
        m = matrix
    }

    /// Solves the standard 8-unknown DLT system from exactly 4 point pairs using
    /// Gaussian elimination with partial pivoting. Returns nil for degenerate input
    /// (wrong counts, any 3 collinear points, tiny pivot, non-finite result).
    init?(from src: [CGPoint], to dst: [CGPoint]) {
        guard src.count == 4, dst.count == 4,
              !Homography.hasCollinearTriple(src),
              !Homography.hasCollinearTriple(dst)
        else { return nil }

        var a = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
        for i in 0..<4 {
            let x = Double(src[i].x)
            let y = Double(src[i].y)
            let u = Double(dst[i].x)
            let v = Double(dst[i].y)
            a[2 * i] = [x, y, 1, 0, 0, 0, -u * x, -u * y, u]
            a[2 * i + 1] = [0, 0, 0, x, y, 1, -v * x, -v * y, v]
        }
        guard let h = Homography.solve(&a) else { return nil }
        m = h + [1]
    }

    /// Maps the unit square (0,0),(1,0),(1,1),(0,1) onto `quad`'s TL, TR, BR, BL.
    static func unitSquare(to quad: Quad) -> Homography? {
        Homography(
            from: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)],
            to: quad.points
        )
    }

    /// Applies the transform. When w is ~0 the point is at infinity and the result
    /// is (NaN, NaN); callers that index with the result must range-check in Double.
    func map(_ p: CGPoint) -> CGPoint {
        let x = Double(p.x)
        let y = Double(p.y)
        let w = m[6] * x + m[7] * y + m[8]
        guard abs(w) > 1e-12 else { return CGPoint(x: Double.nan, y: Double.nan) }
        return CGPoint(
            x: (m[0] * x + m[1] * y + m[2]) / w,
            y: (m[3] * x + m[4] * y + m[5]) / w
        )
    }

    var inverse: Homography? {
        let a = m[0], b = m[1], c = m[2]
        let d = m[3], e = m[4], f = m[5]
        let g = m[6], h = m[7], i = m[8]
        let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        guard det.isFinite, abs(det) > 1e-14 else { return nil }
        let inv = [
            (e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det,
            (f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det,
            (d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det,
        ]
        guard inv.allSatisfy({ $0.isFinite }) else { return nil }
        return Homography(matrix: inv)
    }

    // MARK: - Private

    private static func hasCollinearTriple(_ pts: [CGPoint]) -> Bool {
        for i in 0..<pts.count {
            for j in (i + 1)..<pts.count {
                for k in (j + 1)..<pts.count {
                    let abx = Double(pts[j].x - pts[i].x)
                    let aby = Double(pts[j].y - pts[i].y)
                    let acx = Double(pts[k].x - pts[i].x)
                    let acy = Double(pts[k].y - pts[i].y)
                    let lengths = hypot(abx, aby) * hypot(acx, acy)
                    guard lengths.isFinite, lengths > 0 else { return true }
                    // |sin(angle)| between the two edges.
                    if abs(abx * acy - aby * acx) / lengths < collinearEpsilon { return true }
                }
            }
        }
        return false
    }

    /// Gaussian elimination with partial pivoting on an 8x9 augmented matrix.
    private static func solve(_ a: inout [[Double]]) -> [Double]? {
        let n = 8
        for col in 0..<n {
            var pivot = col
            for r in (col + 1)..<n where abs(a[r][col]) > abs(a[pivot][col]) {
                pivot = r
            }
            guard abs(a[pivot][col]) > pivotEpsilon else { return nil }
            if pivot != col { a.swapAt(pivot, col) }
            for r in (col + 1)..<n {
                let factor = a[r][col] / a[col][col]
                if factor == 0 { continue }
                for c in col...n {
                    a[r][c] -= factor * a[col][c]
                }
            }
        }
        var x = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var sum = a[r][n]
            for c in (r + 1)..<n {
                sum -= a[r][c] * x[c]
            }
            x[r] = sum / a[r][r]
        }
        guard x.allSatisfy({ $0.isFinite }) else { return nil }
        return x
    }
}
