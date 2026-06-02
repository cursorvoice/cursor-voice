import Foundation
import AppKit
import CoreGraphics

/// Set-of-Marks: draws numbered badges over candidate clickable regions on a
/// screenshot, so the model can pick a target by INDEX instead of guessing
/// pixel coordinates. This is the fallback when neither the Accessibility tree
/// (no labels) nor OCR (no text) can locate a target — icons, toolbars,
/// canvas/painted UI.
enum MarkOverlay {

    /// One numbered candidate. `bbox` is in image-pixel coordinates (top-left
    /// origin, same scale as the screenshot the model receives).
    struct Mark {
        let index: Int
        let label: String   // short hint (AX title / OCR text), may be empty
        let bbox: CGRect
    }

    /// Build marks from AX element frames (converted to image pixels) plus OCR
    /// boxes, de-duplicated by rough position. Returns the marks and an
    /// annotated JPEG (base64) with numbered badges drawn on.
    static func build(baseImage cg: CGImage,
                      axElements: [AXTree.Element],
                      ocr: [OCR.Match]) -> (marks: [Mark], imageBase64: String?) {

        let imgW = CGFloat(cg.width), imgH = CGFloat(cg.height)
        let scale = ScreenCapture.pointsPerImagePixel   // points per image-pixel
        let origin = ScreenCapture.capturedDisplayOrigin

        var raw: [(rect: CGRect, label: String)] = []

        // AX frames are GLOBAL screen points → convert to local image pixels.
        for e in axElements {
            let f = e.frame
            let px = CGRect(x: (f.minX - origin.x) / scale,
                            y: (f.minY - origin.y) / scale,
                            width:  f.width  / scale,
                            height: f.height / scale)
            if px.width >= 8 && px.height >= 8 &&
               px.maxX <= imgW + 2 && px.maxY <= imgH + 2 && px.minX >= -2 && px.minY >= -2 {
                raw.append((px, e.title))
            }
        }
        // OCR boxes are already in image pixels.
        for m in ocr where m.bbox.width >= 8 && m.bbox.height >= 8 {
            raw.append((m.bbox, m.text))
        }

        // De-dup by center proximity (within 16px), prefer the one with a label.
        var kept: [(rect: CGRect, label: String)] = []
        for cand in raw {
            let c = CGPoint(x: cand.rect.midX, y: cand.rect.midY)
            if let i = kept.firstIndex(where: {
                abs($0.rect.midX - c.x) < 16 && abs($0.rect.midY - c.y) < 16
            }) {
                if kept[i].label.isEmpty && !cand.label.isEmpty { kept[i] = cand }
            } else {
                kept.append(cand)
            }
            if kept.count >= 80 { break }
        }

        let marks = kept.enumerated().map { (i, c) in
            Mark(index: i + 1, label: c.label, bbox: c.rect)
        }

        let annotated = drawBadges(on: cg, marks: marks)
        return (marks, annotated)
    }

    // MARK: - Drawing

    private static func drawBadges(on cg: CGImage, marks: [Mark]) -> String? {
        let w = cg.width, h = cg.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        // CoreGraphics origin is bottom-left; flip so we can draw in top-left space.
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.current = nsCtx

        for m in marks {
            // Flip y for drawing (image top-left → CG bottom-left).
            let r = CGRect(x: m.bbox.minX, y: CGFloat(h) - m.bbox.maxY,
                           width: m.bbox.width, height: m.bbox.height)
            // Outline the region.
            ctx.setStrokeColor(NSColor(red: 0.55, green: 0.30, blue: 0.95, alpha: 0.9).cgColor)
            ctx.setLineWidth(2)
            ctx.stroke(r)

            // Badge in the top-left corner of the region.
            let badge = "\(m.index)"
            let font = NSFont.monospacedSystemFont(ofSize: 15, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: NSColor.white
            ]
            let textSize = badge.size(withAttributes: attrs)
            let pad: CGFloat = 4
            let bw = textSize.width + pad * 2, bh = textSize.height + pad
            let bx = r.minX
            let by = r.maxY - bh   // top-left of the (flipped) rect
            let badgeRect = CGRect(x: bx, y: by, width: bw, height: bh)
            ctx.setFillColor(NSColor(red: 0.55, green: 0.30, blue: 0.95, alpha: 0.95).cgColor)
            ctx.fill(badgeRect)
            badge.draw(at: CGPoint(x: bx + pad, y: by + pad/2), withAttributes: attrs)
        }
        NSGraphicsContext.current = nil

        guard let out = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: out)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])?.base64EncodedString()
    }
}
