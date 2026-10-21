//
//  HomographyTests.swift
//  CameraAccessTests
//

@testable import CameraAccess
import CoreGraphics
import XCTest

final class HomographyTests: XCTestCase {

    private let unitSquare = [
        CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1),
    ]

    private func assertPoint(
        _ p: CGPoint, _ x: Double, _ y: Double, accuracy: Double = 1e-6,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(Double(p.x), x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(Double(p.y), y, accuracy: accuracy, file: file, line: line)
    }

    func testIdentityMapping() throws {
        let pts = [CGPoint(x: 10, y: 20), CGPoint(x: 210, y: 25), CGPoint(x: 220, y: 180), CGPoint(x: 5, y: 190)]
        let h = try XCTUnwrap(Homography(from: pts, to: pts))
        assertPoint(h.map(CGPoint(x: 100, y: 100)), 100, 100)
        assertPoint(h.map(CGPoint(x: -30, y: 400)), -30, 400)
        assertPoint(Homography.identity.map(CGPoint(x: 3, y: 4)), 3, 4)
    }

    func testKnownScaleAndTranslateMapping() throws {
        // Unit square onto the axis-aligned rectangle (10,20)-(110,70).
        let dst = [CGPoint(x: 10, y: 20), CGPoint(x: 110, y: 20), CGPoint(x: 110, y: 70), CGPoint(x: 10, y: 70)]
        let h = try XCTUnwrap(Homography(from: unitSquare, to: dst))
        assertPoint(h.map(CGPoint(x: 0, y: 0)), 10, 20)
        assertPoint(h.map(CGPoint(x: 1, y: 1)), 110, 70)
        assertPoint(h.map(CGPoint(x: 0.5, y: 0.5)), 60, 45)
    }

    func testKnownPerspectiveMappingHitsAllCorners() throws {
        let quad = Quad(
            topLeft: CGPoint(x: 120, y: 80), topRight: CGPoint(x: 480, y: 100),
            bottomRight: CGPoint(x: 540, y: 400), bottomLeft: CGPoint(x: 60, y: 380)
        )
        let h = try XCTUnwrap(Homography.unitSquare(to: quad))
        assertPoint(h.map(CGPoint(x: 0, y: 0)), 120, 80)
        assertPoint(h.map(CGPoint(x: 1, y: 0)), 480, 100)
        assertPoint(h.map(CGPoint(x: 1, y: 1)), 540, 400)
        assertPoint(h.map(CGPoint(x: 0, y: 1)), 60, 380)
    }

    func testMapThenInverseRoundTrips() throws {
        let quad = Quad(
            topLeft: CGPoint(x: 120, y: 80), topRight: CGPoint(x: 480, y: 100),
            bottomRight: CGPoint(x: 540, y: 400), bottomLeft: CGPoint(x: 60, y: 380)
        )
        let h = try XCTUnwrap(Homography.unitSquare(to: quad))
        let inv = try XCTUnwrap(h.inverse)
        for p in [CGPoint(x: 0.1, y: 0.9), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.77, y: 0.03), CGPoint(x: 1.2, y: -0.3)] {
            let back = inv.map(h.map(p))
            assertPoint(back, Double(p.x), Double(p.y), accuracy: 1e-6)
        }
    }

    func testCollinearOrWrongCountInputReturnsNil() {
        let collinear = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 2), CGPoint(x: 0, y: 5)]
        XCTAssertNil(Homography(from: collinear, to: unitSquare))
        XCTAssertNil(Homography(from: unitSquare, to: collinear))
        let duplicate = [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
        XCTAssertNil(Homography(from: duplicate, to: unitSquare))
        XCTAssertNil(Homography(from: Array(unitSquare.prefix(3)), to: Array(unitSquare.prefix(3))))
    }

    func testQuadFromVisionNormalizedCornersFlipsY() {
        // Vision: normalized, origin bottom-left. Image 200 x 100 px.
        let corners = BoardCorners(
            topLeft: BoardPoint(CGPoint(x: 0.1, y: 0.9)),
            topRight: BoardPoint(CGPoint(x: 0.9, y: 0.8)),
            bottomRight: BoardPoint(CGPoint(x: 0.95, y: 0.1)),
            bottomLeft: BoardPoint(CGPoint(x: 0.05, y: 0.2))
        )
        let quad = Quad(corners, imageSize: CGSize(width: 200, height: 100))
        assertPoint(quad.topLeft, 20, 10)
        assertPoint(quad.topRight, 180, 20)
        assertPoint(quad.bottomRight, 190, 90)
        assertPoint(quad.bottomLeft, 10, 80)
    }

    func testQuadGeometryHelpers() {
        let square = SyntheticBoardImage.centeredQuad(size: 100, center: CGPoint(x: 50, y: 50))
        XCTAssertTrue(square.isConvex)
        XCTAssertEqual(square.area, 10_000, accuracy: 1e-9)
        for length in square.edgeLengths { XCTAssertEqual(length, 100, accuracy: 1e-9) }

        let bowtie = Quad(
            topLeft: CGPoint(x: 0, y: 0), topRight: CGPoint(x: 100, y: 100),
            bottomRight: CGPoint(x: 100, y: 0), bottomLeft: CGPoint(x: 0, y: 100)
        )
        XCTAssertFalse(bowtie.isConvex)
    }

    func testPlausibleBoardChecks() {
        let config = GridVerificationConfig.provisional
        let frame = CGSize(width: 640, height: 480)
        let good = SyntheticBoardImage.centeredQuad(size: 300, center: CGPoint(x: 320, y: 240))
        XCTAssertTrue(good.isPlausibleBoard(config: config, imageSize: frame))

        let tiny = SyntheticBoardImage.centeredQuad(size: 20, center: CGPoint(x: 320, y: 240))
        XCTAssertFalse(tiny.isPlausibleBoard(config: config, imageSize: frame))

        let sliver = Quad(
            topLeft: CGPoint(x: 100, y: 100), topRight: CGPoint(x: 600, y: 100),
            bottomRight: CGPoint(x: 600, y: 110), bottomLeft: CGPoint(x: 100, y: 110)
        )
        XCTAssertFalse(sliver.isPlausibleBoard(config: config, imageSize: frame))
    }
}
