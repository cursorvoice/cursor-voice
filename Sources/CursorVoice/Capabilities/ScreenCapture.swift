import Foundation
import AppKit
import ScreenCaptureKit

/// Captures the active display with ScreenCaptureKit and returns a base64
/// JPEG along with light metadata. First call triggers macOS's Screen
/// Recording permission prompt.
final class ScreenCapture {
    static let shared = ScreenCapture()

    /// Ratio from captured-image-pixels to screen-points, set on every capture.
    /// `point = imagePx * pointsPerImagePixel`. On a default Retina display
    /// macOS reports SCDisplay.width as scaled-pixels (which equals points),
    /// so this is typically 1.0 — but it adjusts dynamically if a setup ever
    /// returns true native pixels (then ratio ≈ 1/backingScale).
    nonisolated(unsafe) static var pointsPerImagePixel: CGFloat = 1.0

    /// Result returned to the realtime client.
    /// `imageBase64` is the JPEG payload that will be injected as an
    /// input_image conversation item so the model can see what's on screen.
    struct Result {
        let metadata: [String: String]
        let imageBase64: String?
        /// The raw CGImage — kept around so OCR / Vision pipelines can run on
        /// it without re-decoding the JPEG.
        let cgImage: CGImage?
    }

    func capture() async -> Result {
        let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                                onScreenWindowsOnly: true)
            guard let display = pickDisplay(content: content) else {
                return Result(metadata: ["error": "no display found", "frontmost": frontmost],
                              imageBase64: nil, cgImage: nil)
            }

            let cfg = SCStreamConfiguration()
            // Capture at the display's NATIVE pixel resolution. Coordinates
            // the model reads from this image map 1:1 to InputSynth's input.
            cfg.width  = display.width
            cfg.height = display.height
            cfg.showsCursor = true
            cfg.pixelFormat = kCVPixelFormatType_32BGRA

            // Exclude our own windows (orb panel + cursor halo). Otherwise the
            // model sees its own overlay covering the UI it's trying to click.
            let ourBundleID = Bundle.main.bundleIdentifier ?? "com.cursorvoice.app"
            let ourWindows = content.windows.filter {
                $0.owningApplication?.bundleIdentifier == ourBundleID
            }
            let filter = SCContentFilter(display: display, excludingWindows: ourWindows)
            let cg = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                configuration: cfg)

            guard let jpeg = jpegEncode(cg, quality: 0.72) else {
                return Result(metadata: ["error": "jpeg encode failed", "frontmost": frontmost],
                              imageBase64: nil, cgImage: cg)
            }
            let b64 = jpeg.base64EncodedString()

            // Record the image-pixel ↔ screen-point ratio for InputSynth.
            if let nsScreen = NSScreen.screens.first(where: {
                let id = ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
                return id == display.displayID
            }) ?? NSScreen.main {
                Self.pointsPerImagePixel = nsScreen.frame.width / CGFloat(cfg.width)
            }
            NSLog("ScreenCapture: \(cfg.width)x\(cfg.height), \(jpeg.count) bytes JPEG, frontmost=\(frontmost), pt/px=\(Self.pointsPerImagePixel)")

            return Result(
                metadata: [
                    "frontmost": frontmost,
                    "image_size_px": "\(cfg.width)x\(cfg.height)",
                    "note": "Click coordinates are image pixels, origin TOP-LEFT, matching this screenshot exactly."
                ],
                imageBase64: b64,
                cgImage: cg
            )
        } catch {
            NSLog("ScreenCapture: failed: \(error.localizedDescription)")
            return Result(
                metadata: ["error": error.localizedDescription, "frontmost": frontmost],
                imageBase64: nil,
                cgImage: nil
            )
        }
    }

    private func pickDisplay(content: SCShareableContent) -> SCDisplay? {
        // Try the screen the cursor is on (best-effort — display IDs sometimes
        // don't line up cleanly with NSScreen on multi-monitor setups).
        let cursor = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(cursor, $0.frame, false) }),
           let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
           let match = content.displays.first(where: { $0.displayID == id }) {
            return match
        }
        return content.displays.first
    }

    private func jpegEncode(_ cg: CGImage, quality: Double) -> Data? {
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}
