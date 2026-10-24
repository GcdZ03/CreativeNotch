import SwiftUI
import CreativeNotchCore

extension EnvironmentValues {
    /// `TextSize.scale` for the open panel (2026-10-24).
    ///
    /// Set by `NotchRootView` on the open panel and the drop target only, so
    /// a view shared with a peek -- the transport buttons, the progress bar --
    /// draws at one there and at the setting here, without being told which
    /// it is in. One by default: anything outside the open panel is the size
    /// it always was.
    @Entry var notchTextScale: CGFloat = 1
}

/// A panel font at the panel's text size: `.system(size:weight:design:)` at
/// `NotchType.size` of the nominal size, read from the environment where it
/// is drawn.
///
/// A modifier rather than a `Font`, because a `Font` cannot read the
/// environment, and handing the scale to every view by hand is how one gets
/// missed. No observer: SwiftUI re-resolves it when the value changes.
private struct NotchFont: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight?
    let design: Font.Design?
    @Environment(\.notchTextScale) private var scale

    func body(content: Content) -> some View {
        content.font(.system(size: NotchType.size(size, scale: scale), weight: weight, design: design))
    }
}

/// A fixed frame that holds text or a glyph, grown by `NotchType.length` so
/// a larger font is not squeezed into the box sized for the smaller one.
private struct NotchFrame: ViewModifier {
    let width: CGFloat?
    let height: CGFloat?
    let alignment: Alignment
    @Environment(\.notchTextScale) private var scale

    func body(content: Content) -> some View {
        content.frame(
            width: width.map { NotchType.length($0, scale: scale) },
            height: height.map { NotchType.length($0, scale: scale) },
            alignment: alignment
        )
    }
}

extension View {
    /// The open panel's font for a nominal point size. Use this, not
    /// `.font(.system(size:))`, anywhere inside the open panel; the closed
    /// notch's badges and the peeks keep fixed sizes (see `NotchType`).
    nonisolated func notchFont(_ size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) -> some View {
        modifier(NotchFont(size: size, weight: weight, design: design))
    }

    /// `.frame(width:height:alignment:)` for a box that holds panel text or
    /// a glyph: a button, a tile, a column of icons. Graphics that hold no
    /// text -- the battery gauge, the progress bars -- keep plain frames.
    nonisolated func notchFrame(
        width: CGFloat? = nil, height: CGFloat? = nil, alignment: Alignment = .center
    ) -> some View {
        modifier(NotchFrame(width: width, height: height, alignment: alignment))
    }
}
