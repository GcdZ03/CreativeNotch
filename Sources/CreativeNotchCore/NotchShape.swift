import CoreGraphics

/// The visible region of the panel, in panel-local coordinates.
///
/// The window is always the full expanded size, so everything outside this
/// rect must pass clicks through to whatever is underneath — otherwise the
/// panel eats menu bar clicks across a 620pt band.
public enum NotchShape {

    /// How much of the panel is currently drawn. Deliberately coarser than
    /// `NotchState`: `.receiving` and `.open` are both `.expanded` here.
    public enum Presentation: Equatable, Sendable {
        case closed
        case peek
        case expanded
    }

    /// Panel-local, bottom-left origin, y increasing upward — matching an
    /// unflipped `NSView`.
    public static func visibleRect(
        presentation: Presentation,
        anchor: Anchor,
        panelFrame: CGRect
    ) -> CGRect {
        let local = CGRect(
            x: anchor.rect.minX - panelFrame.minX,
            y: anchor.rect.minY - panelFrame.minY,
            width: anchor.rect.width,
            height: anchor.rect.height
        )

        switch presentation {
        case .closed:
            return local

        case .peek:
            // On real hardware the peek grows sideways into the ears and
            // keeps the notch's own height, so the icon and the bar land
            // beside the camera housing instead of behind it. A centred
            // slab put 72% of the level bar under the notch on a 14" Mac.
            if anchor.isNotch {
                let ear = NotchGeometry.peekEarWidth
                return CGRect(
                    x: local.minX - ear,
                    y: local.minY,
                    width: local.width + ear * 2,
                    height: local.height
                )
            }
            // A notchless Mac has nothing to avoid, so the pill keeps the
            // original centred slab.
            let size = NotchGeometry.peekSize
            return CGRect(
                x: local.midX - size.width / 2,
                y: local.maxY - size.height,
                width: size.width,
                height: size.height
            )

        case .expanded:
            return CGRect(origin: .zero, size: panelFrame.size)
        }
    }

}
