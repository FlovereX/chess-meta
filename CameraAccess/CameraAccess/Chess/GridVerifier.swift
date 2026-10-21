//
//  GridVerifier.swift
//  CameraAccess
//
//  Classical, deterministic 8x8 checker-grid verification on a rectified grayscale
//  image. No Vision/Meta/UIKit imports; pure functions, safe in Task.detached.
//
//  All thresholds come from GridVerificationConfig, and all of them are provisional
//  (uncalibrated; no real glasses images were used).
//

import CoreGraphics
import Foundation

enum GridRejectionReason: String, Sendable, Codable, Equatable {
    case noRectangleCandidate
    case implausibleQuad
    case partiallyOutOfFrame
    case lowContrast
    case lowEdgeAlignment
    case texturedBorder
    case lowAlternation
    case lowScore

    /// Short text for the HUD / analysis sheet.
    var message: String {
        switch self {
        case .noRectangleCandidate: return "no rectangle found"
        case .implausibleQuad: return "implausible shape"
        case .partiallyOutOfFrame: return "board partly out of frame"
        case .lowContrast: return "low light/dark contrast"
        case .lowEdgeAlignment: return "no regular 8x8 grid lines"
        case .texturedBorder: return "textured border (not an 8x8 grid)"
        case .lowAlternation: return "squares don't alternate"
        case .lowScore: return "combined score too low"
        }
    }
}

struct GridComponents: Sendable, Equatable {
    /// Fraction of the 49 inner vertices with the expected alternating saddle, 0...1.
    var alternation: Double
    /// Periodic grid-line alignment (worst of the two axes), 0...1.
    var edgeAlignment: Double
    /// |median(light) - median(dark)| / 255.
    var contrast: Double

    static let zero = GridComponents(alternation: 0, edgeAlignment: 0, contrast: 0)
}

struct GridVerificationResult: Sendable {
    /// Combined score, 0...1.
    var score: Double
    var accepted: Bool
    var components: GridComponents
    /// Estimated wooden border, as fractions of the rectified (outer quad) size.
    var borderInsets: BorderInsets
    /// Either [r0, r180] or [r90, r270]. 0 vs 180 is NOT resolved: checker parity
    /// cannot tell them apart; that needs piece colours (a later milestone).
    var orientationCandidates: [BoardRotation]
    var rejection: GridRejectionReason?

    static func rejected(_ reason: GridRejectionReason) -> GridVerificationResult {
        GridVerificationResult(
            score: 0,
            accepted: false,
            components: .zero,
            borderInsets: .zero,
            orientationCandidates: [],
            rejection: reason
        )
    }
}

enum GridVerifier {

    /// Plausibility check + rectification + scoring for one candidate quad (pixel,
    /// top-left-origin space of `image`).
    static func verify(
        candidate: Quad,
        in image: GrayImage,
        config: GridVerificationConfig
    ) -> GridVerificationResult {
        let size = CGSize(width: image.width, height: image.height)
        guard candidate.isPlausibleBoard(config: config, imageSize: size),
              let rectified = BoardRectifier.rectify(image, quad: candidate, outputSize: config.rectifiedSize)
        else {
            return .rejected(.implausibleQuad)
        }
        return verify(rectified: rectified.image, visibleFraction: rectified.visibleFraction, config: config)
    }

