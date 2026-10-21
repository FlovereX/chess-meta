//
//  ChessGameManager.swift
//  CameraAccess
//
//  Created by Kieth Tyler Flores on 10/19/26.
//


import Foundation
import Observation
import UIKit

enum BoardLockState {
    case searching
    case calibrating
    case candidateLocked
    case reacquiring

    var message: String {
        switch self {
        case .searching:
            return "Searching for board..."
        case .calibrating:
            return "Calibrating..."
        case .candidateLocked:
            return "Board candidate locked"
        case .reacquiring:
            return "Reacquiring board..."
        }
    }
}

@Observable
@MainActor
final class ChessGameManager {
    
    private(set) var isActive = false
    private(set) var sampledFrames = 0
    private(set) var rectangleFound = false
    private(set) var detectedCorners: BoardCorners?
    
    private(set) var boardLockState: BoardLockState = .searching
    private(set) var consistentDetections = 0
    private(set) var calibratedCorners: BoardCorners?
    
    private(set) var gridStatus: GridVerificationStatus = .notRun
    private(set) var lastGridScore: Double?
    private(set) var verifiedBoard: VerifiedBoard?
    private(set) var rectifiedPreview: UIImage?
    
    var config: GridVerificationConfig = ChessGameManager.initialConfig()
    

    @ObservationIgnored
    private var previousCandidate: BoardCorners?

    
    @ObservationIgnored
    private var lastSampleTime = Date.distantPast
    
    @ObservationIgnored
    private var isAnalyzing = false
    
    @ObservationIgnored
    private var analysisTask: Task<Void, Never>?
    
    @ObservationIgnored
    private var sessionID = UUID()
    
    @ObservationIgnored
    private(set) var latestSample: UIImage?
    
    nonisolated private static func initialConfig() -> GridVerificationConfig {
        #if DEBUG
        return GridVerificationConfig.fromUserDefaults()
        #else
        return .provisional
        #endif
    }
    
    private func resetGridState() {
        gridStatus = .notRun
        lastGridScore = nil
        verifiedBoard = nil
        rectifiedPreview = nil
    }
    
    private func apply(_ analysis: BoardAnalysis, gated: Bool) {
        // Gated: only a verified board's OUTER corners reach Board Lock.
        // Ungated: the legacy largest rectangle (candidates are sorted by size).
        let corners = gated
            ? analysis.best?.outerCorners
            : analysis.candidates.first?.corners
        updateBoardLock(with: corners)
        
        gridStatus = analysis.status
        lastGridScore = analysis.best?.result.score ?? analysis.topCandidate?.result.score
        verifiedBoard = analysis.best
        rectifiedPreview = analysis.rectifiedPreview?.toUIImage()
    }

    private func updateBoardLock(with corners: BoardCorners?) {
        guard let corners else {
            rectangleFound = false
            detectedCorners = nil
            previousCandidate = nil
            consistentDetections = 0

            boardLockState = calibratedCorners == nil
                ? .searching
                : .reacquiring
            return
        }

        rectangleFound = true
        detectedCorners = corners

        if let previousCandidate,
           cornersAreSimilar(previousCandidate, corners) {
            consistentDetections += 1
        } else {
            consistentDetections = 1
        }

        previousCandidate = corners

        if consistentDetections >= 3 {
            calibratedCorners = corners
            boardLockState = .candidateLocked
        } else {
            boardLockState = calibratedCorners == nil
                ? .calibrating
                : .reacquiring
        }
    }

    private func cornersAreSimilar(
        _ a: BoardCorners,
        _ b: BoardCorners
    ) -> Bool {
        let pairs: [(BoardPoint, BoardPoint)] = [
            (a.topLeft, b.topLeft),
            (a.topRight, b.topRight),
            (a.bottomRight, b.bottomRight),
            (a.bottomLeft, b.bottomLeft)
        ]

        return pairs.allSatisfy { pair in
            let dx = pair.0.x - pair.1.x
            let dy = pair.0.y - pair.1.y

            return dx * dx + dy * dy < 0.08 * 0.08
        }
    }

    
    func start() {
        detectedCorners = nil
        stop()
        
        #if DEBUG
        config = GridVerificationConfig.fromUserDefaults()
        #endif
        
        isActive = true
        sampledFrames = 0
        rectangleFound = false
        lastSampleTime = .distantPast
    }
    
    func stop() {
        detectedCorners = nil
        isActive = false
        rectangleFound = false
        latestSample = nil
        sessionID = UUID()
        
        analysisTask?.cancel()
        analysisTask = nil
        isAnalyzing = false
        
        boardLockState = .searching
        consistentDetections = 0
        calibratedCorners = nil
        previousCandidate = nil
        detectedCorners = nil
        resetGridState()

    }
    
    func receive(_ image: UIImage) {
        guard isActive, !isAnalyzing else { return }
        
        let now = Date()
        
        guard now.timeIntervalSince(lastSampleTime) >= 1.0
        else { return }
        
        lastSampleTime = now
        sampledFrames += 1
        latestSample = image
        
        guard let imageData = image.jpegData(
            compressionQuality: 0.75
        ) else {
            return
        }
        
        isAnalyzing = true
        let currentSession = sessionID
        let config = self.config
        
        analysisTask = Task {
            let analysis = await Task.detached(
                priority: .utility
            ) {
                BoardVerificationPipeline.analyze(
                    imageData: imageData,
                    config: config
                )
            }.value
            
            guard !Task.isCancelled,
                  isActive,
                  sessionID == currentSession
            else {
                return
            }
            
            apply(
                analysis,
                gated: config.gateBoardLockOnVerification
            )
            isAnalyzing = false
            
        }
    }
}
