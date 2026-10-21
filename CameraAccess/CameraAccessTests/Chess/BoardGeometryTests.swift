//
//  BoardGeometryTests.swift
//  CameraAccessTests
//

@testable import CameraAccess
import CoreGraphics
import XCTest

final class BoardGeometryTests: XCTestCase {

    /// 800 x 800 axis-aligned outer quad: each square is 100 px.
    private let outer = Quad(
        topLeft: CGPoint(x: 0, y: 0), topRight: CGPoint(x: 800, y: 0),
        bottomRight: CGPoint(x: 800, y: 800), bottomLeft: CGPoint(x: 0, y: 800)
    )

    private func makeGeometry(
        insets: BorderInsets = .zero,
        candidates: [BoardRotation] = [.r0, .r180]
    ) throws -> BoardGeometry {
        try XCTUnwrap(BoardGeometry(outerQuad: outer, borderInsets: insets, orientationCandidates: candidates))
    }

    private func assertPoint(
        _ p: CGPoint, _ x: Double, _ y: Double,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(Double(p.x), x, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(Double(p.y), y, accuracy: 1e-6, file: file, line: line)
    }

    func testSquareCenters() throws {
        let g = try makeGeometry()
        // a1 is bottom-left, h8 top-right (image y grows downward).
        assertPoint(g.squareCenter(file: 0, rank: 0), 50, 750)
        assertPoint(g.squareCenter(file: 7, rank: 0), 750, 750)
        assertPoint(g.squareCenter(file: 0, rank: 7), 50, 50)
        assertPoint(g.squareCenter(file: 7, rank: 7), 750, 50)
        assertPoint(g.squareCenter(file: 4, rank: 3), 450, 450)
    }

    func testSquareQuads() throws {
        let g = try makeGeometry()
        let a1 = g.squareQuad(file: 0, rank: 0)
        assertPoint(a1.topLeft, 0, 700)
        assertPoint(a1.topRight, 100, 700)
        assertPoint(a1.bottomRight, 100, 800)
        assertPoint(a1.bottomLeft, 0, 800)
        let h8 = g.squareQuad(file: 7, rank: 7)
        assertPoint(h8.topLeft, 700, 0)
        assertPoint(h8.bottomRight, 800, 100)
        let e4 = g.squareQuad(file: 4, rank: 3)
        assertPoint(e4.topLeft, 400, 400)
        assertPoint(e4.bottomRight, 500, 500)
    }

    func testSquareIndexInvertsSquareCenter() throws {
        let g = try makeGeometry(insets: BorderInsets(left: 0.05, top: 0.08, right: 0.04, bottom: 0.1))
        for file in 0..<8 {
            for rank in 0..<8 {
                let index = try XCTUnwrap(g.squareIndex(at: g.squareCenter(file: file, rank: rank)))
                XCTAssertEqual(index.file, file)
                XCTAssertEqual(index.rank, rank)
            }
        }
        XCTAssertNil(g.squareIndex(at: CGPoint(x: 1, y: 1)))   // inside the border
        XCTAssertNil(g.squareIndex(at: CGPoint(x: -10, y: 400)))
    }

    func testDarkSquareParityAndNames() {
        XCTAssertTrue(BoardGeometry.isDarkSquare(file: 0, rank: 0))    // a1 dark
        XCTAssertFalse(BoardGeometry.isDarkSquare(file: 7, rank: 0))   // h1 light
        XCTAssertFalse(BoardGeometry.isDarkSquare(file: 0, rank: 7))   // a8 light
        XCTAssertTrue(BoardGeometry.isDarkSquare(file: 7, rank: 7))    // h8 dark
        XCTAssertTrue(BoardGeometry.isDarkSquare(file: 4, rank: 3))    // e4 dark
        XCTAssertEqual(BoardGeometry.algebraicName(file: 0, rank: 0), "a1")
        XCTAssertEqual(BoardGeometry.algebraicName(file: 7, rank: 7), "h8")
        XCTAssertEqual(BoardGeometry.algebraicName(file: 4, rank: 3), "e4")
        XCTAssertEqual(BoardGeometry.algebraicName(file: 8, rank: 0), "?")
    }

    func testBorderInsetsShrinkPlayingArea() throws {
        let g = try makeGeometry(insets: BorderInsets(left: 0.1, top: 0.05, right: 0.1, bottom: 0.05))
        assertPoint(g.playingAreaQuad.topLeft, 80, 40)
        assertPoint(g.playingAreaQuad.topRight, 720, 40)
        assertPoint(g.playingAreaQuad.bottomRight, 720, 760)
        assertPoint(g.playingAreaQuad.bottomLeft, 80, 760)
        assertPoint(g.squareCenter(file: 0, rank: 0), 80 + 40, 760 - 45)
    }

    func testInvalidInsetsReturnNil() {
        XCTAssertNil(BoardGeometry(
            outerQuad: outer,
            borderInsets: BorderInsets(left: 0.6, top: 0, right: 0.4, bottom: 0),
            orientationCandidates: []
        ))
        XCTAssertNil(BoardGeometry(
            outerQuad: outer,
            borderInsets: BorderInsets(left: -0.1, top: 0, right: 0, bottom: 0),
            orientationCandidates: []
        ))
    }

    func testRotationPermutesCornersCyclically() throws {
        let quad = Quad(
            topLeft: CGPoint(x: 10, y: 10), topRight: CGPoint(x: 90, y: 20),
            bottomRight: CGPoint(x: 100, y: 100), bottomLeft: CGPoint(x: 0, y: 90)
        )
        let g = try XCTUnwrap(BoardGeometry(
            outerQuad: quad,
            borderInsets: BorderInsets(left: 0.01, top: 0.02, right: 0.03, bottom: 0.04),
            orientationCandidates: [.r90, .r270]
        ))
        XCTAssertEqual(g.rotated(.r0).outerQuad, quad)

        let r90 = g.rotated(.r90)
        XCTAssertEqual(r90.outerQuad.topLeft, quad.topRight)
        XCTAssertEqual(r90.outerQuad.topRight, quad.bottomRight)
        XCTAssertEqual(r90.outerQuad.bottomRight, quad.bottomLeft)
        XCTAssertEqual(r90.outerQuad.bottomLeft, quad.topLeft)
        XCTAssertEqual(r90.borderInsets, BorderInsets(left: 0.02, top: 0.03, right: 0.04, bottom: 0.01))

        XCTAssertEqual(g.rotated(.r180).outerQuad.topLeft, quad.bottomRight)
        XCTAssertEqual(g.rotated(.r270).outerQuad.topLeft, quad.bottomLeft)
        // Four quarter turns come back to the start.
        XCTAssertEqual(r90.rotated(.r90).rotated(.r90).rotated(.r90).outerQuad, quad)
    }

    func testOrientationCandidates() throws {
        // Parity separates {0, 180} from {90, 270} but cannot split 0 from 180.
        let upright = try makeGeometry(candidates: [.r0, .r180])
        XCTAssertEqual(Set(upright.orientationCandidates), [.r0, .r180])
        let sideways = try makeGeometry(candidates: [.r90, .r270])
        XCTAssertEqual(Set(sideways.orientationCandidates), [.r90, .r270])

        // Re-labelling by a candidate rotation makes r0 a candidate; the geometry
        // keeps two candidates (it never pretends to have picked one).
        let relabelled = sideways.rotated(.r90)
        XCTAssertTrue(relabelled.orientationCandidates.contains(.r0))
        XCTAssertEqual(relabelled.orientationCandidates.count, 2)
        XCTAssertEqual(Set(relabelled.orientationCandidates), [.r0, .r180])
        XCTAssertEqual(BoardRotation.r270.advanced(by: 1), .r0)
        XCTAssertEqual(BoardRotation.r0.advanced(by: -1), .r270)
    }
}
