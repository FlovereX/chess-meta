# M1 — Grid verification (geometry core, rectification, verification, Board Lock gating)

> **Status: written, not compiled, not run.** This milestone was authored in an environment
> without macOS/Xcode/Swift. Nothing here has been built, unit-tested, or run on a device,
> and **nothing has been verified on physical Ray-Ban Meta glasses.** All thresholds are
> provisional placeholders.

## Files

| File | Change | Why |
|---|---|---|
| `CameraAccess/Chess/Homography.swift` | new | `Quad` (+ Vision→pixel conversion) and `Homography` (4-point DLT, Gaussian elimination with partial pivoting). |
| `CameraAccess/Chess/BoardGeometry.swift` | new | Board coordinate system (a1 at (0,0), 8x8 units), `BorderInsets`, `BoardRotation`, orientation candidates. |
| `CameraAccess/Chess/GridVerificationConfig.swift` | new | Every tunable, `.provisional` defaults, DEBUG-only UserDefaults overrides. |
| `CameraAccess/Chess/BoardRectifier.swift` | new | `GrayImage`, deterministic CPU perspective warp (bilinear) with `visibleFraction`, playing-area crop, `toUIImage()`. |
| `CameraAccess/Chess/GridVerifier.swift` | new | Classical scoring: border search, edge alignment, saddle alternation, contrast, rejection reasons, orientation candidates. |
| `CameraAccess/Chess/BoardVerificationPipeline.swift` | new | `analyze(imageData:config:)`, `analyzeSnapshot(_:)`, `BoardAnalysis`/`VerifiedBoard`/`GridVerificationStatus`, ImageIO JPEG→gray decode. |
| `CameraAccess/ChessBoardDetector.swift` | changed | Added `detectCandidates(in:limit:)`; request setup shared in a private helper. `detectCorners(in:)` keeps its signature and behaviour. |
| `CameraAccess/ChessGameManager.swift` | changed | Runs the pipeline instead of `detectCorners`; feeds Board Lock the verified board's outer corners (or the legacy largest rectangle when gating is off); new observable grid state, reset in `stop()`. |
| `CameraAccess/Views/BoardVerificationViews.swift` | new | `GridStatusLine`, `RectifiedBoardView`, `BoardSnapshotSheet`. |
| `CameraAccess/Views/CameraView.swift` | changed | HUD grid line + 96 pt thumbnail; Analyze Board sheet replaced by `BoardSnapshotSheet`. |
| `CameraAccessTests/Chess/*.swift` (5 files) | new | `HomographyTests`, `BoardGeometryTests`, `BoardRectifierTests`, `GridVerifierTests`, helper `SyntheticBoardImage`. |
| `CameraAccess.xcodeproj/project.pbxproj` | changed | App target only: file references, a `Chess` group, and Sources build-phase entries for the 7 new app files (+36 lines, additions only). The test target uses a file-system-synchronized group, so the new test files need no entries. Package references, signing, bundle ID, deployment target and `Info.plist` are untouched. |

## How the pieces fit

```
JPEG (ChessGameManager.receive, 1 fps)
  └─ BoardVerificationPipeline.analyze            (Task.detached)
       ├─ decodeGray (ImageIO, EXIF orientation applied)
       ├─ ChessBoardDetector.detectCandidates     (Vision, up to maxCandidatesToVerify, largest first)
       ├─ Quad(BoardCorners, imageSize:)          (normalized bottom-left → pixel top-left, once)
       ├─ GridVerifier.verify
       │    ├─ plausibility → BoardRectifier.rectify (512²) → visibleFraction check
       │    ├─ border + edge-alignment search from 1D gradient profiles
       │    ├─ alternation (49 inner-vertex saddles) + contrast on central square patches
       │    └─ score, accepted, rejection reason, orientation candidates
       └─ best ACCEPTED candidate → BoardGeometry + rectified playing-area preview
  └─ ChessGameManager.apply
       ├─ gateBoardLockOnVerification = true : updateBoardLock(best.outerCorners | nil)
       └─ false                              : updateBoardLock(largest Vision rectangle)  (legacy)
```

`BoardLockState`, `cornersAreSimilar` and the 3-consistent-detections rule are unchanged;
`calibratedCorners` still means the outer corners of the locked candidate. The
`sessionID` / `Task.isCancelled` / `isAnalyzing` guards are intact.

Notes on the algorithm:

- **Border search.** Per axis, hypotheses `(insetStart, insetEnd)` in `[0, maxBorderFraction]` are scored by
  mean(edge profile at the 9 predicted lines) − mean(at the 8 midpoints); a quarter-step refinement follows
  the coarse search. Because an 8x8 window cut out of a 9x9 checker also aligns, a **border-texture check**
  rejects candidates whose "border" strips vary by more than `maxBorderTextureRatio` of the board contrast.
- **Insets only grow.** Insets are ≥ 0, so a Vision quad that cuts *into* the playing area is not corrected.
- **Orientation.** With a1 dark, parity separates {0°, 180°} from {90°, 270°}. **0° vs 180° is unresolved**
  until piece colours exist (later milestone); `orientationCandidates` always has two entries.
- **Pieces.** Squares are sampled on their central 50 %. Large piece bases that cover most of that patch flip
  square values and cost alternation score; expect starting positions on a real board to score lower than on
  the synthetic blobs.

## Tunables (`GridVerificationConfig`)