    /// Scores an image already rectified from the candidate quad.
    static func verify(
        rectified image: GrayImage,
        visibleFraction: Double,
        config: GridVerificationConfig
    ) -> GridVerificationResult {
        guard visibleFraction >= config.minVisibleFraction else {
            return .rejected(.partiallyOutOfFrame)
        }
        guard image.width >= 64, image.height >= 64, image.pixels.count == image.width * image.height else {
            return .rejected(.implausibleQuad)
        }

        // (b) Playing-area search from 1D gradient projection profiles.
        let profiles = gradientProfiles(of: image)
        let xFit = fitAxis(profile: profiles.x, config: config)
        let yFit = fitAxis(profile: profiles.y, config: config)
        let insets = BorderInsets(left: xFit.start, top: yFit.start, right: xFit.end, bottom: yFit.end)
        let edgeAlignment = min(xFit.alignment, yFit.alignment)

        // (c) Checker alternation on the central patch of each of the 64 squares.
        let squares = squareMeans(of: image, insets: insets, config: config)
        let parityMedians = [
            median(squares.indices.filter { parity(ofSquare: $0) == 0 }.map { squares[$0] }),
            median(squares.indices.filter { parity(ofSquare: $0) == 1 }.map { squares[$0] }),
        ]
        let contrast = abs(parityMedians[0] - parityMedians[1]) / 255
        let alternation = alternationScore(squares: squares, config: config)

        // (e) Orientation from parity. Square index = row * 8 + col with row 0 at the
        // image top, so the bottom-left square has row 7, col 0 => parity 1. With a1
        // dark, a1 (r0) needs that square dark; a quarter turn puts a light square
        // there. 0 vs 180 stays unresolved (point-symmetric board).
        let darkParity = parityMedians[0] < parityMedians[1] ? 0 : 1
        let candidates: [BoardRotation] = darkParity == 1 ? [.r0, .r180] : [.r90, .r270]

        // (d) Combine.
        let weightSum = max(config.weightAlternation + config.weightEdgeAlignment + config.weightContrast, 1e-9)
        let contrastComponent = min(1, contrast / max(config.contrastSaturation, 1e-9))
        let score = (config.weightAlternation * alternation
            + config.weightEdgeAlignment * edgeAlignment
            + config.weightContrast * contrastComponent) / weightSum

        let smoothing = max(1, Int((0.25 * config.insetSearchStep * Double(image.width)).rounded()))
        let borderTexture = borderTextureRatio(
            of: image,
            insets: insets,
            contrast255: abs(parityMedians[0] - parityMedians[1]),
            smoothing: smoothing
        )

        var rejection: GridRejectionReason?
        if contrast < config.minContrast {
            rejection = .lowContrast
        } else if edgeAlignment < config.minEdgeAlignmentScore {
            rejection = .lowEdgeAlignment
        } else if borderTexture > config.maxBorderTextureRatio {
            rejection = .texturedBorder
        } else if alternation < config.minAlternationScore {
            rejection = .lowAlternation
        } else if score < config.minAcceptScore {
            rejection = .lowScore
        }

        return GridVerificationResult(
            score: score,
            accepted: rejection == nil,
            components: GridComponents(alternation: alternation, edgeAlignment: edgeAlignment, contrast: contrast),
            borderInsets: insets,
            orientationCandidates: candidates,
            rejection: rejection
        )
    }

    // MARK: - Profiles and playing-area search

    private struct AxisFit {
        var start: Double
        var end: Double
        var alignment: Double
    }

    /// Mean absolute central-difference gradient per column (x) and per row (y).
    private static func gradientProfiles(of image: GrayImage) -> (x: [Double], y: [Double]) {
        let w = image.width
        let h = image.height
        var px = [Double](repeating: 0, count: w)
        var py = [Double](repeating: 0, count: h)
        image.pixels.withUnsafeBufferPointer { p in
            for y in 0..<h {
                let up = max(y - 1, 0) * w
                let down = min(y + 1, h - 1) * w
                let row = y * w
                for x in 0..<w {
                    let l = max(x - 1, 0)
                    let r = min(x + 1, w - 1)
                    px[x] += abs(Double(p[row + r]) - Double(p[row + l]))
                    py[y] += abs(Double(p[down + x]) - Double(p[up + x]))
                }
            }
        }
        for x in 0..<w { px[x] /= Double(h) }
        for y in 0..<h { py[y] /= Double(w) }
        return (px, py)
    }

