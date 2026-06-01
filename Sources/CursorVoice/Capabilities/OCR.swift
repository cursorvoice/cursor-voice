import Foundation
import CoreGraphics
import Vision

/// Wraps Apple's Vision framework to do live OCR on a screenshot.
/// Returns text + bounding boxes in image-pixel coordinates with a
/// TOP-LEFT origin — matching the convention the rest of the app uses
/// (and what `InputSynth.click(imagePx:)` expects directly).
enum OCR {
    struct Match {
        let text: String
        /// Image-pixel coordinates, top-left origin, same scale as the screenshot.
        let bbox: CGRect
        /// Vision's per-candidate confidence, 0…1.
        let confidence: Float
    }

    enum Level { case fast, accurate }

    /// Recognise text in a CGImage. The Vision request runs on a background
    /// thread; the function suspends until results are available.
    static func recognize(in cgImage: CGImage,
                          level: Level = .accurate,
                          maxResults: Int = 80) async -> [Match] {
        await withCheckedContinuation { (cont: CheckedContinuation<[Match], Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = (level == .accurate) ? .accurate : .fast
                request.usesLanguageCorrection = false

                do {
                    try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
                } catch {
                    NSLog("OCR: error \(error)")
                    cont.resume(returning: [])
                    return
                }

                let imageWidth  = CGFloat(cgImage.width)
                let imageHeight = CGFloat(cgImage.height)

                let matches: [Match] = (request.results ?? []).compactMap { obs in
                    guard let cand = obs.topCandidates(1).first else { return nil }
                    // Vision's boundingBox is normalized (0..1), origin BOTTOM-LEFT.
                    let nb = obs.boundingBox
                    let x = nb.origin.x * imageWidth
                    let y = (1 - nb.origin.y - nb.height) * imageHeight   // flip to top-left
                    let w = nb.width  * imageWidth
                    let h = nb.height * imageHeight
                    return Match(
                        text: cand.string,
                        bbox: CGRect(x: x, y: y, width: w, height: h),
                        confidence: cand.confidence
                    )
                }
                cont.resume(returning: Array(matches.prefix(maxResults)))
            }
        }
    }

    /// Filter `matches` to entries whose text contains `query` (case-insensitive).
    /// If `query` is nil/empty, returns the full list.
    static func filter(_ matches: [Match], query: String?) -> [Match] {
        guard let q = query?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty else {
            return matches
        }
        let lq = q.lowercased()
        return matches.filter { $0.text.lowercased().contains(lq) }
    }
}
