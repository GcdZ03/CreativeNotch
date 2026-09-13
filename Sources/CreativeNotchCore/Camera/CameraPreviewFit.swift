import Foundation

/// How big the preview is inside the space it has.
///
/// Pure, and worth a test **because the roadmap got this arithmetic wrong**:
/// it said a 16:9 preview 620 points wide wants 349 points of height against a
/// 260-point panel, and concluded it did not fit. That is only true fitting to
/// width. Fit to height and 16:9 at 260 tall is 462 x 260, inside 620 with
/// room to spare.
public enum CameraPreviewFit {

    /// The largest rect of `aspect` that fits inside `bounds`, centred.
    ///
    /// `aspect` is width divided by height: 16:9 is 1.777…, 4:3 is 1.333….
    public static func fit(aspect: Double, in bounds: CGSize) -> CGRect {
        guard aspect > 0, bounds.width > 0, bounds.height > 0 else { return .zero }

        let boundsAspect = bounds.width / bounds.height
        let size: CGSize = boundsAspect > aspect
            // Taller than wide relative to the content: height is the limit.
            ? CGSize(width: bounds.height * aspect, height: bounds.height)
            // Wider: width is the limit.
            : CGSize(width: bounds.width, height: bounds.width / aspect)

        return CGRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    /// The panel is 620 x 260 and the camera tab takes all of it, suppressing
    /// the media header and the tab bar.
    ///
    /// Not tidiness: the content area left by that chrome is roughly 195
    /// points, dropping to about 130 when a track starts playing -- and **a
    /// preview whose height changes when music starts is not acceptable.**
    /// Taking the full height leaves `expandedFrame` untouched, so no other
    /// tab is affected.
    public static let standardAspect: Double = 16.0 / 9.0
}
