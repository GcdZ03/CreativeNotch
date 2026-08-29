import Foundation

/// Drops repeated emissions describing a state we are already showing.
///
/// The spike measured about six notifications for one press of play.
/// Letting them all through would rebuild the header and re-run peek
/// arbitration six times for a single user action — the same problem
/// `HUDCoalescer` solves for CoreAudio's duplicate callbacks.
///
/// Unlike the HUD's, this needs no time window. Artwork lives in
/// `MediaArtworkCache`, so a `TrackSnapshot` holds only identity and
/// playback state, and exact equality is both cheap and exactly the right
/// question: if nothing in it changed, there is nothing to redraw.
public struct MediaCoalescer: Equatable, Sendable {

    private var last: TrackSnapshot??

    public init() {}

    /// Returns whether this snapshot should be published.
    ///
    /// The doubled optional is deliberate: `nil` (media stopped) is itself
    /// a state that must be published once and then deduped, which an
    /// unwrapped optional could not distinguish from "nothing seen yet".
    public mutating func accept(_ snapshot: TrackSnapshot?) -> Bool {
        if let last, last == snapshot { return false }
        last = snapshot
        return true
    }
}
