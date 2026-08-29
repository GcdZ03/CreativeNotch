# Media Metadata Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show what is playing — title, artist, artwork — in the open panel's header and as an ambient peek, by reading now-playing metadata through a helper process that has the code-signing exemption the app itself cannot have.

**Architecture:** `/usr/bin/perl` is signed `com.apple.perl`, which `mediaremoted` allows. The app spawns it, perl loads a dylib we ship, and the dylib streams newline-delimited JSON back over stdout. Everything carrying judgement — payload decoding, line reassembly, coalescing, artwork caching, backoff — is pure logic in `CreativeNotchCore` and runs headlessly. `CreativeNotchUI` owns the subprocess and the views.

**Tech Stack:** Swift 6.3, SwiftUI, AppKit, Objective-C (the bridge), perl 5.34 (system), MediaRemote (private, via `dlopen`), Swift Testing, SwiftPM. No third-party dependencies.

**Spec:** `docs/specs/2026-08-29-media-metadata-design.md`
**Research:** `docs/research/2026-08-29-media-metadata-feasibility.md` — **read this before Task 6.** It records three traps that each produce a wrong conclusion.

## Global Constraints

- Minimum platform **macOS 26.0**.
- **No third-party dependencies.** Standard library, AppKit, SwiftUI, Swift Testing only. The bridge is ours; the technique is the only borrowed part.
- **`CreativeNotchCore` must never `import AppKit`, `import SwiftUI`, `import UIKit` or `import Cocoa`.** `CorePurityTests` enforces this recursively.
- **No polling.** The helper is push-driven by MediaRemote notifications. The clipboard poller remains the only `Timer` in the codebase. No new timers, monitors, or `DispatchSourceTimer`s.
- **Never log payload contents.** Track titles and artists are user data — the same rule the clipboard module follows. Counts and error kinds only. No `NSLog`/`print`/`debugPrint` may take a title, artist, or artwork as an argument.
- **No test may spawn the helper.** The line source is injected everywhere. `Process` must not appear in any test file.
- **Never mutate `AppState.state` directly.** It is `private(set)`; go through `transition(to:)`.
- All new types in `CreativeNotchCore` are `public`, `Equatable`, and `Sendable`.
- **No `Task.sleep` in tests.**
- **Every new test must be proven to fail against the bug it targets** — introduce it, watch it fail, revert. Verify the build succeeds before interpreting a mutation result: an invalid mutation breaks the build, produces no test failures, and looks identical to an uncaught bug.
- Conventional commit prefixes (`feat:`, `fix:`, `test:`, `chore:`, `docs:`).
- Baseline before this plan: **394 tests in 46 suites, all passing.**

## Three rules the spike forced

Each comes from observed behaviour. Getting any of them wrong produces a visible bug, and none is discoverable from a one-shot read.

1. **Artwork is cached by track identity and NEVER cleared because a payload omits it.** For one unchanged song, consecutive emissions reported artwork sizes `138061 → 0 → 0 → 138061 → 138061 → 0 → 138061`. Clearing on omission flickers the album art several times per play/pause.
2. **One user action emits about six notifications.** They must be coalesced.
3. **`playbackRate` is the source of truth for playing state**, not notification arrival or ordering.

## File Structure

**`CreativeNotchCore` — pure, headless**

| File | Responsibility |
|---|---|
| `Media/MediaPayload.swift` | One decoded JSON line; tolerates missing fields and absent artwork |
| `Media/LineBuffer.swift` | Reassembles NDJSON from arbitrary byte chunks |
| `Media/TrackIdentity.swift` | Stable identity for a track, for artwork keying and change detection |
| `Media/MediaArtworkCache.swift` | Artwork by identity, bounded; the never-clear-on-omission rule |
| `Media/MediaCoalescer.swift` | Collapses the notification burst |
| `Media/HelperBackoff.swift` | Restart schedule and the give-up point |

**`CreativeNotchUI` — subprocess and views**

| File | Responsibility |
|---|---|
| `Media/MediaHelperProcess.swift` | Spawns perl, reads stdout, reports exit |
| `Media/MediaHelperSupervisor.swift` | Restart with backoff; degrade after the cap |
| `Media/MediaController.swift` | Judgement and wiring, mirroring `HUDController` |
| `Media/NowPlayingView.swift` | The header |

**`Sources/CreativeNotchMediaBridge/`** — the ObjC dylib (new target).
**`Resources/media-helper.pl`** — the perl loader.

**Modified:** `Package.swift`, `Scripts/bundle.sh`, `AppDelegate.swift`, `ClipboardController.swift`, `NotchRootView.swift`, `CorePurityTests.swift`, `README.md`.

---

### Task 1: Hoist `SystemActivityObserver` to `AppDelegate`

Not part of the media feature — a prerequisite refactor, first and in its own commit.

`SystemActivityObserver` is currently owned privately by `ClipboardController`. This module needs the same signal, and spec section 4.7 is explicit that the gate is *"enforced once, here"*. Two observers would mean two sets of workspace and distributed-notification registrations for one fact, and two places to get lock-vs-sleep precedence wrong.

**Files:**
- Modify: `Sources/CreativeNotchUI/Clipboard/ClipboardController.swift`
- Modify: `Sources/CreativeNotchUI/AppDelegate.swift`
- Modify: `Tests/CreativeNotchUITests/ClipboardControllerTests.swift`
- Create: `Tests/CreativeNotchUITests/SystemActivityFanOutTests.swift`

**Interfaces:**
- Produces:
  - `ClipboardController.setActivity(_ activity: SystemActivity, now: TimeInterval)` — replaces its private observer
  - `AppDelegate.activity: SystemActivityObserver` (internal, so the fan-out is provable)

- [ ] **Step 1: Write the failing tests**

Create `Tests/CreativeNotchUITests/SystemActivityFanOutTests.swift`:

```swift
import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// Spec section 4.7: the sleep/lock gate is "enforced once, here". One
/// observer, fanned out — not one per consumer.
///
/// Two observers would mean two sets of registrations for a single fact,
/// and two independent chances to get the sleep-outranks-lock precedence
/// wrong.
@MainActor
struct SystemActivityFanOutTests {

    private static let notched = ScreenMetrics(
        frame: CGRect(x: 1470, y: 200, width: 1470, height: 956),
        safeAreaTopInset: 38,
        auxiliaryTopLeftWidth: 620,
        auxiliaryTopRightWidth: 620,
        menuBarHeight: 38
    )

    private func makeDelegate() -> AppDelegate {
        let delegate = AppDelegate()
        delegate.growthDelay = .zero
        delegate.shelfDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CreativeNotchFanOut-\(UUID().uuidString)")
        delegate.install(metrics: Self.notched)
        return delegate
    }

    @Test func theDelegateOwnsExactlyOneObserver() {
        let delegate = makeDelegate()
        delegate.activity.start()

        // Four registrations: sleep, wake, lock, unlock. Any more means a
        // second observer is registering alongside this one.
        #expect(delegate.activity.tokenCount == 4)
        delegate.activity.stop()
    }

    /// The clipboard poller must still be gated after the refactor — it is
    /// the behaviour the observer existed for in the first place.
    @Test func lockingStillSuspendsTheClipboardPoller() throws {
        let delegate = makeDelegate()
        let clipboard = try #require(delegate.clipboard)
        clipboard.poller.scheduleTimer = { _, _ in nil }
        clipboard.poller.cancelTimer = { _ in }
        clipboard.start()

        delegate.activity.handle(.screenLocked)

        #expect(clipboard.poller.scheduledInterval == nil)
    }

    @Test func unlockingResumesTheClipboardPoller() throws {
        let delegate = makeDelegate()
        let clipboard = try #require(delegate.clipboard)
        clipboard.poller.scheduleTimer = { _, _ in nil }
        clipboard.poller.cancelTimer = { _ in }
        clipboard.start()

        delegate.activity.handle(.screenLocked)
        delegate.activity.handle(.screenUnlocked)

        #expect(clipboard.poller.scheduledInterval == ClipboardPollSchedule.activeInterval)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter SystemActivityFanOutTests`
Expected: FAIL — `value of type 'AppDelegate' has no member 'activity'`.

- [ ] **Step 3: Move the observer out of `ClipboardController`**

In `ClipboardController`, delete the `activity` property and every reference to it. `start()` no longer calls `activity.start()`; `stop()` no longer calls `activity.stop()`. Add:

```swift
    /// The activity gate reaches the poller through here rather than
    /// through an observer this type owns. Spec section 4.7 puts the gate
    /// in one place; `AppDelegate` holds it and fans it out, so the media
    /// module and this one cannot disagree about whether the screen is
    /// locked.
    public func setActivity(_ activity: SystemActivity, now: TimeInterval) {
        poller.setActivity(activity, now: now)
    }
```

