import AppKit
import SwiftUI

/// The artwork's average colour, for the glow behind the cover (spec §5.2).
///
/// Computed once per artwork change, in a `.task(id:)`; never on a clock.
/// Downsampling the image to a single pixel is the whole algorithm — the
/// GPU does the averaging, and the result is one `Color`.
enum ArtworkTint {
    static func color(for data: Data) -> Color? {
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
        return Color(red: Double(p[0]) / 255, green: Double(p[1]) / 255, blue: Double(p[2]) / 255)
    }
}
