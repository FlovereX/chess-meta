//
//  BoardGeometry.swift
//  CameraAccess
//
//  Board coordinate system. Playing area = unit grid [0,8]x[0,8] in "board space":
//  file a..h along x, rank 1..8 along y, a1 at (0,0). Image space is pixel,
//  top-left origin. No UIKit/SwiftUI imports.
//

import CoreGraphics
import Foundation

/// How many quarter turns clockwise the board appears rotated in the image relative
/// to the standard view (white at the bottom, a1 at the bottom-left of the quad).
///
/// Checker parity can distinguish 0°/180° from 90°/270° (with a1 dark, a quarter turn
/// swaps which colour sits in a given corner) but it can NOT tell 0° from 180°: the
/// board is point-symmetric. Resolving that needs piece colours in a later milestone.
/// M1 does not pretend to resolve it; see `BoardGeometry.orientationCandidates`.
enum BoardRotation: Int, Sendable, Codable, CaseIterable {
    case r0 = 0
    case r90
    case r180
    case r270

    func advanced(by quarterTurns: Int) -> BoardRotation {
        BoardRotation(rawValue: (((rawValue + quarterTurns) % 4) + 4) % 4) ?? .r0
    }
}

/// Border widths as fractions of the OUTER quad's rectified width (left/right) and
/// height (top/bottom).
struct BorderInsets: Sendable, Equatable, Codable {
    var left: Double
    var top: Double
    var right: Double
    var bottom: Double

    static let zero = BorderInsets(left: 0, top: 0, right: 0, bottom: 0)
}

struct BoardGeometry: Sendable {
    /// What Vision returned; may include a wooden border.
    let outerQuad: Quad
    let borderInsets: BorderInsets
    /// Rotations still consistent with the checker parity. Either [r0, r180] or
    /// [r90, r270]; 0 vs 180 is unresolved until piece colours exist.
    let orientationCandidates: [BoardRotation]
    /// The 8x8 playing area in image space (outer quad minus border).
    let playingAreaQuad: Quad
    let homographyBoardToImage: Homography
    let homographyImageToBoard: Homography

    /// Returns nil for degenerate quads or insets that leave no playing area.
    init?(outerQuad: Quad, borderInsets: BorderInsets, orientationCandidates: [BoardRotation]) {
        guard borderInsets.left >= 0, borderInsets.top >= 0,
              borderInsets.right >= 0, borderInsets.bottom >= 0,
              borderInsets.left + borderInsets.right < 1,
              borderInsets.top + borderInsets.bottom < 1,
              let unitToImage = Homography.unitSquare(to: outerQuad)
        else { return nil }

        let l = borderInsets.left
        let t = borderInsets.top
        let r = 1 - borderInsets.right
        let b = 1 - borderInsets.bottom
        let playing = Quad(
            topLeft: unitToImage.map(CGPoint(x: l, y: t)),
            topRight: unitToImage.map(CGPoint(x: r, y: t)),
            bottomRight: unitToImage.map(CGPoint(x: r, y: b)),
            bottomLeft: unitToImage.map(CGPoint(x: l, y: b))
        )
        // Board space has rank 8 (y = 8) at the top of the standard view.
        guard let boardToImage = Homography(
            from: [CGPoint(x: 0, y: 8), CGPoint(x: 8, y: 8), CGPoint(x: 8, y: 0), CGPoint(x: 0, y: 0)],
            to: playing.points
        ), let imageToBoard = boardToImage.inverse
        else { return nil }

        self.outerQuad = outerQuad
        self.borderInsets = borderInsets
        self.orientationCandidates = orientationCandidates
        self.playingAreaQuad = playing
        self.homographyBoardToImage = boardToImage
        self.homographyImageToBoard = imageToBoard
    }

    /// Reinterprets the same quad as if the board were rotated by `rotation` clockwise
    /// in the image: corners (and insets) are cyclically permuted so that, in the
    /// returned geometry, a1 is the bottom-left corner again. Candidates shift
    /// accordingly, so `rotated(r)` of a geometry with `r` among its candidates has
    /// `.r0` among its own.
    func rotated(_ rotation: BoardRotation) -> BoardGeometry {
        var quad = outerQuad
        var insets = borderInsets
        for _ in 0..<rotation.rawValue {
            quad = Quad(
                topLeft: quad.topRight,
                topRight: quad.bottomRight,
                bottomRight: quad.bottomLeft,
                bottomLeft: quad.topLeft
            )
            insets = BorderInsets(
                left: insets.top,
                top: insets.right,
                right: insets.bottom,
                bottom: insets.left
            )
        }
        let candidates = orientationCandidates.map { $0.advanced(by: -rotation.rawValue) }
        return BoardGeometry(outerQuad: quad, borderInsets: insets, orientationCandidates: candidates) ?? self
    }

    /// Centre of a square in image space. `file` 0...7 = a...h, `rank` 0...7 = 1...8.
    func squareCenter(file: Int, rank: Int) -> CGPoint {
        homographyBoardToImage.map(CGPoint(x: Double(file) + 0.5, y: Double(rank) + 0.5))
    }

    /// Corners of a square in image space (topLeft is the corner nearest rank+1/file).
    func squareQuad(file: Int, rank: Int) -> Quad {
        let f = Double(file)
        let r = Double(rank)
        return Quad(
            topLeft: homographyBoardToImage.map(CGPoint(x: f, y: r + 1)),
            topRight: homographyBoardToImage.map(CGPoint(x: f + 1, y: r + 1)),
            bottomRight: homographyBoardToImage.map(CGPoint(x: f + 1, y: r)),
            bottomLeft: homographyBoardToImage.map(CGPoint(x: f, y: r))
        )
    }

    /// The square containing an image point, or nil if outside the playing area.
    func squareIndex(at imagePoint: CGPoint) -> (file: Int, rank: Int)? {
        let p = homographyImageToBoard.map(imagePoint)
        guard p.x.isFinite, p.y.isFinite, p.x >= 0, p.y >= 0, p.x < 8, p.y < 8 else { return nil }
        return (file: Int(p.x), rank: Int(p.y))
    }

    /// "a1"..."h8" for 0-based file/rank.
    static func algebraicName(file: Int, rank: Int) -> String {
        let files = ["a", "b", "c", "d", "e", "f", "g", "h"]
        guard (0..<8).contains(file), (0..<8).contains(rank) else { return "?" }
        return files[file] + String(rank + 1)
    }

    /// a1 is dark, so a square is dark when (file + rank) is even (0-based).
    static func isDarkSquare(file: Int, rank: Int) -> Bool {
        (file + rank) % 2 == 0
    }
}
