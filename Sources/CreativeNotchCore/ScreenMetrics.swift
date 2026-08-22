import CoreGraphics

/// A pure snapshot of the parts of `NSScreen` that geometry depends on.
///
/// Keeping this AppKit-free is what allows `NotchGeometry` to be tested
/// headlessly. The executable target populates it from a real `NSScreen`.
public struct ScreenMetrics: Equatable, Sendable {
    public var frame: CGRect
    public var safeAreaTopInset: CGFloat
    public var auxiliaryTopLeftWidth: CGFloat
    public var auxiliaryTopRightWidth: CGFloat
    public var menuBarHeight: CGFloat

    public init(
        frame: CGRect,
        safeAreaTopInset: CGFloat,
        auxiliaryTopLeftWidth: CGFloat,
        auxiliaryTopRightWidth: CGFloat,
        menuBarHeight: CGFloat
    ) {
        self.frame = frame
        self.safeAreaTopInset = safeAreaTopInset
        self.auxiliaryTopLeftWidth = auxiliaryTopLeftWidth
        self.auxiliaryTopRightWidth = auxiliaryTopRightWidth
        self.menuBarHeight = menuBarHeight
    }
}