All values in `.provisional` are **placeholders chosen against synthetic images** until real camera images exist.

| Property | Default | Meaning |
|---|---|---|
| `rectifiedSize` | 512 | Side of the rectified square image. |
| `maxBorderFraction` | 0.15 | Largest border per side searched (fraction of rectified size). |
| `insetSearchStep` | 0.0125 | Coarse inset search step (refined at ¼ step). |
| `minVisibleFraction` | 0.97 | Below this, rejected as `partiallyOutOfFrame`. |
| `minAlternationScore` | 0.70 | Min fraction of the 49 inner vertices with the expected alternating saddle. |
| `minEdgeAlignmentScore` | 0.50 | Min periodic grid-line alignment (worst axis). |
| `minContrast` | 0.12 | Min \|median(light) − median(dark)\| / 255. |
| `contrastSaturation` | 0.30 | Contrast at which the contrast component reaches 1.0. |
| `minAcceptScore` | 0.60 | Min combined score. |
| `weightAlternation` / `weightEdgeAlignment` / `weightContrast` | 0.5 / 0.3 / 0.2 | Component weights (normalised). |
| `minInnerVertexContrast` | 0.08 | Min \|saddle\|/255 for a vertex to count. |
| `squarePatchFraction` | 0.5 | Fraction of each square (per side) sampled around its centre. |
| `lineHitRatio` | 0.40 | An interior line "hits" at this fraction of the strongest line. |
| `maxBorderTextureRatio` | 0.35 | Max border-strip variation relative to board contrast. |
| `maxCandidatesToVerify` | 4 | Vision rectangles verified per frame. |
| `minQuadAreaFraction` | 0.02 | Min quad area as a fraction of the frame. |
| `maxEdgeLengthRatio` | 3.0 | Max longest/shortest quad edge. |
| `gateBoardLockOnVerification` | true | Gate Board Lock on verification (false = legacy largest rectangle). |

**DEBUG overrides.** In DEBUG builds, `GridVerificationConfig.fromUserDefaults()` reads
`chessmeta.grid.<propertyName>` keys (e.g. `chessmeta.grid.minContrast`,
`chessmeta.grid.gateBoardLockOnVerification`). `ChessGameManager` re-reads them each time Start Game is tapped.
Set them from a debug hook or the launch arguments, e.g. add
`-chessmeta.grid.minContrast 0.08 -chessmeta.grid.gateBoardLockOnVerification NO` to the scheme's
Arguments Passed On Launch (iOS maps `-key value` launch arguments into UserDefaults).

## Testing in Xcode

1. Open `CameraAccess/CameraAccess.xcodeproj`.
2. Select the **CameraAccess** scheme and an iPhone simulator.
3. Press **⌘U** to run unit tests, or open the Test navigator → `CameraAccessTests` → run the Chess
   classes only (`HomographyTests`, `BoardGeometryTests`, `BoardRectifierTests`, `GridVerifierTests`).
   The pre-existing `ViewModelIntegrationTests` need the bundled `plant.mp4` and MockDeviceKit, so run the
   Chess classes separately to tell failures apart. CLI equivalent:
   `xcodebuild test -project CameraAccess/CameraAccess.xcodeproj -scheme CameraAccess -destination 'platform=iOS Simulator,name=<installed iPhone>' -only-testing:CameraAccessTests/GridVerifierTests`
4. **On a phone with the glasses:** Start Session → Preview → **Start Game**, aim at a real board, and read the
   `Grid:` HUD line (`grid_status_label`) and the rectified thumbnail (`rectified_board_preview`).
5. Tap **Analyze Board** to see the full breakdown (score, alternation, edge alignment, contrast, border insets,
   rejection reason, labelled rectified board).

**Hardware checklist**

- [ ] Well-lit board, no border → `Grid: verified`, thumbnail shows an upright-looking board with the grid lines on the squares.
- [ ] Board with a wooden border → verified; border insets in Analyze Board roughly match the frame.
- [ ] A book, monitor, window, tiled wall or tray in view → `Grid: rejected`.
- [ ] Lean in until the board is partly out of frame → it must **not** lock (`partly out of frame`).
- [ ] Starting position and mid-game positions → still verified (watch the alternation score).
- [ ] Flip `gateBoardLockOnVerification` off (launch argument above) and compare Board Lock behaviour with the legacy path.

**What to record** for each trial: grid score, the three component scores, border insets, rejection reason,
lighting, board type, distance/angle. **Save the frames** (e.g. the Analyze Board snapshot, or the glasses
photo capture) into a labelled set (board / not-board, and why). That set replaces the provisional
thresholds; the `// TODO: real glasses frames` hook in `GridVerifierTests` is where to add them.

## Known limitations

- Thresholds are provisional and uncalibrated; the synthetic tests only show the logic is self-consistent.
- 0° vs 180° orientation is unresolved (needs piece colours).
- The board must be fully in frame; there is no tracking or reacquisition yet (M2). `.reacquiring` is a label only.
- Vision's rectangle detector may never propose the board in cluttered scenes; the verifier can only judge what it proposes.
- Performance is unmeasured (the warp is a plain CPU loop at 512², analysed at ~1 fps off the main actor).
- No real-image validation of any kind. It is also assumed (not confirmed) that Vision reads Data input in the same EXIF-oriented pixel grid ImageIO produces.
- Out of scope: Stockfish, audio, background operation, tracking/reacquisition, piece recognition.
