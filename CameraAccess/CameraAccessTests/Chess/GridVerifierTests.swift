//
//  GridVerifierTests.swift
//  CameraAccessTests
//
//  Table-driven: adding a real glasses frame later is one line in the fixtures hook.
//  All thresholds under test are PROVISIONAL (see GridVerificationConfig).
//

@testable import CameraAccess
import CoreGraphics
import XCTest

final class GridVerifierTests: XCTestCase {

    private struct Case {
        let name: String
        let image: GrayImage
        let quad: Quad
        /// Expected rejection for negatives where the reason is deterministic.
        var expectedRejection: GridRejectionReason?
        /// Expected orientation candidates for positives where parity is known.
        var expectedOrientation: Set<BoardRotation>?
    }

    private let frameWidth = 640
    private let frameHeight = 480
    private let center = CGPoint(x: 320, y: 240)

    // MARK: - Fixtures

    private func boardCase(
        _ name: String,
        configure: (inout SyntheticBoardImage) -> Void = { _ in },
        quadTransform: (Quad) -> Quad = { $0 },
        orientation: Set<BoardRotation>? = [.r0, .r180]
    ) -> Case {
        var board = SyntheticBoardImage()
        configure(&board)
        let flatQuad = SyntheticBoardImage.centeredQuad(size: Double(board.outerSize), center: center)
        let quad = quadTransform(flatQuad)
        let image = board.render(frameWidth: frameWidth, frameHeight: frameHeight, quad: quad)
        return Case(name: name, image: image, quad: quad, expectedRejection: nil, expectedOrientation: orientation)
    }

    private func positiveCases() -> [Case] {
        var cases: [Case] = [
            boardCase("flat board"),
            boardCase("wooden border 12px") { $0.borderThickness = 12 },
            boardCase("wooden border 24px") { $0.borderThickness = 24 },
            boardCase("wooden border 40px, dark wood") {
                $0.borderThickness = 40
                $0.borderTone = 90
            },
            boardCase("keystone perspective", quadTransform: { SyntheticBoardImage.keystone($0, topShrink: 50) }),
            boardCase("keystone + border") {
                $0.borderThickness = 24
            } quadTransform: {
                SyntheticBoardImage.keystone($0, topShrink: 40)
            },
            boardCase("12 degree in-plane rotation", quadTransform: { SyntheticBoardImage.rotated($0, degrees: 12) }),
            boardCase(
                "90 degree rotation",
                quadTransform: { SyntheticBoardImage.relabelled($0, quarterTurns: 1) },
                orientation: [.r90, .r270]
            ),
            boardCase("starting position piece blobs") { $0.pieces = true },
            boardCase("mild noise + blur") {
                $0.noiseSigma = 8
                $0.blurRadius = 1
            },
        ]

        // Low resolution: ~18 px per square, board ~144 px wide in a small frame.
        var small = SyntheticBoardImage()
        small.squareSize = 18
        small.blurRadius = 1
        let smallQuad = SyntheticBoardImage.centeredQuad(size: Double(small.outerSize), center: CGPoint(x: 160, y: 120))
        cases.append(Case(
            name: "low resolution 18px/square",
            image: small.render(frameWidth: 320, frameHeight: 240, quad: smallQuad),
            quad: smallQuad,
            expectedRejection: nil,
            expectedOrientation: [.r0, .r180]
        ))

        // TODO: real glasses frames — append `Case(name:image:quad:...)` built from files
        // captured on the device. Do not add synthetic stand-ins here.
        return cases
    }

    private func negativeCase(_ name: String, _ image: GrayImage, reason: GridRejectionReason? = nil) -> Case {
        Case(
            name: name,
            image: image,
            quad: SyntheticBoardImage.fullFrameQuad(image),
            expectedRejection: reason,
            expectedOrientation: nil
        )
    }

    private func negativeCases() -> [Case] {
        var partial = boardCase("partial board (half outside the frame)")
        partial = Case(
            name: partial.name,
            image: partial.image,
            // Shift the candidate so its centre sits on the left frame edge.
            quad: SyntheticBoardImage.translated(partial.quad, dx: -320, dy: 0),
            expectedRejection: .partiallyOutOfFrame,
            expectedOrientation: nil
        )
        var lowContrastBoard = SyntheticBoardImage()
        lowContrastBoard.light = 135
        lowContrastBoard.dark = 118
        let lowContrastQuad = SyntheticBoardImage.centeredQuad(size: 384, center: center)

        return [
            negativeCase("uniform gray", SyntheticBoardImage.uniform(), reason: .lowContrast),
            negativeCase("horizontal gradient", SyntheticBoardImage.horizontalGradient()),
            negativeCase("vertical stripes", SyntheticBoardImage.verticalStripes()),
            negativeCase("noise", SyntheticBoardImage.noise()),
            negativeCase("7x7 checker", SyntheticBoardImage.checker(columns: 7, rows: 7)),
            negativeCase("9x9 checker", SyntheticBoardImage.checker(columns: 9, rows: 9)),
            negativeCase("6x10 checker", SyntheticBoardImage.checker(columns: 6, rows: 10)),
            negativeCase("4x4 checker", SyntheticBoardImage.checker(columns: 4, rows: 4)),
            negativeCase("16x16 checker", SyntheticBoardImage.checker(columns: 16, rows: 16)),
            negativeCase("2x3 window panes", SyntheticBoardImage.windowPanes()),
            negativeCase("text-page horizontal lines", SyntheticBoardImage.textLines()),
            Case(
                name: "very low contrast 8x8",
                image: lowContrastBoard.render(frameWidth: frameWidth, frameHeight: frameHeight, quad: lowContrastQuad),
                quad: lowContrastQuad,
                expectedRejection: .lowContrast,
                expectedOrientation: nil
            ),
            partial,
        ]
    }

