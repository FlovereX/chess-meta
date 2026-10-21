//
//  ChessBoardDetector.swift
//  CameraAccess
//
//  Created by Kieth Tyler Flores on 10/19/26.
//




import Foundation
import Vision

struct BoardPoint: Sendable {
    let x: Double
    let y: Double

    init(_ point: CGPoint) {
        x = Double(point.x)
        y = Double(point.y)
    }
}

struct BoardCorners: Sendable {
    let topLeft: BoardPoint
    let topRight: BoardPoint
    let bottomRight: BoardPoint
    let bottomLeft: BoardPoint
}

enum ChessBoardDetector {

    /// Legacy path: the single largest rectangle, or nil.
    static func detectCorners(
        in imageData: Data
    ) -> BoardCorners? {

        guard let rectangle = observations(in: imageData)?.max(by: {
            $0.boundingBox.width * $0.boundingBox.height <
            $1.boundingBox.width * $1.boundingBox.height
        }) else {
            return nil
        }

        return corners(of: rectangle)
    }

    /// All rectangle candidates, largest bounding box first, capped at `limit`.
    static func detectCandidates(
        in imageData: Data,
        limit: Int
    ) -> [BoardCorners] {

        guard limit > 0, let results = observations(in: imageData) else {
            return []
        }

        return results
            .sorted {
                $0.boundingBox.width * $0.boundingBox.height >
                $1.boundingBox.width * $1.boundingBox.height
            }
            .prefix(limit)
            .map { corners(of: $0) }
    }

    // MARK: - Shared setup

    private static func makeRequest() -> VNDetectRectanglesRequest {
        let request = VNDetectRectanglesRequest()

        request.maximumObservations = 10
        request.minimumConfidence = 0.5
        request.minimumAspectRatio = 0.4
        request.maximumAspectRatio = 1.0
        request.minimumSize = 0.15
        request.quadratureTolerance = 30

        return request
    }

    /// Runs the shared request; nil when Vision fails or returns no result list.
    private static func observations(
        in imageData: Data
    ) -> [VNRectangleObservation]? {
        let request = makeRequest()

        do {
            let handler = VNImageRequestHandler(
                data: imageData,
                options: [:]
            )

            try handler.perform([request])

            return request.results

        } catch {
            print("Chess Meta detection error: \(error)")
            return nil
        }
    }

    private static func corners(
        of rectangle: VNRectangleObservation
    ) -> BoardCorners {
        BoardCorners(
            topLeft: BoardPoint(rectangle.topLeft),
            topRight: BoardPoint(rectangle.topRight),
            bottomRight: BoardPoint(rectangle.bottomRight),
            bottomLeft: BoardPoint(rectangle.bottomLeft)
        )
    }
}
