//
//  BoardVerificationViews.swift
//  CameraAccess
//
//  Small SwiftUI views for the grid-verification HUD line, the rectified board
//  thumbnail, and the Analyze Board sheet.
//

import SwiftUI
import UIKit

// MARK: - HUD status line

struct GridStatusLine: View {
  let status: GridVerificationStatus

  var body: some View {
    Text(text)
      .font(.footnote)
      .foregroundStyle(color)
      .multilineTextAlignment(.center)
      .accessibilityIdentifier("grid_status_label")
  }

  private var text: String {
    switch status {
    case .notRun:
      return "Grid: not checked"
    case .verified(let score):
      return "Grid: verified \(formatted(score))"
    case .rejected(let reason, let bestScore):
      return "Grid: rejected — \(reason.message) (\(formatted(bestScore)))"
    }
  }

  private var color: Color {
    switch status {
    case .notRun: return .secondary
    case .verified: return .green
    case .rejected: return .orange
    }
  }
}

private func formatted(_ value: Double) -> String {
  String(format: "%.2f", value)
}

// MARK: - Rectified board

/// The perspective-corrected playing area with a thin 8x8 line overlay, optionally
/// labelled a1...h8. Labels follow the first orientation candidate; 0°/180° is not
/// resolved yet, so they can be off by a half turn.
struct RectifiedBoardView: View {
  let image: UIImage
  var size: CGFloat = 96
  var rotation: BoardRotation = .r0
  var showLabels = false

  var body: some View {
    Image(uiImage: image)
      .resizable()
      .interpolation(.medium)
      .frame(width: size, height: size)
      .overlay(BoardGridOverlay(rotation: rotation, showLabels: showLabels))
      .clipShape(RoundedRectangle(cornerRadius: 4))
      .accessibilityIdentifier("rectified_board_preview")
  }
}

private struct BoardGridOverlay: View {
  let rotation: BoardRotation
  let showLabels: Bool

  var body: some View {
    Canvas { context, size in
      var lines = Path()
      for i in 0...8 {
        let x = size.width * CGFloat(i) / 8
        let y = size.height * CGFloat(i) / 8
        lines.move(to: CGPoint(x: x, y: 0))
        lines.addLine(to: CGPoint(x: x, y: size.height))
        lines.move(to: CGPoint(x: 0, y: y))
        lines.addLine(to: CGPoint(x: size.width, y: y))
      }
      context.stroke(lines, with: .color(.white.opacity(0.7)), lineWidth: 0.5)

      guard showLabels else { return }
      for row in 0..<8 {
        for col in 0..<8 {
          let (file, rank) = Self.square(col: col, row: row, rotation: rotation)
          let label = Text(BoardGeometry.algebraicName(file: file, rank: rank))
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(.yellow)
          context.draw(
            label,
            at: CGPoint(
              x: size.width * CGFloat(col) / 8 + 2,
              y: size.height * CGFloat(row) / 8 + 1
            ),
            anchor: .topLeading
          )
        }
      }
    }
  }

  /// File/rank (0-based) of the image cell (`col` from the left, `row` from the top)
  /// when the board appears rotated `rotation` quarter turns clockwise.
  private static func square(col: Int, row: Int, rotation: BoardRotation) -> (Int, Int) {
    switch rotation {
    case .r0: return (col, 7 - row)
    case .r90: return (row, col)
    case .r180: return (7 - col, row)
    case .r270: return (7 - row, 7 - col)
    }
  }
}

// MARK: - Verification breakdown

private struct GridVerificationDetails: View {
  let result: GridVerificationResult

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Score \(formatted(result.score))")
        .font(.headline)
      Text(
        "Alternation \(formatted(result.components.alternation)) · "
          + "Edge alignment \(formatted(result.components.edgeAlignment)) · "
          + "Contrast \(formatted(result.components.contrast))"
      )
      Text(
        "Border L \(formatted(result.borderInsets.left)) T \(formatted(result.borderInsets.top)) "
          + "R \(formatted(result.borderInsets.right)) B \(formatted(result.borderInsets.bottom))"
      )
      if !result.orientationCandidates.isEmpty {
        Text("Orientation: \(orientationText) (0°/180° unresolved)")
      }
      if let rejection = result.rejection {
        Text("Rejected: \(rejection.message)")
          .foregroundStyle(.orange)
      }
    }
    .font(.footnote.monospacedDigit())
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var orientationText: String {
    result.orientationCandidates
      .map { "\($0.rawValue * 90)°" }
      .joined(separator: " / ")
  }
}

// MARK: - Analyze Board sheet

struct BoardSnapshotSheet: View {
  let image: UIImage
  let config: GridVerificationConfig
  let onClose: () -> Void

  @State private var analysis: BoardAnalysis?

  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        Text("Chess Meta")
          .font(.largeTitle.bold())

        Image(uiImage: image)
          .resizable()
          .scaledToFit()
          .frame(maxWidth: .infinity)

        if let analysis {
          results(for: analysis)
        } else {
          ProgressView("Analyzing board…")
        }

        Button("Close", action: onClose)
          .buttonStyle(.borderedProminent)
      }
      .padding()
    }
    .task {
      // Encode on the main actor, then analyze off it.
      let data = BoardVerificationPipeline.jpegData(for: image)
      let config = self.config
      analysis = await Task.detached(priority: .userInitiated) {
        guard let data else { return BoardAnalysis.empty }
        return BoardVerificationPipeline.analyze(imageData: data, config: config)
      }.value
    }
  }

  @ViewBuilder
  private func results(for analysis: BoardAnalysis) -> some View {
    if let best = analysis.best {
      Label("Chessboard verified", systemImage: "checkmark.circle.fill")
        .foregroundStyle(.green)
      GridVerificationDetails(result: best.result)
      if let preview = analysis.rectifiedPreview?.toUIImage() {
        RectifiedBoardView(
          image: preview,
          size: 300,
          rotation: best.result.orientationCandidates.first ?? .r0,
          showLabels: true
        )
      }
    } else {
      Label("No verified chessboard in this frame", systemImage: "xmark.circle.fill")
        .foregroundStyle(.orange)
      if let top = analysis.topCandidate {
        GridVerificationDetails(result: top.result)
      } else {
        Text("Reason: \(GridRejectionReason.noRectangleCandidate.message)")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
  }
}
