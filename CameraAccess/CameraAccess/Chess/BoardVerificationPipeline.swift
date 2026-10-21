//
//  BoardVerificationPipeline.swift
//  CameraAccess
//
//  detectCandidates -> Quad -> rectify -> GridVerifier -> best accepted candidate.
//  Pure functions over Sendable values, safe to run in Task.detached.
//

import CoreGraphics
import Foundation
import ImageIO
import UIKit

enum GridVerificationStatus: Sendable, Equatable {
    case notRun
    case verified(score: Double)
    case rejected(reason: GridRejectionReason, bestScore: Double)
}

struct BoardCandidateResult: Sendable {
    let corners: BoardCorners
    let result: GridVerificationResult
}

struct VerifiedBoard: Sendable {
    /// Outer corners as Vision returned them (possibly including a wooden border),
    /// in Vision's normalized, bottom-left-origin space.
    let outerCorners: BoardCorners
    let geometry: BoardGeometry
    let result: GridVerificationResult
}

struct BoardAnalysis: Sendable {
    /// Every verified candidate, largest Vision bounding box first (so `first` is the
    /// legacy "largest rectangle").
    let candidates: [BoardCandidateResult]
    /// Highest-scoring ACCEPTED candidate, if any.
    let best: VerifiedBoard?
    /// Playing area of `best`, perspective-corrected.
    let rectifiedPreview: GrayImage?

    static let empty = BoardAnalysis(candidates: [], best: nil, rectifiedPreview: nil)

    /// The highest-scoring candidate regardless of acceptance (for rejection reporting).
    var topCandidate: BoardCandidateResult? {
        candidates.max { $0.result.score < $1.result.score }
    }

    var status: GridVerificationStatus {
        if let best {
            return .verified(score: best.result.score)
        }
        guard let top = topCandidate else {
            return .rejected(reason: .noRectangleCandidate, bestScore: 0)
        }
        return .rejected(reason: top.result.rejection ?? .lowScore, bestScore: top.result.score)
    }
}

enum BoardVerificationPipeline {

    private static let jpegQuality: CGFloat = 0.75

    static func analyze(imageData: Data, config: GridVerificationConfig) -> BoardAnalysis {
        guard let gray = decodeGray(imageData) else { return .empty }

        let size = CGSize(width: gray.width, height: gray.height)
        let corners = ChessBoardDetector.detectCandidates(
            in: imageData,
            limit: config.maxCandidatesToVerify
        )

        var results: [BoardCandidateResult] = []
        var bestIndex: Int?
        for (index, candidate) in corners.enumerated() {
            let quad = Quad(candidate, imageSize: size)
            let result = GridVerifier.verify(candidate: quad, in: gray, config: config)
            results.append(BoardCandidateResult(corners: candidate, result: result))
            if result.accepted, bestIndex.map({ result.score > results[$0].result.score }) ?? true {
                bestIndex = index
            }
        }

        guard let bestIndex else {
            return BoardAnalysis(candidates: results, best: nil, rectifiedPreview: nil)
        }

        let winner = results[bestIndex]
        let quad = Quad(winner.corners, imageSize: size)
        guard let geometry = BoardGeometry(
            outerQuad: quad,
            borderInsets: winner.result.borderInsets,
            orientationCandidates: winner.result.orientationCandidates
        ) else {
            return BoardAnalysis(candidates: results, best: nil, rectifiedPreview: nil)
        }

        let preview = BoardRectifier.rectifiedCrop(
            of: gray,
            geometry: geometry,
            outputSize: config.rectifiedSize
        )?.image
        return BoardAnalysis(
            candidates: results,
            best: VerifiedBoard(outerCorners: winner.corners, geometry: geometry, result: winner.result),
            rectifiedPreview: preview
        )
    }

    /// JPEG-encodes a snapshot exactly like ChessGameManager.receive does.
    static func jpegData(for image: UIImage) -> Data? {
        image.jpegData(compressionQuality: jpegQuality)
    }

    /// For the Analyze Board sheet. Encodes through JPEG so the pixels match the live path.
    static func analyzeSnapshot(
        _ image: UIImage,
        config: GridVerificationConfig = .provisional
    ) -> BoardAnalysis {
        guard let data = jpegData(for: image) else { return .empty }
        return analyze(imageData: data, config: config)
    }

    /// Decodes JPEG data into gray pixels with the EXIF orientation applied, i.e. the
    /// oriented pixel grid Vision reports its normalized coordinates against
    /// (assumption: Vision honours the same orientation metadata for Data input).
    static func decodeGray(_ data: Data) -> GrayImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return GrayImage(cgImage: cgImage)
    }
}
