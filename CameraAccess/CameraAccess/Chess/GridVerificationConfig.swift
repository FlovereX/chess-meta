//
//  GridVerificationConfig.swift
//  CameraAccess
//
//  Every tunable threshold of the 8x8 grid verification. No UIKit/SwiftUI imports.
//

import Foundation

/// Tunables for `GridVerifier` and the pipeline around it.
///
/// IMPORTANT: every value in `provisional` is a PLACEHOLDER. They were chosen against
/// synthetic images only and have NOT been calibrated on real glasses frames. Replace
/// them once real camera images have been collected.
struct GridVerificationConfig: Sendable, Codable, Equatable {
    /// Side length in pixels of the square image the candidate quad is rectified to.
    var rectifiedSize: Int
    /// Largest border (as a fraction of the rectified width/height, per side) searched
    /// when the Vision quad includes a wooden frame around the playing area.
    var maxBorderFraction: Double
    /// Step of the coarse border-inset search, as a fraction of the rectified size.
    var insetSearchStep: Double
    /// Minimum fraction of rectified pixels that must come from inside the camera
    /// frame; below this the board is considered partially out of frame.
    var minVisibleFraction: Double
    /// Minimum checker-alternation score (fraction of the 49 inner vertices that show
    /// the expected alternating saddle), 0...1.
    var minAlternationScore: Double
    /// Minimum periodic edge-alignment score (grid lines vs. midpoints), 0...1.
    var minEdgeAlignmentScore: Double
    /// Minimum light/dark contrast, |median(light) - median(dark)| / 255.
    var minContrast: Double
    /// Contrast at (or above) which the contrast component saturates at 1.0.
    var contrastSaturation: Double
    /// Minimum combined score for acceptance, 0...1.
    var minAcceptScore: Double
    /// Component weights for the combined score (normalised by their sum).
    var weightAlternation: Double
    var weightEdgeAlignment: Double
    var weightContrast: Double
    /// Minimum |saddle| / 255 for an inner vertex to count as a valid checker corner.
    var minInnerVertexContrast: Double
    /// Fraction of each square (per side) sampled around its centre.
    var squarePatchFraction: Double
    /// An interior grid line "hits" when its edge energy is at least this fraction of
    /// the strongest interior line.
    var lineHitRatio: Double
    /// Maximum ratio of edge energy inside the estimated border strips to that inside
    /// the playing area. A real wooden frame is plain; a 9x9 checker whose outer ring
    /// of squares is mistaken for a border is not.
    var maxBorderTextureRatio: Double
    /// Maximum number of Vision rectangle candidates verified per frame.
    var maxCandidatesToVerify: Int
    /// Minimum quad area as a fraction of the frame area.
    var minQuadAreaFraction: Double
    /// Maximum longest/shortest edge ratio of the candidate quad.
    var maxEdgeLengthRatio: Double
    /// When true, Board Lock is fed only verified boards; when false it is fed the
    /// legacy largest rectangle so behaviour can be A/B compared on the glasses.
    var gateBoardLockOnVerification: Bool = true

    /// PLACEHOLDER defaults — uncalibrated, see the type documentation.
    static let provisional = GridVerificationConfig(
        rectifiedSize: 512,
        maxBorderFraction: 0.15,
        insetSearchStep: 0.0125,
        minVisibleFraction: 0.97,
        minAlternationScore: 0.70,
        minEdgeAlignmentScore: 0.50,
        minContrast: 0.12,
        contrastSaturation: 0.30,
        minAcceptScore: 0.60,
        weightAlternation: 0.50,
        weightEdgeAlignment: 0.30,
        weightContrast: 0.20,
        minInnerVertexContrast: 0.08,
        squarePatchFraction: 0.5,
        lineHitRatio: 0.40,
        maxBorderTextureRatio: 0.35,
        maxCandidatesToVerify: 4,
        minQuadAreaFraction: 0.02,
        maxEdgeLengthRatio: 3.0,
        gateBoardLockOnVerification: true
    )

    #if DEBUG
    /// UserDefaults key prefix for on-device threshold overrides (DEBUG builds only).
    /// Keys are `chessmeta.grid.<propertyName>`, e.g. `chessmeta.grid.minContrast`.
    static let userDefaultsPrefix = "chessmeta.grid."

    /// `provisional` with any overrides found in UserDefaults applied, so thresholds
    /// can be tuned on-device without rebuilding.
    static func fromUserDefaults() -> GridVerificationConfig {
        let defaults = UserDefaults.standard
        var config = provisional

        func override(_ name: String, _ value: inout Double) {
            let key = userDefaultsPrefix + name
            if defaults.object(forKey: key) != nil { value = defaults.double(forKey: key) }
        }
        func override(_ name: String, _ value: inout Int) {
            let key = userDefaultsPrefix + name
            if defaults.object(forKey: key) != nil { value = defaults.integer(forKey: key) }
        }
        func override(_ name: String, _ value: inout Bool) {
            let key = userDefaultsPrefix + name
            if defaults.object(forKey: key) != nil { value = defaults.bool(forKey: key) }
        }

        override("rectifiedSize", &config.rectifiedSize)
        override("maxBorderFraction", &config.maxBorderFraction)
        override("insetSearchStep", &config.insetSearchStep)
        override("minVisibleFraction", &config.minVisibleFraction)
        override("minAlternationScore", &config.minAlternationScore)
        override("minEdgeAlignmentScore", &config.minEdgeAlignmentScore)
        override("minContrast", &config.minContrast)
        override("contrastSaturation", &config.contrastSaturation)
        override("minAcceptScore", &config.minAcceptScore)
        override("weightAlternation", &config.weightAlternation)
        override("weightEdgeAlignment", &config.weightEdgeAlignment)
        override("weightContrast", &config.weightContrast)
        override("minInnerVertexContrast", &config.minInnerVertexContrast)
        override("squarePatchFraction", &config.squarePatchFraction)
        override("lineHitRatio", &config.lineHitRatio)
        override("maxBorderTextureRatio", &config.maxBorderTextureRatio)
        override("maxCandidatesToVerify", &config.maxCandidatesToVerify)
        override("minQuadAreaFraction", &config.minQuadAreaFraction)
        override("maxEdgeLengthRatio", &config.maxEdgeLengthRatio)
        override("gateBoardLockOnVerification", &config.gateBoardLockOnVerification)
        return config
    }
    #endif
}
