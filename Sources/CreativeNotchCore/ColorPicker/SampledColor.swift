import Foundation

/// A colour picked from the screen, reduced to the three 8-bit sRGB channels
/// every copy format prints (2026-10-24).
///
/// **Eight bits, not the sampler's floating-point components.** Two picks of
/// the same pixel must compare equal, or the history would show one colour
/// twice; and every format the picker copies -- hex, `rgb()`, `hsl()`, a
/// SwiftUI initialiser to three decimals -- is exact at this resolution. A
/// `Double` carried through would only add digits nobody can paste.
///
/// **Always sRGB.** The AppKit side converts before it gets here
/// (`SampledColor.init(_: NSColor)` in the UI target), because a hex value
/// means sRGB to every tool it is pasted into; a Display P3 component printed
/// as hex is a different colour on the web.
public struct SampledColor: Hashable, Sendable {
    public let red8: UInt8
    public let green8: UInt8
    public let blue8: UInt8

    public init(red8: UInt8, green8: UInt8, blue8: UInt8) {
        self.red8 = red8
        self.green8 = green8
        self.blue8 = blue8
    }

    /// From components in 0...1. Out of range clamps rather than traps: a
    /// wide-gamut pixel converted to sRGB lands just outside the unit range
    /// as a matter of course, and `UInt8(_:)` of 256 would crash the app on
    /// the most saturated thing on screen. NaN reads as zero.
    public init(red: Double, green: Double, blue: Double) {
        self.init(red8: Self.channel(red), green8: Self.channel(green), blue8: Self.channel(blue))
    }

    private static func channel(_ value: Double) -> UInt8 {
        guard value.isFinite else { return 0 }
        return UInt8((min(1, max(0, value)) * 255).rounded())
    }

    /// The channels as fractions, for drawing the swatch.
    public var red: Double { Double(red8) / 255 }
    public var green: Double { Double(green8) / 255 }
    public var blue: Double { Double(blue8) / 255 }

    /// Hue in degrees (0..<360), saturation and lightness in 0...1, by the
    /// CSS Color 4 conversion. Shared by the `hsl()` format and the spoken
    /// name, so the two cannot disagree about what colour this is.
    public var hsl: (hue: Double, saturation: Double, lightness: Double) {
        let r = red, g = green, b = blue
        let maximum = max(r, g, b), minimum = min(r, g, b)
        let delta = maximum - minimum
        let lightness = (maximum + minimum) / 2
        guard delta > 0 else { return (0, 0, lightness) }
        let saturation = delta / (1 - abs(2 * lightness - 1))
        var hue: Double
        switch maximum {
        case r:  hue = (g - b) / delta
        case g:  hue = (b - r) / delta + 2
        default: hue = (r - g) / delta + 4
        }
        hue *= 60
        if hue < 0 { hue += 360 }
        return (hue, min(1, saturation), lightness)
    }
}