    // MARK: - Positives / negatives

    func testPositivesAreAccepted() {
        let config = GridVerificationConfig.provisional
        for c in positiveCases() {
            let result = GridVerifier.verify(candidate: c.quad, in: c.image, config: config)
            XCTAssertTrue(
                result.accepted,
                "\(c.name) should be accepted: \(describe(result))"
            )
            XCTAssertNil(result.rejection, c.name)
            XCTAssertGreaterThanOrEqual(result.score, config.minAcceptScore, c.name)
            if let expected = c.expectedOrientation {
                XCTAssertEqual(Set(result.orientationCandidates), expected, "\(c.name) orientation")
                XCTAssertEqual(result.orientationCandidates.count, 2, "\(c.name) keeps both candidates")
            }
        }
    }

    func testNegativesAreRejected() {
        let config = GridVerificationConfig.provisional
        for c in negativeCases() {
            let result = GridVerifier.verify(candidate: c.quad, in: c.image, config: config)
            XCTAssertFalse(result.accepted, "\(c.name) should be rejected: \(describe(result))")
            XCTAssertNotNil(result.rejection, c.name)
            if let expected = c.expectedRejection {
                XCTAssertEqual(result.rejection, expected, "\(c.name): \(describe(result))")
            }
        }
    }

    // MARK: - Border estimate

    func testBorderInsetEstimateWithinOneAndAHalfSteps() {
        let config = GridVerificationConfig.provisional
        let tolerance = 1.5 * config.insetSearchStep
        let thicknesses = [12, 24, 40]
        for thickness in thicknesses {
            for keystone in [false, true] {
                var board = SyntheticBoardImage()
                board.borderThickness = thickness
                var quad = SyntheticBoardImage.centeredQuad(size: Double(board.outerSize), center: center)
                if keystone { quad = SyntheticBoardImage.keystone(quad, topShrink: 40) }
                let image = board.render(frameWidth: frameWidth, frameHeight: frameHeight, quad: quad)
                let result = GridVerifier.verify(candidate: quad, in: image, config: config)
                let truth = board.borderFraction
                let name = "border \(thickness)px keystone=\(keystone)"
                XCTAssertTrue(result.accepted, "\(name): \(describe(result))")
                XCTAssertEqual(result.borderInsets.left, truth, accuracy: tolerance, name)
                XCTAssertEqual(result.borderInsets.right, truth, accuracy: tolerance, name)
                XCTAssertEqual(result.borderInsets.top, truth, accuracy: tolerance, name)
                XCTAssertEqual(result.borderInsets.bottom, truth, accuracy: tolerance, name)
            }
        }
    }

    // MARK: - Config

    func testTighteningMinAcceptScoreFlipsBorderlinePositive() {
        let c = boardCase("noisy positive") {
            $0.noiseSigma = 8
            $0.blurRadius = 1
        }
        let loose = GridVerifier.verify(candidate: c.quad, in: c.image, config: .provisional)
        XCTAssertTrue(loose.accepted, describe(loose))

        var strict = GridVerificationConfig.provisional
        strict.minAcceptScore = min(1, loose.score + 0.001)
        let tight = GridVerifier.verify(candidate: c.quad, in: c.image, config: strict)
        XCTAssertFalse(tight.accepted)
        XCTAssertEqual(tight.rejection, .lowScore)
    }

    func testConfigCodableRoundTrip() throws {
        var config = GridVerificationConfig.provisional
        config.minContrast = 0.2
        config.maxCandidatesToVerify = 7
        config.gateBoardLockOnVerification = false
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(GridVerificationConfig.self, from: data)
        XCTAssertEqual(decoded, config)
        XCTAssertEqual(decoded.rectifiedSize, 512)
    }

    // MARK: - Helpers

    private func describe(_ r: GridVerificationResult) -> String {
        String(
            format: "score %.3f alt %.3f edge %.3f contrast %.3f reason %@",
            r.score, r.components.alternation, r.components.edgeAlignment, r.components.contrast,
            r.rejection?.rawValue ?? "none"
        )
    }
}