- [ ] **Step 4: Own the observer in `AppDelegate`**

Add beside the other module properties:

```swift
    /// One observer for the whole app. Internal rather than private so the
    /// fan-out is provable — `SystemActivityFanOutTests` asserts there is
    /// exactly one registration set.
    let activity = SystemActivityObserver()
```

In `install(metrics:)`, after the clipboard controller is built, wire the fan-out:

```swift
        activity.onChange = { [weak self] state in
            guard let self else { return }
            let now = Date().timeIntervalSince1970
            self.clipboard?.setActivity(state, now: now)
        }
```

In `applicationDidFinishLaunching`, start it beside the other modules; in `applicationWillTerminate`, stop it.

- [ ] **Step 5: Update `ClipboardControllerTests`**

Its tests drive `controller.activity.handle(...)` directly. Replace each with `controller.setActivity(.locked, now: 1)` / `.active`. Assertions are unchanged — the behaviour is identical, only the entry point moved.

- [ ] **Step 6: Run the full suite**

Run: `swift test`
Expected: PASS, 397 tests. The clipboard suite must still be green — if any clipboard test fails, the refactor changed behaviour and is wrong.

- [ ] **Step 7: Prove the tests bite**

Add a second `SystemActivityObserver()` to `ClipboardController` and start it in `start()`. Build, then run `swift test --filter SystemActivityFanOutTests`. Expected: `theDelegateOwnsExactlyOneObserver` still passes (it counts the delegate's own), so **this mutation does not bite** — note that in your report rather than claiming it does. Then delete the `activity.onChange` fan-out in `AppDelegate` instead. Build, run again. Expected: both clipboard gating tests fail. Revert.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "refactor: hoist the SystemActivity gate to AppDelegate"
```

---

### Task 2: `MediaPayload` — one line off the wire

The boundary between an untrusted byte stream and the rest of the app. Everything downstream assumes this type is already sane.

**Files:**
- Create: `Sources/CreativeNotchCore/Media/MediaPayload.swift`
- Create: `Tests/CreativeNotchCoreTests/MediaPayloadTests.swift`

**Interfaces:**
- Produces:
  - `struct MediaPayload: Equatable, Sendable, Decodable` with `title: String`, `artist: String`, `album: String`, `isPlaying: Bool`, `contentID: String?`, `artworkBase64: String?`
  - `static MediaPayload.decode(line: String) -> MediaPayload?`
  - `var artwork: Data?`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CreativeNotchCoreTests/MediaPayloadTests.swift`:

```swift
import Foundation
import Testing
@testable import CreativeNotchCore

/// One line of the helper's newline-delimited JSON.
///
/// This is the boundary between an untrusted byte stream and everything
/// downstream, so it has to survive anything the helper — or a corrupted
/// pipe — can emit, and never trap.
struct MediaPayloadTests {

    private let full = #"{"title":"Beauty And A Beat","artist":"Justin Bieber","album":"Believe","playing":true,"contentID":"E398464F","artwork":"QUJD"}"#

    @Test func aCompleteLineDecodes() throws {
        let p = try #require(MediaPayload.decode(line: full))
        #expect(p.title == "Beauty And A Beat")
        #expect(p.artist == "Justin Bieber")
        #expect(p.album == "Believe")
        #expect(p.isPlaying)
        #expect(p.contentID == "E398464F")
        #expect(p.artwork == Data("ABC".utf8))
    }

    /// The spike observed artwork present in one emission and absent in the
    /// next for the same track. An absent field is normal, not an error.
    @Test func anAbsentArtworkFieldIsNotAFailure() throws {
        let line = #"{"title":"T","artist":"A","album":"","playing":false}"#
        let p = try #require(MediaPayload.decode(line: line))
        #expect(p.artwork == nil)
        #expect(p.title == "T")
    }

    /// Missing text fields default to empty rather than failing the line —
    /// a track with no album is ordinary.
    @Test func missingTextFieldsDefaultToEmpty() throws {
        let p = try #require(MediaPayload.decode(line: #"{"playing":true}"#))
        #expect(p.title.isEmpty)
        #expect(p.artist.isEmpty)
        #expect(p.isPlaying)
    }

    @Test func malformedJSONYieldsNil() {
        #expect(MediaPayload.decode(line: "not json") == nil)
        #expect(MediaPayload.decode(line: "") == nil)
        #expect(MediaPayload.decode(line: "{") == nil)
        #expect(MediaPayload.decode(line: "[]") == nil)
    }

    /// The helper writes stderr diagnostics too. If those ever reach the
    /// stdout reader they must be dropped, not crash it.
    @Test func nonJSONDiagnosticLinesYieldNil() {
        #expect(MediaPayload.decode(line: "[stream] registered") == nil)
    }

    @Test func invalidBase64ArtworkIsIgnoredRatherThanFatal() throws {
        let line = #"{"title":"T","artist":"A","album":"","playing":true,"artwork":"!!!not base64!!!"}"#
        let p = try #require(MediaPayload.decode(line: line))
        #expect(p.artwork == nil)
        #expect(p.title == "T")
    }

    /// Titles contain quotes, emoji and non-Latin scripts. The spike's own
    /// test track was "跳楼机".
    @Test func unicodeAndQuotesSurvive() throws {
        let line = #"{"title":"跳楼机 \"live\"","artist":"歌手","album":"","playing":true}"#
        let p = try #require(MediaPayload.decode(line: line))
        #expect(p.title == "跳楼机 \"live\"")
        #expect(p.artist == "歌手")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter MediaPayloadTests`
Expected: FAIL — `cannot find 'MediaPayload' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/CreativeNotchCore/Media/MediaPayload.swift`:

```swift
import Foundation

/// One line of the helper's newline-delimited JSON.
///
/// Decoding is total: any line either produces a payload or `nil`, and
/// nothing here can trap. The helper is a subprocess reading a private
/// framework, and its output is the least trustworthy input in the app —
/// stderr diagnostics can appear, a pipe can truncate, and a future macOS
/// can change what MediaRemote returns.
///
/// Text fields default to empty rather than failing the whole line. A
/// track with no album is ordinary, and losing the title because the album
/// was absent would be a bad trade.
public struct MediaPayload: Equatable, Sendable, Decodable {

    public var title: String
    public var artist: String
    public var album: String
    public var isPlaying: Bool
    public var contentID: String?

    /// Base64 as it arrives on the wire. Kept encoded until asked for, so
    /// decoding a payload never allocates an image-sized buffer.
    public var artworkBase64: String?

    private enum CodingKeys: String, CodingKey {
        case title, artist, album, contentID
        case isPlaying = "playing"
        case artworkBase64 = "artwork"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        artist = try c.decodeIfPresent(String.self, forKey: .artist) ?? ""
        album = try c.decodeIfPresent(String.self, forKey: .album) ?? ""
        isPlaying = try c.decodeIfPresent(Bool.self, forKey: .isPlaying) ?? false
        contentID = try c.decodeIfPresent(String.self, forKey: .contentID)
        artworkBase64 = try c.decodeIfPresent(String.self, forKey: .artworkBase64)
    }

    /// Decoded artwork, or `nil` if absent or unusable.
    ///
    /// Invalid base64 yields `nil` rather than failing the payload: the
    /// title and artist are still worth showing, and the spike proved
    /// artwork is unreliable by nature.
    public var artwork: Data? {
        guard let artworkBase64 else { return nil }
        return Data(base64Encoded: artworkBase64)
    }

    /// Returns `nil` for anything that is not a JSON object — including
    /// the helper's own stderr diagnostics, should they ever be routed
    /// here by mistake.
    public static func decode(line: String) -> MediaPayload? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MediaPayload.self, from: data)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter MediaPayloadTests`
Expected: PASS, 7 tests.

- [ ] **Step 5: Prove the tests bite**

Change `decodeIfPresent(String.self, forKey: .title) ?? ""` to `decode(String.self, forKey: .title)`. Build, run `swift test --filter MediaPayloadTests`. Expected: `missingTextFieldsDefaultToEmpty` fails. Revert.

Change `artwork` to `Data(base64Encoded: artworkBase64)!`. Build, run again. Expected: `invalidBase64ArtworkIsIgnoredRatherThanFatal` crashes the suite — which is the point: a force-unwrap here takes the whole app down on a malformed line. Revert.

- [ ] **Step 6: Run the full suite**

Run: `swift test`
Expected: PASS, 404 tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/CreativeNotchCore/Media Tests/CreativeNotchCoreTests/MediaPayloadTests.swift
git commit -m "feat: decode the media helper's wire format"
```

---

### Task 3: `LineBuffer` — NDJSON across arbitrary reads

A `readabilityHandler` delivers whatever bytes happened to be available. A JSON line **will** be split across two reads, and two lines **will** arrive in one read. This type is where that is handled, and it gets its own tests because the failure is intermittent and invisible in casual use.

**Files:**
- Create: `Sources/CreativeNotchCore/Media/LineBuffer.swift`
- Create: `Tests/CreativeNotchCoreTests/LineBufferTests.swift`

**Interfaces:**
- Produces:
  - `struct LineBuffer: Equatable, Sendable` with `init()`, `mutating func append(_ chunk: String) -> [String]`, `var pending: String`, `mutating func reset()`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CreativeNotchCoreTests/LineBufferTests.swift`:

```swift
import Foundation
import Testing
@testable import CreativeNotchCore

/// Reassembles newline-delimited output from arbitrary chunks.
///
/// `FileHandle.readabilityHandler` hands over whatever bytes exist at that
/// moment — never whole lines. A payload split across two reads is the
/// normal case for anything larger than a pipe buffer, and artwork makes
/// these lines large. Handling it inline in the reader is how this bug
/// hides for months and then appears only for long titles.
struct LineBufferTests {

    @Test func aWholeLineIsReturnedImmediately() {
        var b = LineBuffer()
        #expect(b.append("hello\n") == ["hello"])
    }

    @Test func severalLinesInOneChunkAllReturn() {
        var b = LineBuffer()
        #expect(b.append("a\nb\nc\n") == ["a", "b", "c"])
    }

    /// The case this type exists for.
    @Test func aLineSplitAcrossChunksIsRejoined() {
        var b = LineBuffer()
        #expect(b.append("{\"tit") == [])
        #expect(b.append("le\":\"x\"}") == [])
        #expect(b.append("\n") == ["{\"title\":\"x\"}"])
    }

    /// A chunk boundary landing exactly on the newline must not produce an
    /// empty line or lose the next one.
    @Test func aChunkEndingOnTheNewlineIsClean() {
        var b = LineBuffer()
        #expect(b.append("one\n") == ["one"])
        #expect(b.append("two\n") == ["two"])
    }

    @Test func aTrailingPartialLineIsHeldNotEmitted() {
        var b = LineBuffer()
        #expect(b.append("complete\npartial") == ["complete"])
        #expect(b.pending == "partial")
    }

    /// Blank lines carry no payload and must not reach the decoder as
    /// empty strings it then has to special-case.
    @Test func blankLinesAreDropped() {
        var b = LineBuffer()
        #expect(b.append("a\n\n\nb\n") == ["a", "b"])
    }

    /// A helper restart must not glue the dead process's half-line onto the
    /// new one's first line, which would corrupt exactly one payload per
    /// restart — rare, and maddening to diagnose.
    @Test func resetDropsThePartialLine() {
        var b = LineBuffer()
        _ = b.append("half a li")
        b.reset()
        #expect(b.pending.isEmpty)
        #expect(b.append("ne\n") == ["ne"])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter LineBufferTests`
Expected: FAIL — `cannot find 'LineBuffer' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/CreativeNotchCore/Media/LineBuffer.swift`:

```swift
import Foundation

/// Reassembles newline-delimited text arriving in arbitrary chunks.
///
/// `FileHandle.readabilityHandler` delivers whatever bytes are available,
/// not whole lines. A payload carrying base64 artwork is far larger than a
/// pipe buffer, so splitting is the normal case rather than an edge one.
///
/// Kept separate from the reader, and pure, because the failure mode is
/// intermittent: a naive reader works perfectly until a line happens to
/// straddle a chunk boundary, which correlates with nothing a user can
/// describe.
public struct LineBuffer: Equatable, Sendable {

    private var buffer = ""

    public init() {}

    /// What is held back awaiting its newline.
    public var pending: String { buffer }

    /// Appends a chunk and returns every complete line it completed.
    ///
    /// Blank lines are dropped rather than returned as empty strings —
    /// they carry no payload, and letting them through only moves the
    /// special case into the decoder.
    public mutating func append(_ chunk: String) -> [String] {
        buffer += chunk

        var lines: [String] = []
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[buffer.startIndex..<newline])
            buffer = String(buffer[buffer.index(after: newline)...])
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }

    /// Discards any partial line.
    ///
    /// Called when the helper dies. Without it, the dead process's
    /// half-written line would be glued to the new process's first line,
    /// corrupting exactly one payload per restart.
    public mutating func reset() {
        buffer = ""
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter LineBufferTests`
Expected: PASS, 7 tests.

- [ ] **Step 5: Prove the tests bite**

Replace the `while` loop with a single `split(separator: "\n")` that returns everything and clears the buffer. Build, run `swift test --filter LineBufferTests`. Expected: `aTrailingPartialLineIsHeldNotEmitted` and `aLineSplitAcrossChunksIsRejoined` fail. Revert.

Delete the `if !line.isEmpty` guard. Build, run again. Expected: `blankLinesAreDropped` fails. Revert.

- [ ] **Step 6: Run the full suite**

Run: `swift test`
Expected: PASS, 411 tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/CreativeNotchCore/Media/LineBuffer.swift Tests/CreativeNotchCoreTests/LineBufferTests.swift
git commit -m "feat: reassemble the helper's output across read boundaries"
```

---

### Task 4: `TrackIdentity` and `MediaArtworkCache`

Where the spike's sharpest finding lives. Artwork flapped present/absent for a single unchanged track; the cache is what makes that invisible to the user.

**Files:**
- Create: `Sources/CreativeNotchCore/Media/TrackIdentity.swift`
- Create: `Sources/CreativeNotchCore/Media/MediaArtworkCache.swift`
- Create: `Tests/CreativeNotchCoreTests/MediaArtworkCacheTests.swift`

**Interfaces:**
- Consumes: `MediaPayload` (Task 2).
- Produces:
  - `struct TrackIdentity: Hashable, Sendable` with `init(payload: MediaPayload)` and `var key: String`
  - `struct MediaArtworkCache: Equatable, Sendable` with `static let capacity = 8`, `static let maxEntryBytes = 5_000_000`, `init()`, `mutating func absorb(_ payload: MediaPayload) `, `func artwork(for identity: TrackIdentity) -> Data?`, `var count: Int`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CreativeNotchCoreTests/MediaArtworkCacheTests.swift`:

```swift
import Foundation
import Testing
@testable import CreativeNotchCore

/// Artwork keyed by track identity.
///
/// The spike found artwork flapping present/absent across consecutive
/// emissions for ONE unchanged song: 138061 → 0 → 0 → 138061 → 138061 → 0
/// → 138061. Clearing the art whenever a payload omits it would flicker
/// the album cover several times per play/pause. This type is the reason
/// that never reaches the screen.
struct MediaArtworkCacheTests {

    private func payload(
        title: String = "T",
        artist: String = "A",
        id: String? = "id-1",
        artwork: Data? = nil
    ) -> MediaPayload {
        var json = "{\"title\":\"\(title)\",\"artist\":\"\(artist)\",\"album\":\"\",\"playing\":true"
        if let id { json += ",\"contentID\":\"\(id)\"" }
        if let artwork { json += ",\"artwork\":\"\(artwork.base64EncodedString())\"" }
        json += "}"
        return MediaPayload.decode(line: json)!
    }

    private let art = Data(repeating: 7, count: 1024)

    // MARK: - Identity

    @Test func contentIDIdentifiesTheTrack() {
        let a = TrackIdentity(payload: payload(title: "X", id: "same"))
        let b = TrackIdentity(payload: payload(title: "Y", id: "same"))
        #expect(a == b)
    }

    /// Not every player supplies a content id, so title+artist is the
    /// fallback — without it, every payload would look like a new track and
    /// the cache would never hit.
    @Test func titleAndArtistIdentifyATrackWithNoContentID() {
        let a = TrackIdentity(payload: payload(title: "X", artist: "A", id: nil))
        let b = TrackIdentity(payload: payload(title: "X", artist: "A", id: nil))
        let c = TrackIdentity(payload: payload(title: "Z", artist: "A", id: nil))
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - The rule this type exists for

    @Test func artworkIsRememberedForTheTrack() {
        var cache = MediaArtworkCache()
        let p = payload(artwork: art)
        cache.absorb(p)

        #expect(cache.artwork(for: TrackIdentity(payload: p)) == art)
    }

    /// The whole point. A later payload for the SAME track with no artwork
    /// must not erase what we already have.
    @Test func aLaterPayloadWithoutArtworkDoesNotClearIt() {
        var cache = MediaArtworkCache()
        cache.absorb(payload(artwork: art))
        cache.absorb(payload(artwork: nil))

        #expect(cache.artwork(for: TrackIdentity(payload: payload())) == art)
    }

    /// Replays the exact sequence the spike measured.
    @Test func theObservedFlapSequenceKeepsTheArtwork() {
        var cache = MediaArtworkCache()
        for present in [true, false, false, true, true, false, true] {
            cache.absorb(payload(artwork: present ? art : nil))
        }
        #expect(cache.artwork(for: TrackIdentity(payload: payload())) == art)
    }

    /// A different track legitimately has different art, and must not
    /// inherit the previous track's.
    @Test func aDifferentTrackDoesNotInheritArtwork() {
        var cache = MediaArtworkCache()
        cache.absorb(payload(id: "one", artwork: art))

        #expect(cache.artwork(for: TrackIdentity(payload: payload(id: "two"))) == nil)
    }

    /// Fresh artwork for a track we already know replaces the old — album
    /// art can legitimately change resolution mid-playback.
    @Test func newerArtworkForTheSameTrackReplacesIt() {
        var cache = MediaArtworkCache()
        let bigger = Data(repeating: 9, count: 2048)
        cache.absorb(payload(artwork: art))
        cache.absorb(payload(artwork: bigger))

        #expect(cache.artwork(for: TrackIdentity(payload: payload())) == bigger)
    }

    // MARK: - Bounds

    @Test func theCacheIsBounded() {
        var cache = MediaArtworkCache()
        for i in 0...(MediaArtworkCache.capacity + 3) {
            cache.absorb(payload(id: "track-\(i)", artwork: art))
        }
        #expect(cache.count <= MediaArtworkCache.capacity)
    }

    @Test func theOldestEntryIsEvicted() {
        var cache = MediaArtworkCache()
        for i in 0..<MediaArtworkCache.capacity {
            cache.absorb(payload(id: "track-\(i)", artwork: art))
        }
        cache.absorb(payload(id: "newest", artwork: art))

        #expect(cache.artwork(for: TrackIdentity(payload: payload(id: "newest"))) == art)
        #expect(cache.artwork(for: TrackIdentity(payload: payload(id: "track-0"))) == nil)
    }

    /// One absurd image must not become the app's memory profile.
    @Test func anOverSizedImageIsRefused() {
        var cache = MediaArtworkCache()
        let huge = Data(repeating: 1, count: MediaArtworkCache.maxEntryBytes + 1)
        cache.absorb(payload(artwork: huge))

        #expect(cache.artwork(for: TrackIdentity(payload: payload())) == nil)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter MediaArtworkCacheTests`
Expected: FAIL — `cannot find 'TrackIdentity' in scope`.

- [ ] **Step 3: Write `TrackIdentity`**

Create `Sources/CreativeNotchCore/Media/TrackIdentity.swift`:

```swift
import Foundation

/// What makes two payloads "the same track".
///
/// `contentID` when the player supplies one — it survives the title
/// changing case or gaining a suffix mid-stream. Title and artist are the
/// fallback, because not every player provides an id, and without a
/// fallback every payload would look like a new track and the artwork
/// cache would never hit.
public struct TrackIdentity: Hashable, Sendable {

    public let key: String

    public init(payload: MediaPayload) {
        if let id = payload.contentID, !id.isEmpty {
            key = "id:\(id)"
        } else {
            key = "ta:\(payload.title)\u{1F}\(payload.artist)"
        }
    }
}
```

The separator is `U+001F` (unit separator) rather than a printable
character, so a title containing the separator cannot forge a collision
with a different artist.

- [ ] **Step 4: Write `MediaArtworkCache`**

Create `Sources/CreativeNotchCore/Media/MediaArtworkCache.swift`:

```swift
import Foundation

/// Artwork, remembered per track.
///
/// **Absorbing a payload with no artwork never clears what is stored.**
/// The spike measured artwork flapping present/absent across consecutive
/// emissions for one unchanged song — `138061 → 0 → 0 → 138061 → 138061 →
/// 0 → 138061`. Clearing on omission would flicker the album cover several
/// times per play/pause, and the cause would be invisible from the UI code
/// where the symptom appears.
///
/// Bounded on both axes: a handful of recent tracks, and a ceiling per
/// image. Artwork is the only unbounded thing the helper can hand us.
public struct MediaArtworkCache: Equatable, Sendable {

    /// Enough to cover skipping back and forth through a few tracks.
    public static let capacity = 8

    /// 5 MB. Real cover art is tens to hundreds of kilobytes; anything at
    /// this size is a bug somewhere upstream, not a picture worth showing.
    public static let maxEntryBytes = 5_000_000

    private var entries: [(identity: TrackIdentity, artwork: Data)] = []

    public init() {}

    public var count: Int { entries.count }

    public static func == (lhs: MediaArtworkCache, rhs: MediaArtworkCache) -> Bool {
        lhs.entries.map(\.identity) == rhs.entries.map(\.identity)
            && lhs.entries.map(\.artwork) == rhs.entries.map(\.artwork)
    }

    /// Takes whatever this payload offers, and keeps everything it does not.
    public mutating func absorb(_ payload: MediaPayload) {
        guard let artwork = payload.artwork,
              !artwork.isEmpty,
              artwork.count <= Self.maxEntryBytes
        else { return }   // <- the never-clear rule, in one `return`

        let identity = TrackIdentity(payload: payload)
        entries.removeAll { $0.identity == identity }
        entries.append((identity, artwork))

        while entries.count > Self.capacity {
            entries.removeFirst()
        }
    }

    public func artwork(for identity: TrackIdentity) -> Data? {
        entries.last { $0.identity == identity }?.artwork
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter MediaArtworkCacheTests`
Expected: PASS, 10 tests.

- [ ] **Step 6: Prove the tests bite**

Change the `guard` in `absorb` so a payload with no artwork removes the entry (`entries.removeAll { $0.identity == identity }` before returning). Build, run `swift test --filter MediaArtworkCacheTests`. Expected: `aLaterPayloadWithoutArtworkDoesNotClearIt` and `theObservedFlapSequenceKeepsTheArtwork` fail. Revert. **This is the single most important mutation in the plan** — it reproduces the flicker bug exactly.

Change `entries.removeFirst()` to `entries.removeLast()`. Build, run again. Expected: `theOldestEntryIsEvicted` fails. Revert.

Delete the `artwork.count <= Self.maxEntryBytes` condition. Build, run again. Expected: `anOverSizedImageIsRefused` fails. Revert.

- [ ] **Step 7: Run the full suite**

Run: `swift test`
Expected: PASS, 421 tests.

- [ ] **Step 8: Commit**

```bash
git add Sources/CreativeNotchCore/Media Tests/CreativeNotchCoreTests/MediaArtworkCacheTests.swift
git commit -m "feat: cache artwork by track identity, never clearing on omission"
```

---

### Task 5: `MediaCoalescer` and `HelperBackoff`

Two small pure policies, batched because each is a handful of lines and neither needs its own review surface.

**Files:**
- Create: `Sources/CreativeNotchCore/Media/MediaCoalescer.swift`
- Create: `Sources/CreativeNotchCore/Media/HelperBackoff.swift`
- Create: `Tests/CreativeNotchCoreTests/MediaCoalescerTests.swift`
- Create: `Tests/CreativeNotchCoreTests/HelperBackoffTests.swift`

**Interfaces:**
- Consumes: `MediaPayload` (Task 2), `TrackSnapshot` (existing).
- Produces:
  - `struct MediaCoalescer: Equatable, Sendable` with `init()`, `mutating func accept(_ snapshot: TrackSnapshot?) -> Bool`
  - `enum HelperBackoff` with `static let maxAttempts = 5`, `static let cap: TimeInterval = 30`, `static func delay(forAttempt: Int) -> TimeInterval?`
  - `MediaPayload.snapshot: TrackSnapshot?`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CreativeNotchCoreTests/MediaCoalescerTests.swift`:

```swift
import Foundation
import Testing
@testable import CreativeNotchCore

/// Collapses the notification burst.
///
/// The spike measured about six emissions for a single press of play.
/// Passing all of them through would rebuild the header and restart peek
/// arbitration six times for one user action. Same problem `HUDCoalescer`
/// solves for CoreAudio.
///
/// Deduping on `TrackSnapshot` equality is what makes this cheap — artwork
/// lives in the cache, not in the snapshot, so equality never compares
/// image bytes.
struct MediaCoalescerTests {

    private func snap(_ title: String, playing: Bool = true) -> TrackSnapshot {
        TrackSnapshot(title: title, artist: "A", isPlaying: playing)
    }

    @Test func theFirstSnapshotIsAlwaysAccepted() {
        var c = MediaCoalescer()
        #expect(c.accept(snap("one")))
    }

    @Test func anIdenticalRepeatIsDropped() {
        var c = MediaCoalescer()
        #expect(c.accept(snap("one")))
        #expect(c.accept(snap("one")) == false)
    }

    /// The measured burst: six identical emissions, one visible update.
    @Test func aBurstOfIdenticalEmissionsCollapsesToOne() {
        var c = MediaCoalescer()
        let accepted = (0..<6).filter { _ in c.accept(snap("same")) }.count
        #expect(accepted == 1)
    }

    @Test func aChangedTrackIsAccepted() {
        var c = MediaCoalescer()
        _ = c.accept(snap("one"))
        #expect(c.accept(snap("two")))
    }

    /// Play/pause on the same track is a real change the user is waiting
    /// to see — it must not be swallowed as a duplicate.
    @Test func aPlayStateChangeOnTheSameTrackIsAccepted() {
        var c = MediaCoalescer()
        _ = c.accept(snap("one", playing: true))
        #expect(c.accept(snap("one", playing: false)))
    }

    /// Media stopping entirely is a transition, and repeats of it are not.
    @Test func nilIsAcceptedOnceThenDeduped() {
        var c = MediaCoalescer()
        _ = c.accept(snap("one"))
        #expect(c.accept(nil))
        #expect(c.accept(nil) == false)
    }
}
```

Create `Tests/CreativeNotchCoreTests/HelperBackoffTests.swift`:

```swift
import Foundation
import Testing
@testable import CreativeNotchCore

/// How hard to try before giving up on the helper.
///
/// Spec section 5: 1s doubling to a 30s cap, five attempts, then degrade
/// to controls-only. Pure arithmetic so the whole policy is provable
/// without waiting.
struct HelperBackoffTests {

    @Test func thePolicyIsWhatTheSpecSays() {
        #expect(HelperBackoff.maxAttempts == 5)
        #expect(HelperBackoff.cap == 30)
    }

    @Test func itDoublesFromOneSecond() {
        #expect(HelperBackoff.delay(forAttempt: 1) == 1)
        #expect(HelperBackoff.delay(forAttempt: 2) == 2)
        #expect(HelperBackoff.delay(forAttempt: 3) == 4)
        #expect(HelperBackoff.delay(forAttempt: 4) == 8)
        #expect(HelperBackoff.delay(forAttempt: 5) == 16)
    }

    /// Past the last attempt there is no delay because there is no retry —
    /// `nil` is the signal to degrade, not "retry immediately".
    @Test func pastTheLastAttemptThereIsNoDelay() {
        #expect(HelperBackoff.delay(forAttempt: 6) == nil)
        #expect(HelperBackoff.delay(forAttempt: 99) == nil)
    }

    /// Guards the cap even though the doubling sequence does not reach it
    /// within five attempts — the cap must hold if `maxAttempts` is ever
    /// raised.
    @Test func theDelayNeverExceedsTheCap() {
        for attempt in 1...HelperBackoff.maxAttempts {
            if let d = HelperBackoff.delay(forAttempt: attempt) {
                #expect(d <= HelperBackoff.cap)
            }
        }
    }

    @Test func attemptZeroOrNegativeIsNonsenseAndYieldsNil() {
        #expect(HelperBackoff.delay(forAttempt: 0) == nil)
        #expect(HelperBackoff.delay(forAttempt: -1) == nil)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter "MediaCoalescerTests|HelperBackoffTests"`
Expected: FAIL — types not in scope.

- [ ] **Step 3: Write both implementations**

Create `Sources/CreativeNotchCore/Media/MediaCoalescer.swift`:

```swift
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
```

Create `Sources/CreativeNotchCore/Media/HelperBackoff.swift`:

```swift
import Foundation

/// How long to wait before restarting the helper, and when to stop trying.
///
/// The helper is a subprocess talking to a private framework; it failing is
/// ordinary rather than exceptional. Retrying forever would be a crash loop
/// nobody notices, so this gives up — and giving up is safe, because
/// transport controls need none of this and keep working.
public enum HelperBackoff {

    public static let maxAttempts = 5

    /// Nothing waits longer than this, however `maxAttempts` changes.
    public static let cap: TimeInterval = 30

    /// The delay before `attempt`, or `nil` when there is no attempt left.
    ///
    /// `nil` means **degrade**, not "retry immediately" — the caller must
    /// not treat an absent delay as zero.
    public static func delay(forAttempt attempt: Int) -> TimeInterval? {
        guard attempt >= 1, attempt <= maxAttempts else { return nil }
        return min(pow(2, Double(attempt - 1)), cap)
    }
}
```

Add to `MediaPayload` (Task 2's file):

```swift
    /// The part of this payload the rest of the app models.
    ///
    /// `isPlaying` comes from the payload's own playback rate rather than
    /// from notification ordering — the spike saw `playing` lag the real
    /// state in the first notifications after a change.
    ///
    /// A payload with no title describes no track: that is how "nothing is
    /// playing" arrives, and it becomes `nil` rather than an empty header.
    public var snapshot: TrackSnapshot? {
        guard !title.isEmpty || !artist.isEmpty else { return nil }
        return TrackSnapshot(title: title, artist: artist, isPlaying: isPlaying)
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter "MediaCoalescerTests|HelperBackoffTests"`
Expected: PASS, 11 tests.

- [ ] **Step 5: Prove the tests bite**

Change `MediaCoalescer.last` to a plain `TrackSnapshot?`. Build, run the coalescer tests. Expected: `nilIsAcceptedOnceThenDeduped` fails — the doubled optional is load-bearing. Revert.

Change `delay(forAttempt:)`'s guard to `attempt >= 1` only. Build, run the backoff tests. Expected: `pastTheLastAttemptThereIsNoDelay` fails. Revert.

- [ ] **Step 6: Run the full suite**

Run: `swift test`
Expected: PASS, 432 tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/CreativeNotchCore/Media Tests/CreativeNotchCoreTests/MediaCoalescerTests.swift Tests/CreativeNotchCoreTests/HelperBackoffTests.swift
git commit -m "feat: coalesce media updates and bound helper restarts"
```

---

### Task 6: The bridge, the helper script, and the bundle

The only non-Swift code in the repo, and the only task the Swift test suite cannot reach at all.

⚠️ **Read `docs/research/2026-08-29-media-metadata-feasibility.md` in full before starting.** It records three traps that each produce a wrong conclusion, and one of them — doing the work in a `constructor` — reads exactly like the technique not working.

**Files:**
- Create: `Sources/CreativeNotchMediaBridge/bridge.m`
- Create: `Sources/CreativeNotchMediaBridge/include/bridge.h`
- Create: `Resources/media-helper.pl`
- Modify: `Package.swift`
- Modify: `Scripts/bundle.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: a signed `libCreativeNotchMediaBridge.dylib` in `Contents/Frameworks/` and `media-helper.pl` in `Contents/Resources/`, emitting NDJSON matching `MediaPayload`'s `CodingKeys` exactly: `title`, `artist`, `album`, `playing`, `contentID`, `artwork` (base64).

- [ ] **Step 1: Write the bridge**

Create `Sources/CreativeNotchMediaBridge/include/bridge.h`:

```c
#ifndef CREATIVENOTCH_MEDIA_BRIDGE_H
#define CREATIVENOTCH_MEDIA_BRIDGE_H

/// Entry point, installed into perl as an XSUB.
///
/// The two arguments are perl's threaded calling convention (`pTHX_ CV*`)
/// and are ignored — we never touch perl's stack, which is what lets this
/// build without perl's headers.
void cn_media_stream(void *interp_unused, void *cv_unused);

#endif
```

Create `Sources/CreativeNotchMediaBridge/bridge.m`. Requirements, each with its reason:

- Do the work in `cn_media_stream`, **never in a `__attribute__((constructor))`**. A constructor runs during `dlopen` under dyld's loader lock, and MediaRemote's XPC callback cannot complete there — it times out, and the result is indistinguishable from the gate refusing you.
- `dlopen` MediaRemote by absolute path; resolve `MRMediaRemoteGetNowPlayingInfo` and `MRMediaRemoteRegisterForNowPlayingNotifications`.
- Register for notifications, then observe `kMRMediaRemoteNowPlayingInfoDidChangeNotification` and `kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification`.
- Emit one JSON object per line on **stdout**, `fflush` after each. Diagnostics go to **stderr** only.
- **Escape JSON properly.** Build the object with `NSJSONSerialization`, not `printf`. Titles contain quotes, backslashes, newlines and emoji; a hand-rolled formatter produces invalid JSON on real music.
- `playing` comes from `kMRMediaRemoteNowPlayingInfoPlaybackRate > 0`.
- `artwork` is base64 of `kMRMediaRemoteNowPlayingInfoArtworkData`, omitted entirely when absent.
- Emit once immediately on start, so a freshly spawned helper reports current state rather than waiting for a change.
- Run `CFRunLoopRun()` — **indefinitely**. The spike's 12-second bound was scaffolding and must not survive.
- Exit cleanly when stdin closes (the parent died): install a `dispatch_source` on `STDIN_FILENO` and `exit(0)` on EOF. **This is the orphan-prevention mechanism** — without it a helper outlives the app that spawned it.

Create `Resources/media-helper.pl`:

```perl
#!/usr/bin/perl
# The helper CreativeNotch spawns to read now-playing metadata.
#
# It exists only to be an Apple-signed host process. `mediaremoted` gates
# metadata reads on the CALLING process's code-signing identifier, and
# /usr/bin/perl is signed com.apple.perl. The app itself, signed
# com.gcdz.creativenotch, gets nothing. A dylib loaded here inherits
# perl's exemption — that is the whole mechanism.
use strict;
use warnings;
require DynaLoader;

my $dylib = shift @ARGV
    or die "usage: media-helper.pl /absolute/path/to/dylib\n";

# /usr/bin/perl is a HARDENED program, which rejects relative dylib paths
# outright ("relative path not allowed in hardened program"). Checking here
# turns a confusing dyld error into an obvious one.
die "dylib path must be absolute, got: $dylib\n" unless $dylib =~ m{^/};
die "dylib not found: $dylib\n" unless -e $dylib;

my $lib = DynaLoader::dl_load_file($dylib, 0)
    or die "dl_load_file failed: " . DynaLoader::dl_error() . "\n";
my $sym = DynaLoader::dl_find_symbol($lib, "cn_media_stream")
    or die "symbol 'cn_media_stream' not found in $dylib\n";

DynaLoader::dl_install_xsub("main::cn_media_stream", $sym);

$| = 1;    # unbuffered, so the parent sees each line as it is emitted
cn_media_stream();
```

- [ ] **Step 2: Add the target to `Package.swift`**

```swift
    products: [
        // Loaded at runtime by the perl helper; nothing links it.
        .library(name: "CreativeNotchMediaBridge", type: .dynamic,
                 targets: ["CreativeNotchMediaBridge"]),
    ],
```

and among the targets:

```swift
        .target(
            name: "CreativeNotchMediaBridge",
            linkerSettings: [.linkedFramework("Foundation")]
        ),
```

Do **not** add it as a dependency of any Swift target.

- [ ] **Step 3: Ship it from `bundle.sh`**

After the existing resource copies:

```bash
# The dylib goes in Frameworks/, not Resources/. codesign seals
# Frameworks/ as nested *code*; a dylib in Resources/ is sealed as an
# opaque resource, and loading it later breaks validation.
mkdir -p "$APP/Contents/Frameworks"
cp "$(swift build -c "$CONFIG" --show-bin-path)/libCreativeNotchMediaBridge.dylib" \
   "$APP/Contents/Frameworks/libCreativeNotchMediaBridge.dylib"
cp "$ROOT/Resources/media-helper.pl" "$APP/Contents/Resources/media-helper.pl"
```

and, immediately before the existing `codesign` of `$APP`:

```bash
# Inside out: nested code must be signed BEFORE the bundle containing it,
# or the outer signature seals unsigned code.
codesign -s "$IDENTITY" --force --timestamp=none \
  "$APP/Contents/Frameworks/libCreativeNotchMediaBridge.dylib"
```

- [ ] **Step 4: Verify the build and the signature**

```bash
swift build
./Scripts/bundle.sh debug
codesign --verify --deep --strict --verbose=2 dist/CreativeNotch.app
```

Expected: `valid on disk`, `satisfies its Designated Requirement`, and the dylib listed as `--validated`. (`spctl` still rejects the bundle — it is not notarised. Pre-existing, documented in the README, not a regression.)

- [ ] **Step 5: Verify the helper end to end by hand**

The Swift suite cannot reach any of this. With music playing:

```bash
APP="$(pwd)/dist/CreativeNotch.app"
/usr/bin/perl "$APP/Contents/Resources/media-helper.pl" \
              "$APP/Contents/Frameworks/libCreativeNotchMediaBridge.dylib"
```

Confirm all of:
1. A JSON line appears **immediately**, before any change.
2. Its keys are exactly `title`, `artist`, `album`, `playing`, `contentID`, `artwork` — matching `MediaPayload`'s `CodingKeys`. A mismatch here is silent: payloads decode with empty fields.
3. Pressing play/pause emits further lines and `playing` flips.
4. A track whose title contains a quote or emoji still produces **valid JSON** — pipe through `python3 -m json.tool` to confirm.
5. `Ctrl-C`, then `pgrep -f media-helper` returns nothing.
6. Run it again and close its stdin (`… < /dev/null`): it exits rather than hanging.

Record the actual first line in your report — it becomes the fixture for later tasks.

- [ ] **Step 6: Run the full suite**

Run: `swift test`
Expected: PASS, 432 tests — unchanged. This task adds no Swift code.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: add the perl media helper and its bridge"
```

---

### Task 7: `MediaHelperProcess` — spawn and read

**Files:**
- Create: `Sources/CreativeNotchUI/Media/MediaHelperProcess.swift`
- Create: `Tests/CreativeNotchUITests/MediaHelperProcessTests.swift`

**Interfaces:**
- Consumes: `LineBuffer` (Task 3).
- Produces:
  - `@MainActor final class MediaHelperProcess` with `init()`, `var onLine: ((String) -> Void)?`, `var onExit: ((Int32) -> Void)?`, `static var bundledPaths: (script: String, dylib: String)?`, `static var isAvailable: Bool`, `var isRunning: Bool`, `func start()`, `func stop()`, and internal `func ingest(_ chunk: String)`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CreativeNotchUITests/MediaHelperProcessTests.swift`:

```swift
import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// Spawning the helper and reading its output.
///
/// **No test here starts a real process.** `Process` must not appear in
/// this file. What is tested is `ingest` — the seam between the pipe and
/// the rest of the app — driven directly with the chunks a real
/// `readabilityHandler` would deliver. The real spawn is verified by hand
/// in Task 6 and Task 10.
@MainActor
struct MediaHelperProcessTests {

    @Test func aWholeLineIsForwarded() {
        let helper = MediaHelperProcess()
        var lines: [String] = []
        helper.onLine = { lines.append($0) }

        helper.ingest("{\"title\":\"x\"}\n")

        #expect(lines == ["{\"title\":\"x\"}"])
    }

    /// Artwork makes payloads far larger than a pipe buffer, so splitting
    /// is the normal case rather than an edge one.
    @Test func aSplitLineIsForwardedOnceComplete() {
        let helper = MediaHelperProcess()
        var lines: [String] = []
        helper.onLine = { lines.append($0) }

        helper.ingest("{\"tit")
        #expect(lines.isEmpty)
        helper.ingest("le\":\"x\"}\n")

        #expect(lines == ["{\"title\":\"x\"}"])
    }

    @Test func severalLinesInOneChunkAllForward() {
        let helper = MediaHelperProcess()
        var count = 0
        helper.onLine = { _ in count += 1 }

        helper.ingest("a\nb\nc\n")

        #expect(count == 3)
    }

    /// A restart must not glue the dead helper's half-line onto the new
    /// one's first line — that corrupts exactly one payload per restart.
    @Test func stoppingDiscardsAPartialLine() {
        let helper = MediaHelperProcess()
        var lines: [String] = []
        helper.onLine = { lines.append($0) }

        helper.ingest("half")
        helper.stop()
        helper.ingest("rest\n")

        #expect(lines == ["rest"])
    }

    /// In a test run or under `swift run` there is no app bundle, so the
    /// paths are absent and the module must report unavailable rather than
    /// spawning something wrong.
    @Test func availabilityFollowsTheBundledPaths() {
        #expect(MediaHelperProcess.isAvailable == (MediaHelperProcess.bundledPaths != nil))
    }

    @Test func aFreshHelperIsNotRunning() {
        #expect(MediaHelperProcess().isRunning == false)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter MediaHelperProcessTests`
Expected: FAIL — `cannot find 'MediaHelperProcess' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/CreativeNotchUI/Media/MediaHelperProcess.swift`. Requirements:

- `bundledPaths` resolves `Contents/Resources/media-helper.pl` and `Contents/Frameworks/libCreativeNotchMediaBridge.dylib` from `Bundle.main`, returning `nil` unless **both** exist. Under `swift test` and `swift run` there is no such bundle, which is what keeps tests from spawning anything.
- Pass the dylib path **absolute** — perl is hardened and rejects relative paths.
- `start()` runs `/usr/bin/perl` with `[script, dylib]`, pipes stdout, and sets a `readabilityHandler` that decodes UTF-8 and calls `ingest`.
- `ingest(_:)` is internal, feeds `LineBuffer`, and calls `onLine` per complete line. **This is the only method tests touch.**
- stderr is drained to avoid filling the pipe and blocking the child, and is **never** forwarded to `onLine` — it is diagnostics, not payload. Do not log its contents; it may quote a track title.
- `terminationHandler` clears handlers and calls `onExit`.
- `stop()` terminates, waits, clears the handler, and **resets the line buffer**.
- No timer anywhere in this file.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter MediaHelperProcessTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Prove the tests bite**

Remove the `buffer.reset()` from `stop()`. Build, run the tests. Expected: `stoppingDiscardsAPartialLine` fails. Revert.

Make `bundledPaths` return a tuple unconditionally. Build, run again. Expected: `availabilityFollowsTheBundledPaths` still passes (both sides move together), so **this mutation does not bite** — say so in your report rather than claiming otherwise.

- [ ] **Step 6: Confirm no test spawns a process**

```bash
grep -rn "Process(" Tests/ || echo "clean"
```
Expected: `clean`.

- [ ] **Step 7: Run the full suite and commit**

```bash
swift test
git add Sources/CreativeNotchUI/Media Tests/CreativeNotchUITests/MediaHelperProcessTests.swift
git commit -m "feat: spawn the media helper and read its stream"
```

Expected: PASS, 438 tests.

---

### Task 8: `MediaHelperSupervisor` — restart, then give up

**Files:**
- Create: `Sources/CreativeNotchUI/Media/MediaHelperSupervisor.swift`
- Create: `Tests/CreativeNotchUITests/MediaHelperSupervisorTests.swift`

**Interfaces:**
- Consumes: `HelperBackoff` (Task 5), `MediaHelperProcess` (Task 7).
- Produces:
  - `@MainActor final class MediaHelperSupervisor` with `init()`, `var onLine: ((String) -> Void)?`, `var onDegraded: (() -> Void)?`, `var startHelper: () -> Void`, `var stopHelper: () -> Void`, `var scheduleRetry: (TimeInterval, @escaping @MainActor () -> Void) -> Void`, `private(set) var attempt: Int`, `private(set) var isDegraded: Bool`, `func start()`, `func stop()`, `func helperExited(status: Int32)`, `func noteHealthy()`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CreativeNotchUITests/MediaHelperSupervisorTests.swift`:

```swift
import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// Restart policy for a subprocess that is expected to fail sometimes.
///
/// Nothing here sleeps and nothing spawns: the retry scheduler is injected
/// and captured, so the whole policy is asserted by inspecting what was
/// *asked for* — the same shape as `ClipboardPoller`'s injected timer.
@MainActor
struct MediaHelperSupervisorTests {

    private final class Box {
        var starts = 0
        var stops = 0
        var scheduled: [TimeInterval] = []
        var pending: (@MainActor () -> Void)?
        var degraded = false
    }

    private func makeSupervisor() -> (MediaHelperSupervisor, Box) {
        let box = Box()
        let s = MediaHelperSupervisor()
        s.startHelper = { box.starts += 1 }
        s.stopHelper = { box.stops += 1 }
        s.scheduleRetry = { delay, work in
            box.scheduled.append(delay)
            box.pending = work
        }
        s.onDegraded = { box.degraded = true }
        return (s, box)
    }

    @Test func startingStartsTheHelper() {
        let (s, box) = makeSupervisor()
        s.start()
        #expect(box.starts == 1)
    }

    @Test func anUnexpectedExitSchedulesARetryAtTheFirstDelay() {
        let (s, box) = makeSupervisor()
        s.start()
        s.helperExited(status: 1)

        #expect(box.scheduled == [HelperBackoff.delay(forAttempt: 1)])
        #expect(box.starts == 1, "the retry has not fired yet")
    }

    @Test func theScheduledRetryStartsTheHelperAgain() {
        let (s, box) = makeSupervisor()
        s.start()
        s.helperExited(status: 1)
        box.pending?()

        #expect(box.starts == 2)
    }

    @Test func delaysFollowTheBackoffSchedule() {
        let (s, box) = makeSupervisor()
        s.start()
        for _ in 1...HelperBackoff.maxAttempts {
            s.helperExited(status: 1)
            box.pending?()
        }
        #expect(box.scheduled == (1...HelperBackoff.maxAttempts).compactMap {
            HelperBackoff.delay(forAttempt: $0)
        })
    }

    /// Giving up is a feature: transport controls need none of this and
    /// keep working, so a permanent retry loop would burn power for a
    /// capability the user is not getting.
    @Test func exhaustingTheAttemptsDegradesInsteadOfRetryingForever() {
        let (s, box) = makeSupervisor()
        s.start()
        for _ in 1...(HelperBackoff.maxAttempts + 1) {
            s.helperExited(status: 1)
            box.pending?()
        }

        #expect(box.degraded)
        #expect(s.isDegraded)
        #expect(box.scheduled.count == HelperBackoff.maxAttempts)
    }

    /// A helper that ran fine and then died much later is not the fifth
    /// failure of a crash loop; the counter resets on a healthy run.
    @Test func aSuccessfulRunResetsTheAttemptCount() {
        let (s, _) = makeSupervisor()
        s.start()
        s.helperExited(status: 1)
        #expect(s.attempt == 1)

        s.noteHealthy()
        #expect(s.attempt == 0)
    }

    /// A deliberate stop must not look like a crash and trigger a restart.
    @Test func stoppingDoesNotScheduleARetry() {
        let (s, box) = makeSupervisor()
        s.start()
        s.stop()
        s.helperExited(status: 0)

        #expect(box.scheduled.isEmpty)
        #expect(box.stops == 1)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter MediaHelperSupervisorTests`
Expected: FAIL — type not in scope.

- [ ] **Step 3: Write the implementation**

Create `Sources/CreativeNotchUI/Media/MediaHelperSupervisor.swift`. Requirements:

- Injected `startHelper`, `stopHelper`, `scheduleRetry` — defaults use the real `MediaHelperProcess` and `DispatchQueue.main.asyncAfter`. **Not a `Timer`**: the no-polling constraint bans repeating timers, and a one-shot delayed dispatch is not one.
- Also expose `noteHealthy()`, which resets `attempt` — the controller calls it once the helper has produced a line, so a long-lived helper dying later starts a fresh budget rather than tripping the cap.
- `stop()` sets a flag so the subsequent exit is not treated as a crash.
- On degrading: call `onDegraded`, set `isDegraded`, and never schedule again.

- [ ] **Step 4: Run the tests, prove they bite, run the suite**

Run: `swift test --filter MediaHelperSupervisorTests` — expect PASS, 7 tests.

Mutation: delete the deliberate-stop flag so `stop()` is followed by a retry. Build, run. Expected: `stoppingDoesNotScheduleARetry` fails. Revert.

Mutation: allow scheduling past `maxAttempts`. Build, run. Expected: `exhaustingTheAttemptsDegradesInsteadOfRetryingForever` fails. Revert.

Run: `swift test` — expect PASS, 445 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/CreativeNotchUI/Media/MediaHelperSupervisor.swift Tests/CreativeNotchUITests/MediaHelperSupervisorTests.swift
git commit -m "feat: supervise the media helper with bounded restarts"
```

---

### Task 9: `MediaController` — the judgement layer

Mirrors `HUDController` and `ClipboardController`: the sources are dumb, and everything connecting them lives here where a test can drive it.

**Files:**
- Create: `Sources/CreativeNotchUI/Media/MediaController.swift`
- Create: `Tests/CreativeNotchUITests/MediaControllerTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 2–8.
- Produces:
  - `@MainActor final class MediaController` with `init()`, `private(set) var snapshot: TrackSnapshot?`, `func artwork(for: TrackSnapshot) -> Data?`, `var onChange: ((TrackSnapshot?) -> Void)?`, `func start()`, `func stop()`, `func setActivity(_:)`, and internal `func handle(line: String)`, `let supervisor: MediaHelperSupervisor`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CreativeNotchUITests/MediaControllerTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail, then implement**

Run: `swift test --filter MediaControllerTests` — expect FAIL, type not in scope.

Create `Sources/CreativeNotchUI/Media/MediaController.swift`. Requirements:

- Owns `MediaHelperSupervisor`, a `MediaCoalescer`, and a `MediaArtworkCache`.
- `handle(line:)`: decode → absorb artwork into the cache **before** coalescing (artwork must be stored even when the snapshot is unchanged) → coalesce → publish via `onChange` when accepted.
- Call `supervisor.noteHealthy()` on the first successfully decoded line of a run.
- `setActivity(_:)` starts the helper on `.active` and stops it otherwise.
- Never log payload contents.

- [ ] **Step 3: Run the tests, prove they bite, run the suite**

Expect PASS, 8 tests.

Mutation: absorb artwork *after* the coalescer instead of before. Build, run. Expected: `artworkSurvivesPayloadsThatOmitIt` fails — artwork arriving in an otherwise-identical payload would be dropped. Revert.

Mutation: publish on every line rather than only when the coalescer accepts. Build, run. Expected: `aBurstOfIdenticalLinesPublishesOnce` fails. Revert.

Run: `swift test` — expect PASS, 453 tests.

- [ ] **Step 4: Commit**

```bash
git add Sources/CreativeNotchUI/Media/MediaController.swift Tests/CreativeNotchUITests/MediaControllerTests.swift
git commit -m "feat: turn the helper's stream into now-playing state"
```

---

### Task 10: The header, the peek, and the app

**Files:**
- Create: `Sources/CreativeNotchUI/Media/NowPlayingView.swift`
- Create: `Tests/CreativeNotchUITests/NowPlayingTests.swift`
- Modify: `Sources/CreativeNotchUI/NotchRootView.swift`
- Modify: `Sources/CreativeNotchUI/AppDelegate.swift`
- Modify: `Tests/CreativeNotchCoreTests/CorePurityTests.swift`
- Modify: `README.md`

**Interfaces:**
- Produces:
  - `NowPlayingLabel.text(for: TrackSnapshot) -> String`
  - `struct NowPlayingView: View`
  - `AppState.nowPlaying: TrackSnapshot?`, `AppState.nowPlayingArtwork: Data?`, `AppDelegate.media: MediaController?` (internal), `AppDelegate.arbiter` widened from private to internal

- [ ] **Step 1: Write the failing tests**

Create `Tests/CreativeNotchUITests/NowPlayingTests.swift`:

```swift
import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// Views are not unit-tested here, so the pure formatting they lean on is
/// pulled out and tested instead — plus the wiring that makes the module
/// reachable at all.
@MainActor
struct NowPlayingTests {

    private static let notched = ScreenMetrics(
        frame: CGRect(x: 1470, y: 200, width: 1470, height: 956),
        safeAreaTopInset: 38,
        auxiliaryTopLeftWidth: 620,
        auxiliaryTopRightWidth: 620,
        menuBarHeight: 38
    )

    private func makeDelegate() -> AppDelegate {
        let delegate = AppDelegate()
        delegate.growthDelay = .zero
        delegate.shelfDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CreativeNotchNowPlaying-\(UUID().uuidString)")
        delegate.install(metrics: Self.notched)
        return delegate
    }

    @Test func titleAndArtistAreJoined() {
        let s = TrackSnapshot(title: "Beauty And A Beat", artist: "Justin Bieber", isPlaying: true)
        #expect(NowPlayingLabel.text(for: s) == "Beauty And A Beat — Justin Bieber")
    }

    /// Some tracks genuinely have no artist — podcasts, voice memos. A
    /// dangling separator would look broken.
    @Test func aMissingArtistDropsTheSeparator() {
        let s = TrackSnapshot(title: "Some Episode", artist: "", isPlaying: true)
        #expect(NowPlayingLabel.text(for: s) == "Some Episode")
    }

    @Test func installingCreatesTheMediaController() {
        #expect(makeDelegate().media != nil)
    }

    /// The panel header reads this; left unwired it would always be empty.
    @Test func theControllerPublishesIntoAppState() throws {
        let delegate = makeDelegate()
        let media = try #require(delegate.media)
        media.handle(line: #"{"title":"X","artist":"Y","album":"","playing":true,"contentID":"i"}"#)

        #expect(delegate.state.nowPlaying?.title == "X")
    }

    /// The ambient peek is the scope decision this module was built for:
    /// playing media must reach the arbiter, or hovering shows nothing.
    @Test func playingMediaReachesThePeekArbiter() throws {
        let delegate = makeDelegate()
        let media = try #require(delegate.media)
        media.handle(line: #"{"title":"X","artist":"Y","album":"","playing":true,"contentID":"i"}"#)

        #expect(delegate.arbiter.content(now: 0) == .nowPlaying(
            TrackSnapshot(title: "X", artist: "Y", isPlaying: true)
        ))
    }

    /// Paused media is not ambient content — the notch should be quiet.
    @Test func pausedMediaDoesNotPeek() throws {
        let delegate = makeDelegate()
        let media = try #require(delegate.media)
        media.handle(line: #"{"title":"X","artist":"Y","album":"","playing":false,"contentID":"i"}"#)

        #expect(delegate.arbiter.content(now: 0) == nil)
    }
}
```

`AppDelegate.arbiter` is currently `private`; make it internal so this
test can assert the peek wiring. That is the same reason `hud`, `clipboard`
and `activity` are internal.

- [ ] **Step 2: Run the tests to verify they fail, then implement**

Create `Sources/CreativeNotchUI/Media/NowPlayingView.swift` with `NowPlayingLabel.text(for:)` (title, an em-dash separator only when both parts exist) and `NowPlayingView` rendering artwork at ~28pt beside the label, truncating tail, single line.

In `NotchRootView`, add to `AppState`:

```swift
    /// Set by `MediaController`. Observable — unlike `shelf` and
    /// `clipboard`, which are `@Observable` stores that publish their own
    /// changes, this is a plain value the header reads directly.
    public internal(set) var nowPlaying: TrackSnapshot?
    public internal(set) var nowPlayingArtwork: Data?
```

Render it in the `.open` case, **above** `MediaControlsView`, so the header sits at the top exactly as spec section 2 requires — and remember that "top" means below the anchor, which the existing `.padding(.top, app.anchor.rect.height)` already handles.

In `AppDelegate.install(metrics:)`, create the controller, publish into `AppState`, and feed the arbiter:

```swift
        let media = MediaController()
        media.onChange = { [weak self] snapshot in
            guard let self else { return }
            self.state.nowPlaying = snapshot
            self.state.nowPlayingArtwork = snapshot.flatMap { media.artwork(for: $0) }
            self.arbiter.setNowPlaying(snapshot)
            self.reevaluatePeek()
        }
        self.media = media
```

Extend the existing `activity.onChange` fan-out from Task 1 to also call `media.setActivity(state)`. Start and stop it beside the other modules.

Add `"MediaPayload.swift"` to `CorePurityTests`'s `expectedInSubdirectories`.

- [ ] **Step 3: Run the suite, prove the tests bite**

Run: `swift test` — expect PASS, 459 tests.

Mutation: delete `self.arbiter.setNowPlaying(snapshot)`. Build, run. Expected: `playingMediaReachesThePeekArbiter` fails. Revert.

Mutation: delete the `state.nowPlaying` assignment. Build, run. Expected: `theControllerPublishesIntoAppState` fails. Revert.

- [ ] **Step 4: Verify it works in the real app**

⚠️ **Required, not optional.** Nothing in the suite renders a view or spawns the helper, and the media transport module shipped a layout bug to `main` precisely because this step was skipped.

```bash
./Scripts/dev.sh
```

With music playing, confirm:

1. Open the panel — the title and artist appear **above** the transport buttons, below the notch, not hidden behind it.
2. Artwork appears beside them.
3. Skip tracks — the header follows, and the artwork **does not flicker** on and off. Watch for several seconds; this is the flap the cache exists to hide.
4. Play/pause — the header updates without the whole panel jumping.
5. Close the panel and hover — the ambient peek shows the track.
6. Pause, then hover — the peek is silent.
7. `pkill -f CreativeNotch`, then `pgrep -f media-helper` returns **nothing**. An orphaned helper is the worst outcome available here.
8. Lock the screen, unlock, confirm the header still updates — the activity gate stopped and restarted the helper.

- [ ] **Step 5: Update the documentation and commit**

`README.md`: mark media metadata done, update every test count against a real run (badge, the `swift test` comment, and the per-target breakdown — all three), add a usage row, and note that a `perl` helper process is spawned and why.

```bash
git add -A
git commit -m "feat: show now-playing in the panel and the peek"
```

---

## Definition of done

- [ ] `swift build` succeeds with no warnings.
- [ ] `swift test` passes; the suite has grown from 394 to roughly 459 tests.
- [ ] `CorePurityTests` passes with `MediaPayload.swift` among its anchors.
- [ ] **No test spawns a process** — `grep -rn "Process(" Tests/` is empty.
- [ ] No new `Timer` exists; the clipboard poller is still the only one.
- [ ] No payload content is logged anywhere.
- [ ] `codesign --verify --deep --strict` passes on the built bundle.
- [ ] Every mutation listed was performed, seen to fail, and reverted — with the build confirmed good first. Where a listed mutation does **not** bite, that is recorded rather than glossed.
- [ ] **Task 6 Step 5 and Task 10 Step 4 were actually performed in the running app**, including the orphan check.
- [ ] `README.md` marks the module done and states real test counts in all three places.
- [ ] Spec and research documents match what was built.

## Deliberately not built

- **Scrubbing, a position bar, volume, per-app routing.** All need write access or continuous position polling.
- **Artwork in the peek.** The peek is small and the cache may legitimately be empty when it fires.
- **The now-playing app's icon or identity.** Available through the helper; not worth the surface in v1.
- **Persisting artwork between launches.** It is a cache, and the app starts by asking the helper anyway.
- **A second helper for anything else.** One subprocess is the budget.
