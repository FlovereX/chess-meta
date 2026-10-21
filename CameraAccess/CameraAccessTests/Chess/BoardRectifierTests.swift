//
//  BoardRectifierTests.swift
//  CameraAccessTests
//

@testable import CameraAccess
import CoreGraphics
import XCTest

final class BoardRectifierTests: XCTestCase {

    private func meanAbsoluteError(_ a: GrayImage, _ b: GrayImage) -> Double {
        XCTAssertEqual(a.width, b.width)
        XCTAssertEqual(a.height, b.height)
        var sum = 0.0
        for i in 0..<min(a.pixels.count, b.pixels.count) {
            sum += abs(Double(a.pixels[i]) - Double(b.pixels[i]))
        }
        return sum / Double(a.pixels.count)
    }

    func testRectifyingWarpedBoardRecoversFlatBoard() throws {
        var board = SyntheticBoardImage()
        board.squareSize = 32
        let flat = board.flatBoard()
        let quad = SyntheticBoardImage.keystone(
            SyntheticBoardImage.centeredQuad(size: 320, center: CGPoint(x: 320, y: 240)),
            topShrink: 40
        )
        let frame = board.render(frameWidth: 640, frameHeight: 480, quad: quad)

        let result = try XCTUnwrap(BoardRectifier.rectify(frame, quad: quad, outputSize: flat.width))
        XCTAssertEqual(result.visibleFraction, 1, accuracy: 1e-9)
        // Two bilinear resamplings soften edges slightly; the bound is generous.
        XCTAssertLessThan(meanAbsoluteError(result.image, flat), 12)
    }

    func testOutputSizeIsHonoured() throws {
        let frame = SyntheticBoardImage().render(
            frameWidth: 640, frameHeight: 480,
            quad: SyntheticBoardImage.centeredQuad(size: 384, center: CGPoint(x: 320, y: 240))
        )
        let quad = SyntheticBoardImage.centeredQuad(size: 384, center: CGPoint(x: 320, y: 240))
        for size in [64, 200, 512] {
            let result = try XCTUnwrap(BoardRectifier.rectify(frame, quad: quad, outputSize: size))
            XCTAssertEqual(result.image.width, size)
            XCTAssertEqual(result.image.height, size)
            XCTAssertEqual(result.image.pixels.count, size * size)
        }
    }

    func testOutOfFrameQuadReportsReducedVisibleFraction() throws {
        let frame = SyntheticBoardImage.uniform(100)
        // Half of the quad hangs off the left edge of the 512 x 512 frame.
        let quad = SyntheticBoardImage.centeredQuad(size: 200, center: CGPoint(x: 0, y: 256))
        let result = try XCTUnwrap(BoardRectifier.rectify(frame, quad: quad, outputSize: 128))
        XCTAssertEqual(result.visibleFraction, 0.5, accuracy: 0.03)
        // Out-of-frame pixels carry the sentinel fill.
        XCTAssertEqual(result.image[2, 64], BoardRectifier.outOfBoundsFill)
    }

    func testKnownCornerRoundTripsThroughQuadAndRectify() throws {
        // 200 x 100 px image, black with a white block at the top-left of the board.
        var pixels = [UInt8](repeating: 0, count: 200 * 100)
        for y in 10..<30 {
            for x in 20..<40 { pixels[y * 200 + x] = 255 }
        }
        let image = GrayImage(width: 200, height: 100, pixels: pixels)

        // Vision-style normalized, bottom-left-origin corners of the quad (20,10)-(180,90).
        let corners = BoardCorners(
            topLeft: BoardPoint(CGPoint(x: 0.1, y: 0.9)),
            topRight: BoardPoint(CGPoint(x: 0.9, y: 0.9)),
            bottomRight: BoardPoint(CGPoint(x: 0.9, y: 0.1)),
            bottomLeft: BoardPoint(CGPoint(x: 0.1, y: 0.1))
        )
        let quad = Quad(corners, imageSize: CGSize(width: 200, height: 100))
        XCTAssertEqual(Double(quad.topLeft.x), 20, accuracy: 1e-9)
        XCTAssertEqual(Double(quad.topLeft.y), 10, accuracy: 1e-9)

        let result = try XCTUnwrap(BoardRectifier.rectify(image, quad: quad, outputSize: 64))
        XCTAssertGreaterThan(result.image[1, 1], 200)      // top-left of the board is bright
        XCTAssertLessThan(result.image[62, 1], 50)         // top-right
        XCTAssertLessThan(result.image[1, 62], 50)         // bottom-left
        XCTAssertLessThan(result.image[62, 62], 50)        // bottom-right
    }

    func testRectifiedCropUsesPlayingAreaOnly() throws {
        var board = SyntheticBoardImage()
        board.borderThickness = 24
        let outer = SyntheticBoardImage.centeredQuad(size: Double(board.outerSize), center: CGPoint(x: 320, y: 240))
        let frame = board.render(frameWidth: 640, frameHeight: 480, quad: outer)
        let geometry = try XCTUnwrap(BoardGeometry(
            outerQuad: outer,
            borderInsets: BorderInsets(
                left: board.borderFraction, top: board.borderFraction,
                right: board.borderFraction, bottom: board.borderFraction
            ),
            orientationCandidates: [.r0, .r180]
        ))
        let crop = try XCTUnwrap(BoardRectifier.rectifiedCrop(of: frame, geometry: geometry, outputSize: 256))
        XCTAssertEqual(crop.image.width, 256)

        var plain = board
        plain.borderThickness = 0
        plain.squareSize = 32
        XCTAssertLessThan(meanAbsoluteError(crop.image, plain.flatBoard()), 12)
    }
}
