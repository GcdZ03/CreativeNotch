import AppKit
import CreativeNotchCore

/// What picks a colour from the screen (2026-10-24).
///
/// A protocol so the suite never puts a loupe on the developer's screen: the
/// real one, `SystemColorSampler`, is handed in by `configureForRealLaunch()`
/// and nowhere else, and a bare `AppDelegate` gets `InertColorSampler`.
///
/// `completion` runs once, on the main actor: with the colour clicked, or
/// `nil` when the person pressed Esc.
@MainActor
protocol ColorSampling: AnyObject {
    func sample(_ completion: @escaping @MainActor (SampledColor?) -> Void)
}

/// `NSColorSampler`: the system's own loupe.
///
/// **No permission, and nothing at rest.** The sampler is the sanctioned way
/// to read one pixel of another app's window; it needs no Screen Recording
/// grant because the system draws the loupe and hands back only the colour
/// the person clicked. It exists only between the click on the dropper and
/// the click on the screen -- there is no monitor, no capture and no timer
/// before or after.
@MainActor
final class SystemColorSampler: ColorSampling {
    /// Held while the loupe is up, so the sampler is not released under it.
    private var sampler: NSColorSampler?

    func sample(_ completion: @escaping @MainActor (SampledColor?) -> Void) {
        let sampler = NSColorSampler()
        self.sampler = sampler
        sampler.show { [weak self] color in
            // Reduced to a Sendable value before hopping: `NSColor` is not
            // one, and the handler's thread is not promised in the header.
            let picked = color.flatMap(SampledColor.init)
            Task { @MainActor in
                self?.sampler = nil
                completion(picked)
            }
        }
    }
}

/// The sandbox default: finishes at once with nothing, as if Esc were
/// pressed. A test that wants a pick hands in a sampler of its own.
@MainActor
final class InertColorSampler: ColorSampling {
    func sample(_ completion: @escaping @MainActor (SampledColor?) -> Void) {
        completion(nil)
    }
}

extension SampledColor {
    /// The colour converted to sRGB, or `nil` for one with no components
    /// (a pattern). sRGB because a hex value means sRGB to every tool it is
    /// pasted into; a pixel on a Display P3 screen is converted, and a colour
    /// outside sRGB clamps to its edge (`SampledColor(red:green:blue:)`).
    init?(_ color: NSColor) {
        guard color.type == .componentBased || color.type == .catalog,
              let srgb = color.usingColorSpace(.sRGB) else { return nil }
        self.init(
            red: Double(srgb.redComponent),
            green: Double(srgb.greenComponent),
            blue: Double(srgb.blueComponent)
        )
    }
}
