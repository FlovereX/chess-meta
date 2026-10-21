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

    static func detectCorners(
        in imageData: Data
    ) -> BoardCorners? {

        let request = VNDetectRectanglesRequest()

        request.maximumObservations = 10
        request.minimumConfidence = 0.5
        request.minimumAspectRatio = 0.4
        request.maximumAspectRatio = 1.0
        request.minimumSize = 0.15
        request.quadratureTolerance = 30

        do {
            let handler = VNImageRequestHandler(
                data: imageData,
                options: [:]
            )

            try handler.perform([request])

            guard let rectangle = request.results?.max(by: {
                $0.boundingBox.width * $0.boundingBox.height <
                $1.boundingBox.width * $1.boundingBox.height
            }) else {
                return nil
            }

            return BoardCorners(
                topLeft: BoardPoint(rectangle.topLeft),
                topRight: BoardPoint(rectangle.topRight),
                bottomRight: BoardPoint(rectangle.bottomRight),
                bottomLeft: BoardPoint(rectangle.bottomLeft)
            )

        } catch {
            print("Chess Meta detection error: \(error)")
            return nil
        }
    }
}
