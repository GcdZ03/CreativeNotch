import Foundation

/// What VoiceOver is told when a peek appears.
///
/// A peek is a few seconds of picture at the top of the screen. Nobody is
/// asked to look at it, so a VoiceOver user — who has no reason to move the
/// cursor up there — would otherwise never learn the charger slipped out or
/// the timer they set has finished. The peek's words are posted as an
/// announcement from the one place peeks are applied
/// (`AppDelegate.applyPeek`).
///
/// Pure, and in Core, for the reason `PeekArbiter` is: the interesting part
/// is the rules about when to stay **quiet**, and those are testable without
/// a screen reader running.
public enum PeekAnnouncement {

    /// The words for a peek, or `nil` for one that is never spoken.
    ///
    /// Each reuses the module's own wording — `PowerLabel.peekTitle`, the
    /// spoken completion — so what is heard is what is shown. The views use
    /// this as their accessibility label too, so an announcement and a
    /// VoiceOver cursor landing on the same peek say the same thing.
    ///
    /// The drop target is `nil`: it is the user's own drag answering back,
    /// and announcing it would narrate a gesture they are in the middle of.
    public static func text(for content: PeekContent) -> String? {
        switch content {
        case .dragTarget:
            return nil
        case .timerDone(let completion):
            return TimerSpokenText.completion(completion)
        case .power(let event):
            return PowerLabel.spoken(for: event)
        case .nowPlaying(let track):
            return nowPlaying(track)
        }
    }

    /// "Now playing: title by artist", without a dangling "by" for tracks
    /// that have no artist — podcasts and voice memos, as `NowPlayingLabel`
    /// notes.
    public static func nowPlaying(_ track: TrackSnapshot) -> String {
        guard !track.artist.isEmpty else { return "Now playing: \(track.title)" }
        return "Now playing: \(track.title) by \(track.artist)"
    }

    /// Whether moving the peek slot from `previous` to `content` is news,
    /// and if so what to say. `previous` is `nil` when nothing was peeking.
    ///
    /// Silence is the default for re-application, and that matters most for
    /// now-playing. Every pause, play and seek republishes the snapshot, and
    /// the peek on screen is re-applied each time; an announcement for each
    /// would bury the ones that matter. So a now-playing peek is spoken when
    /// it appears and when the *track* changes under it — title or artist —
    /// and never for the rest of the snapshot.
    ///
    /// The transients are spoken whenever they differ from what was showing:
    /// a re-check that finds the same power peek still live is not news, a
    /// finished timer replacing it is, and so is the power peek revealed
    /// when the timer's lapses.
    public static func announcement(showing content: PeekContent, replacing previous: PeekContent?) -> String? {
        guard content != previous else { return nil }
        if case .nowPlaying(let next) = content, case .nowPlaying(let shown)? = previous,
           next.title == shown.title, next.artist == shown.artist {
            return nil
        }
        return text(for: content)
    }
}
