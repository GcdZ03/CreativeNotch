import Foundation

/// The last few colours picked, newest first (2026-10-24).
///
/// **In memory only, never stored.** It is a convenience for the session --
/// re-copying the colour picked a minute ago -- and the clipboard history
/// beside it makes the same promise. Switching the module off empties it.
public struct ColorHistory: Equatable, Sendable {
    /// Five: as many swatches as fit beside the value in the panel's strip
    /// at the largest text size, each still a comfortable target.
    public static let capacity = 5

    public private(set) var colors: [SampledColor] = []

    public init() {}

    /// Puts `color` first. A colour already here moves to the front rather
    /// than appearing twice: two identical swatches side by side read as a
    /// glitch, and re-picking a colour is a way of saying it matters now.
    public mutating func record(_ color: SampledColor) {
        colors.removeAll { $0 == color }
        colors.insert(color, at: 0)
        if colors.count > Self.capacity { colors.removeLast(colors.count - Self.capacity) }
    }

    public mutating func clear() {
        colors.removeAll()
    }
}
