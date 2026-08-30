import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// Where the pieces meet. Driven entirely through `handle(line:)`, so no
/// subprocess is involved.
@MainActor
struct MediaControllerTests {

    private func line(
        title: String = "T",
        artist: String = "A",
        playing: Bool = true,
        id: String = "id-1",
        artwork: Data? = nil
    ) -> String {
        var json = "{\"title\":\"\(title)\",\"artist\":\"\(artist)\",\"album\":\"\","
        json += "\"playing\":\(playing),\"contentID\":\"\(id)\""
        if let artwork { json += ",\"artwork\":\"\(artwork.base64EncodedString())\"" }
        return json + "}"
    }

    @Test func aLineBecomesASnapshot() {
        let c = MediaController()
        c.handle(line: line(title: "Beauty And A Beat", artist: "Justin Bieber"))

        #expect(c.snapshot?.title == "Beauty And A Beat")
        #expect(c.snapshot?.artist == "Justin Bieber")
        #expect(c.snapshot?.isPlaying == true)
    }

    /// The measured burst becomes one published change.
    @Test func aBurstOfIdenticalLinesPublishesOnce() {
        let c = MediaController()
        var published = 0
        c.onChange = { _ in published += 1 }

        for _ in 0..<6 { c.handle(line: line()) }

        #expect(published == 1)
    }

    @Test func aRealChangePublishesAgain() {
        let c = MediaController()
        var published = 0
        c.onChange = { _ in published += 1 }

        c.handle(line: line(playing: true))
        c.handle(line: line(playing: false))

        #expect(published == 2)
    }

    /// The spike's flap sequence, end to end: the artwork the user sees
    /// must not disappear when a payload omits it.
    @Test func artworkSurvivesPayloadsThatOmitIt() throws {
        let c = MediaController()
        let art = Data(repeating: 3, count: 512)

        c.handle(line: line(artwork: art))
        c.handle(line: line(artwork: nil))
        c.handle(line: line(artwork: nil))

        let snapshot = try #require(c.snapshot)
        #expect(c.artwork(for: snapshot) == art)
    }

    /// The brief's `artworkSurvivesPayloadsThatOmitIt` puts the artwork on
    /// the very FIRST line `MediaController` ever sees, and `MediaCoalescer`
    /// always accepts a first-ever snapshot regardless of absorb order —
    /// so that test cannot actually distinguish "absorb before coalescing"
    /// from "absorb after coalescing". This test puts the artwork on a
    /// SECOND, otherwise-identical line instead, so the coalescer treats it
    /// as a duplicate: absorbing after the coalescer would `return` before
    /// ever seeing this payload's artwork, and it would be lost forever.
    @Test func artworkArrivingOnADuplicateLineIsStillCached() throws {
        let c = MediaController()
        let art = Data(repeating: 7, count: 256)

        c.handle(line: line(artwork: nil))
        c.handle(line: line(artwork: art))

        let snapshot = try #require(c.snapshot)
        #expect(c.artwork(for: snapshot) == art)
    }

    @Test func garbageLinesAreIgnored() {
        let c = MediaController()
        c.handle(line: line(title: "Real"))
        c.handle(line: "[stream] registered")
        c.handle(line: "not json")

        #expect(c.snapshot?.title == "Real")
    }

    /// Spec section 4.7: nothing runs outside `.active`.
    @Test func lockingStopsTheHelper() {
        let c = MediaController()
        var stops = 0
        c.supervisor.stopHelper = { stops += 1 }
        c.supervisor.startHelper = {}
        c.supervisor.scheduleRetry = { _, _ in }
        c.start()

        c.setActivity(.locked)

        #expect(stops >= 1)
    }

    @Test func unlockingStartsItAgain() {
        let c = MediaController()
        var starts = 0
        c.supervisor.startHelper = { starts += 1 }
        c.supervisor.stopHelper = {}
        c.supervisor.scheduleRetry = { _, _ in }
        c.start()
        c.setActivity(.locked)
        let before = starts

        c.setActivity(.active)

        #expect(starts > before)
    }

    /// Media stopping must clear the header rather than leave the last
    /// track on screen forever.
    @Test func anEmptyPayloadClearsTheSnapshot() {
        let c = MediaController()
        c.handle(line: line(title: "Something"))
        c.handle(line: #"{"title":"","artist":"","album":"","playing":false}"#)

        #expect(c.snapshot == nil)
    }
}