    private static func boxSmooth(_ a: [Double], halfWidth: Int) -> [Double] {
        let n = a.count
        var prefix = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + a[i] }
        return (0..<n).map { i in
            let lo = max(0, i - halfWidth)
            let hi = min(n - 1, i + halfWidth)
            return (prefix[hi + 1] - prefix[lo]) / Double(hi - lo + 1)
        }
    }

    /// Linear interpolation of a profile at a line position given in continuous pixel
    /// coordinates (pixel i spans [i, i+1], so its centre is i + 0.5).
    private static func sample(_ a: [Double], at position: Double) -> Double {
        let idx = min(max(position - 0.5, 0), Double(a.count - 1))
        let i0 = min(Int(idx), a.count - 2)
        let f = idx - Double(i0)
        return a[i0] * (1 - f) + a[i0 + 1] * f
    }

    /// Edge energy at the 9 predicted grid lines and at the 8 midpoints between them.
    private static func lineSamples(
        _ profile: [Double], start: Double, end: Double
    ) -> (lines: [Double], mids: [Double]) {
        let n = Double(profile.count)
        let lo = start * n
        let step = (n - end * n - lo) / 8
        let lines = (0...8).map { sample(profile, at: lo + Double($0) * step) }
        let mids = (0..<8).map { sample(profile, at: lo + (Double($0) + 0.5) * step) }
        return (lines, mids)
    }

    private static func mean(_ a: [Double]) -> Double {
        a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count)
    }

    /// Picks (insetStart, insetEnd) maximising mean(profile at 9 lines) - mean(profile
    /// at 8 midpoints): a coarse search at `insetSearchStep`, then a finer one (a
    /// quarter step) around the winner.
    private static func fitAxis(profile raw: [Double], config: GridVerificationConfig) -> AxisFit {
        let step = max(config.insetSearchStep, 1e-4)
        let halfWidth = max(1, Int((0.25 * step * Double(raw.count)).rounded()))
        let profile = boxSmooth(raw, halfWidth: halfWidth)

        func rawScore(_ s: Double, _ e: Double) -> Double {
            let samples = lineSamples(profile, start: s, end: e)
            return mean(samples.lines) - mean(samples.mids)
        }

        func search(starts: [Double], ends: [Double]) -> (s: Double, e: Double) {
            var best = (s: starts[0], e: ends[0])
            var bestValue = -Double.infinity
            for s in starts {
                for e in ends {
                    let v = rawScore(s, e)
                    if v > bestValue + 1e-12 {
                        bestValue = v
                        best = (s, e)
                    }
                }
            }
            return best
        }

        let count = Int((config.maxBorderFraction / step).rounded(.down))
        let coarse = (0...max(count, 0)).map { Double($0) * step }
        let first = search(starts: coarse, ends: coarse)

        let fineStep = step / 4
        func neighbourhood(_ centre: Double) -> [Double] {
            var values: [Double] = []
            var v = max(0, centre - step)
            let upper = min(config.maxBorderFraction, centre + step)
            while v <= upper + 1e-12 {
                values.append(v)
                v += fineStep
            }
            return values.isEmpty ? [centre] : values
        }
        let best = search(starts: neighbourhood(first.s), ends: neighbourhood(first.e))

        let samples = lineSamples(profile, start: best.s, end: best.e)
        let meanLines = mean(samples.lines)
        let meanMids = mean(samples.mids)
        let ratio = max(0, (meanLines - meanMids) / (meanLines + 1e-9))
        let interior = Array(samples.lines[1...7])
        let strongest = interior.max() ?? 0
        let hits = interior.filter { $0 >= config.lineHitRatio * strongest }.count
        let coverage = Double(hits) / 7
        return AxisFit(start: best.s, end: best.e, alignment: ratio * coverage)
    }

    // MARK: - Squares, contrast, alternation

    /// Row-major (row 0 at the image top) square index -> checker parity.
    private static func parity(ofSquare index: Int) -> Int {
        (index / 8 + index % 8) % 2
    }

    /// Mean gray level of the central patch of each of the 64 squares (row-major,
    /// row 0 at the top), via an integral image.
    private static func squareMeans(
        of image: GrayImage, insets: BorderInsets, config: GridVerificationConfig
    ) -> [Double] {
        let w = image.width
        let h = image.height
        var integral = [Double](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var rowSum = 0.0
            for x in 0..<w {
                rowSum += Double(image.pixels[y * w + x])
                integral[(y + 1) * (w + 1) + x + 1] = integral[y * (w + 1) + x + 1] + rowSum
            }
        }
        func boxMean(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Double {
            let a = integral[y0 * (w + 1) + x0]
            let b = integral[y0 * (w + 1) + x1]
            let c = integral[y1 * (w + 1) + x0]
            let d = integral[y1 * (w + 1) + x1]
            return (d - b - c + a) / Double(max((x1 - x0) * (y1 - y0), 1))
        }

        let left = insets.left * Double(w)
        let top = insets.top * Double(h)
        let squareW = (Double(w) - (insets.left + insets.right) * Double(w)) / 8
        let squareH = (Double(h) - (insets.top + insets.bottom) * Double(h)) / 8
        let half = min(max(config.squarePatchFraction, 0.05), 1) / 2

        var means: [Double] = []
        for row in 0..<8 {
            for col in 0..<8 {
                let cx = left + (Double(col) + 0.5) * squareW
                let cy = top + (Double(row) + 0.5) * squareH
                let x0 = min(max(Int((cx - half * squareW).rounded()), 0), w - 1)
                let y0 = min(max(Int((cy - half * squareH).rounded()), 0), h - 1)
                let x1 = min(max(Int((cx + half * squareW).rounded()), x0 + 1), w)
                let y1 = min(max(Int((cy + half * squareH).rounded()), y0 + 1), h)
                means.append(boxMean(x0, y0, x1, y1))
            }
        }
        return means
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// Saddle test on the 49 inner vertices: (TL + BR) - (TR + BL) must alternate in
    /// sign between neighbours with magnitude above `minInnerVertexContrast`. The best
    /// of the two global sign choices is used. A few squares disturbed by pieces only
    /// spoil the vertices touching them.
    private static func alternationScore(squares: [Double], config: GridVerificationConfig) -> Double {
        var best = 0
        for global in [1.0, -1.0] {
            var good = 0
            for j in 1...7 {
                for i in 1...7 {
                    let tl = squares[(j - 1) * 8 + (i - 1)]
                    let tr = squares[(j - 1) * 8 + i]
                    let bl = squares[j * 8 + (i - 1)]
                    let br = squares[j * 8 + i]
                    let saddle = ((tl + br) - (tr + bl)) / 255
                    let expected = global * ((i + j) % 2 == 0 ? 1.0 : -1.0)
                    if saddle * expected >= config.minInnerVertexContrast { good += 1 }
                }
            }
            best = max(best, good)
        }
        return Double(best) / 49
    }

    // MARK: - Border texture

    /// How much structure the estimated border strips contain, relative to the
    /// board's light/dark contrast. Each strip is averaged across its width (which
    /// suppresses noise and wood grain), smoothed, and its 5%-95% range along the
    /// strip is compared with `contrast255`. A plain frame is flat (~0); a ring of
    /// extra checker squares, as in a 9x9 board mistaken for 8x8 plus border, varies
    /// by about the full contrast (~1).
    private static func borderTextureRatio(
        of image: GrayImage, insets: BorderInsets, contrast255: Double, smoothing: Int
    ) -> Double {
        guard contrast255 > 1e-6 else { return 0 }
        let w = image.width
        let h = image.height
        let x0 = Int((insets.left * Double(w)).rounded())
        let x1 = w - Int((insets.right * Double(w)).rounded())
        let y0 = Int((insets.top * Double(h)).rounded())
        let y1 = h - Int((insets.bottom * Double(h)).rounded())
        let guardBand = 3
        let minStrip = 4

        // 5%-95% range of the width-averaged, smoothed profile of a strip.
        func range(_ xs: Range<Int>, _ ys: Range<Int>, alongY: Bool) -> Double {
            guard !xs.isEmpty, !ys.isEmpty else { return 0 }
            var profile: [Double] = []
            if alongY {
                profile = ys.map { y in
                    var sum = 0.0
                    for x in xs { sum += Double(image.pixels[y * w + x]) }
                    return sum / Double(xs.count)
                }
            } else {
                profile = xs.map { x in
                    var sum = 0.0
                    for y in ys { sum += Double(image.pixels[y * w + x]) }
                    return sum / Double(ys.count)
                }
            }
            let sorted = boxSmooth(profile, halfWidth: smoothing).sorted()
            let n = sorted.count
            return sorted[Int(0.95 * Double(n - 1))] - sorted[Int(0.05 * Double(n - 1))]
        }

        let innerX = (x0 + guardBand)..<(x1 - guardBand)
        let innerY = (y0 + guardBand)..<(y1 - guardBand)
        var strongest = 0.0
        // Left/right strips vary along y; top/bottom strips vary along x.
        if x0 >= minStrip + 2 * guardBand {
            strongest = max(strongest, range(guardBand..<(x0 - guardBand), innerY, alongY: true))
        }
        if w - x1 >= minStrip + 2 * guardBand {
            strongest = max(strongest, range((x1 + guardBand)..<(w - guardBand), innerY, alongY: true))
        }
        if y0 >= minStrip + 2 * guardBand {
            strongest = max(strongest, range(innerX, guardBand..<(y0 - guardBand), alongY: false))
        }
        if h - y1 >= minStrip + 2 * guardBand {
            strongest = max(strongest, range(innerX, (y1 + guardBand)..<(h - guardBand), alongY: false))
        }
        return strongest / contrast255
    }
}
