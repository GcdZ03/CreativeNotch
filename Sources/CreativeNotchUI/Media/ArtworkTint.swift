import AppKit
import SwiftUI

/// The artwork's average colour, for the glow behind the cover (spec §5.2)
/// and the equalizer's bars (spec 2026-10-15).
///
/// Computed once per artwork change, in a `.task(id:)`; never on a clock.
/// Downsampling the image to a single pixel is the whole algorithm — the
/// GPU does the averaging, and the result is one `Color`.
enum ArtworkTint {
    static func color(for data: Data) -> Color? {
        nsColor(for: data).map { Color(nsColor: $0) }
    }

    /// The same average, lifted so it shows on the black notch.
    static func barColor(for data: Data) -> Color? {
        nsColor(for: data).map { Color(nsColor: legible($0)) }
    }

    /// Keeps the hue, caps the saturation and floors the brightness.
    ///
    /// A cover's average is often near-black, and bars that colour vanish
    /// into the notch they sit in. A garish one is no better beside the
    /// menu bar, hence the cap.
    static func legible(_ color: NSColor) -> NSColor {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
        return NSColor(deviceHue: h, saturation: min(s, 0.7), brightness: max(b, 0.8), alpha: 1)
    }

    private static func nsColor(for data: Data) -> NSColor? {
        guard let image = NSImage(data: data),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        guard let ctx = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let p = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        return NSColor(
            deviceRed: CGFloat(p[0]) / 255, green: CGFloat(p[1]) / 255,
            blue: CGFloat(p[2]) / 255, alpha: 1
        )
    }
}
