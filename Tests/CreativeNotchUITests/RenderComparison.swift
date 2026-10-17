import AppKit

/// Compares two offscreen renders, allowing for the renderer's own noise.
///
/// Exact byte equality was flaky. Under a parallel test run, `ImageRenderer`
/// occasionally anti-aliases a curve one step differently: measured on
/// 2026-10-17 as 6-14 pixels on the shape's and the cover's rounded corners,
/// each off by exactly 1/255 in one channel. That made the "render twice,
/// get the same image" controls fail about one run in ten — and it could
/// equally have made a "these two differ" check pass on noise alone, which
/// is worse.
///
/// So two renders are the *same* when no channel of any pixel differs by
/// more than `tolerance`, and *different* only when one does.
enum Render {
    static let tolerance = 2   // out of 255

    static func same(_ a: Data, _ b: Data) -> Bool { !differs(a, b) }

    static func differs(_ a: Data, _ b: Data) -> Bool {
        guard let x = NSBitmapImageRep(data: a), let y = NSBitmapImageRep(data: b),
              x.pixelsWide == y.pixelsWide, x.pixelsHigh == y.pixelsHigh,
              x.bitsPerPixel == y.bitsPerPixel, x.bytesPerRow == y.bytesPerRow,
              x.bitsPerSample == 8,
              let px = x.bitmapData, let py = y.bitmapData
        else { return a != b }
        let count = x.bytesPerRow * x.pixelsHigh
        for i in 0..<count where abs(Int(px[i]) - Int(py[i])) > tolerance {
            return true
        }
        return false
    }
}
