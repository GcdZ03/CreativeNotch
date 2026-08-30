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

    // MARK: - Degrading (final review I3)

    /// Spec section 5: once the helper has failed past its retry cap the
    /// panel shows no header. Nothing else ever clears `snapshot`, so
    /// before this the panel kept the last track forever — for a song that
    /// may have ended hours ago — and hover kept peeking it. Driven
    /// through the supervisor's real exit path rather than by calling
    /// `degrade()` directly, because the bug was the missing `onDegraded`
    /// assignment, not the clearing.
    @Test func degradingClearsWhatIsOnScreen() {
        let c = MediaController()
        var published: [TrackSnapshot?] = []
        c.onChange = { published.append($0) }
        c.supervisor.startHelper = {}
        c.supervisor.stopHelper = {}
        var pending: (@MainActor () -> Void)?
        c.supervisor.scheduleRetry = { _, work in pending = work }

        c.handle(line: line(title: "Redbone"))
        #expect(c.snapshot?.title == "Redbone")

        for _ in 1...(HelperBackoff.maxAttempts + 1) {
            c.supervisor.helperExited(status: 1)
            pending?()
        }

        #expect(c.supervisor.isDegraded)
        #expect(c.snapshot == nil)
        #expect(published.last == .some(nil), "the clear must be published, not just stored")
    }

    /// A degrade that only cleared `snapshot` without resetting the
    /// coalescer would swallow the *next* clear (`nil` deduped against
    /// `nil`) and, worse, drop the first snapshot of any later run that
    /// happened to match the dead helper's last one.
    @Test func aTrackPublishesAgainAfterADegrade() {
        let c = MediaController()
        var published: [TrackSnapshot?] = []
        c.onChange = { published.append($0) }

        c.handle(line: line(title: "Redbone"))
        c.degrade()
        c.handle(line: line(title: "Redbone"))

        #expect(published.count == 3)
        #expect(published.last??.title == "Redbone")
    }

    // MARK: - Fresh attempt budget (final review I4)

    /// The supervisor promises that a helper which ran healthily and died
    /// much later gets a fresh attempt budget rather than tripping the
    /// crash-loop cap. The controller used to latch `noteHealthy()` behind
    /// a "have I ever seen a line" flag, so it fired exactly once in the
    /// controller's life: five crashes spread over five days degraded the
    /// module as if they had been a tight loop.
    @Test func aHealthyRunBetweenCrashesRestoresTheAttemptBudget() {
        let c = MediaController()
        c.supervisor.startHelper = {}
        c.supervisor.stopHelper = {}
        var pending: (@MainActor () -> Void)?
        c.supervisor.scheduleRetry = { _, work in pending = work }

        // The helper starts, works, and then dies four times — one short
        // of the cap.
        c.handle(line: line(title: "First"))
        for _ in 1..<HelperBackoff.maxAttempts {
            c.supervisor.helperExited(status: 1)
            pending?()
        }
        #expect(c.supervisor.attempt == HelperBackoff.maxAttempts - 1)

        // It comes back and proves itself again. THIS is the line the
        // latch used to swallow.
        c.handle(line: line(title: "Second"))
        #expect(c.supervisor.attempt == 0)

        // So four more deaths, days later, must not degrade the module.
        for _ in 1..<HelperBackoff.maxAttempts {
            c.supervisor.helperExited(status: 1)
            pending?()
        }

        #expect(c.supervisor.isDegraded == false)
        #expect(c.snapshot?.title == "Second")
    }
}
