import Foundation
import Testing
@testable import CreativeNotchCore

// MARK: - The exemption, argued exhaustively

private func inputs(
    tab: Bool = false,
    recording: Bool = false,
    enabled: Bool = true,
    activity: SystemActivity = .active
) -> CameraRunReason.Inputs {
    .init(isTabVisible: tab, isRecording: recording, isEnabled: enabled, activity: activity)
}

/// The ordinary case: the tab is open, so the session runs and draws.
@Test func anOpenCameraTabRunsAndPreviews() {
    let open = inputs(tab: true)
    #expect(CameraRunReason.shouldRun(open))
    #expect(CameraRunReason.shouldPreview(open))
    #expect(CameraRunReason.shouldBadge(open) == false)
}

/// Nothing open, nothing recording: nothing runs. This is the state the module
/// spends almost all of its life in.
@Test func aClosedCameraTabRunsNothing() {
    let closed = inputs()
    #expect(CameraRunReason.shouldRun(closed) == false)
    #expect(CameraRunReason.shouldPreview(closed) == false)
}

/// **The exemption.** Press record, click away: the take survives. A stray
/// cursor ending a deliberate recording is the failure this exists to prevent.
@Test func aRecordingSurvivesThePanelClosing() {
    let recording = inputs(tab: false, recording: true)
    #expect(CameraRunReason.shouldRun(recording))
    #expect(CameraRunReason.shouldPreview(recording) == false, "nothing to draw on")
}

/// **And the exemption is honest.** Whenever the session outlives the panel,
/// the ear says so -- a capture running with nothing on screen to account for
/// it is precisely what this project exists to prevent.
@Test func aRecordingThatOutlivesThePanelIsVisibleInTheEar() {
    #expect(CameraRunReason.shouldBadge(inputs(tab: false, recording: true)))
}

/// A locked screen stops the preview but not a recording. Same split as the
/// timer: the drawing is gated, the work is not.
@Test func lockingStopsThePreviewButNotARecording() {
    let lockedIdle = inputs(tab: true, activity: .locked)
    #expect(CameraRunReason.shouldRun(lockedIdle) == false)
    #expect(CameraRunReason.shouldPreview(lockedIdle) == false)

    let lockedRecording = inputs(tab: true, recording: true, activity: .locked)
    #expect(CameraRunReason.shouldRun(lockedRecording))
    #expect(CameraRunReason.shouldPreview(lockedRecording) == false)
}

/// **The preference outranks everything, including a recording.** Flipping the
/// switch is a stronger statement than the cursor moving, and a camera that
/// kept capturing because a recording happened to be running would be the
/// sharpest possible violation of the Preferences rule.
@Test func switchingTheModuleOffStopsEvenARecording() {
    for tab in [true, false] {
        for recording in [true, false] {
            let off = inputs(tab: tab, recording: recording, enabled: false)
            #expect(CameraRunReason.shouldRun(off) == false, "tab=\(tab) recording=\(recording)")
            #expect(CameraRunReason.shouldPreview(off) == false)
            #expect(CameraRunReason.shouldBadge(off) == false)
        }
    }
}

/// All sixteen combinations, stated as a table rather than reasoned about.
/// The rule is small enough to enumerate, and enumerating it is how a later
/// "simplification" gets caught.
@Test func everyCombinationOfTheFourInputsIsPinned() {
    var seen = 0
    for tab in [true, false] {
        for recording in [true, false] {
            for enabled in [true, false] {
                for activity in [SystemActivity.active, .locked] {
                    let i = inputs(tab: tab, recording: recording, enabled: enabled, activity: activity)
                    let expectedRun = enabled && (recording || (tab && activity == .active))
                    let expectedPreview = enabled && tab && activity == .active
                    let expectedBadge = enabled && recording

                    #expect(CameraRunReason.shouldRun(i) == expectedRun)
                    #expect(CameraRunReason.shouldPreview(i) == expectedPreview)
                    #expect(CameraRunReason.shouldBadge(i) == expectedBadge)
                    seen += 1
                }
            }
        }
    }
    #expect(seen == 16)
}

/// The preview is never drawn without the session running behind it -- an
/// invariant that holds across the whole table rather than in the cases
/// somebody thought to write down.
@Test func previewingAlwaysImpliesRunning() {
    for tab in [true, false] {
        for recording in [true, false] {
            for enabled in [true, false] {
                for activity in [SystemActivity.active, .locked] {
                    let i = inputs(tab: tab, recording: recording, enabled: enabled, activity: activity)
                    if CameraRunReason.shouldPreview(i) {
                        #expect(CameraRunReason.shouldRun(i), "previewing without a session")
                    }
                }
            }
        }
    }
}

// MARK: - The arithmetic the roadmap got wrong

/// The roadmap said 16:9 at 620 wide wants 349 points of height and therefore
/// does not fit in 260. Fitting to HEIGHT instead gives 462 x 260, inside 620
/// with 158 to spare.
@Test func sixteenByNineFitsThePanelWhenFittedToHeight() {
    let rect = CameraPreviewFit.fit(
        aspect: CameraPreviewFit.standardAspect,
        in: CGSize(width: 620, height: 260)
    )
    #expect(abs(rect.height - 260) < 0.01)
    #expect(abs(rect.width - 462.22) < 0.5)
    #expect(rect.width <= 620)
}

@Test func aPreviewIsCentredInTheSpaceItHas() {
    let rect = CameraPreviewFit.fit(aspect: 1, in: CGSize(width: 100, height: 40))
    #expect(abs(rect.width - 40) < 0.01)
    #expect(abs(rect.minX - 30) < 0.01)
    #expect(abs(rect.minY - 0) < 0.01)
}

/// Width-limited when the space is narrower than the content, so the same
/// function serves both orientations rather than two that can disagree.
@Test func aNarrowSpaceLimitsByWidthInstead() {
    let rect = CameraPreviewFit.fit(aspect: 16.0 / 9.0, in: CGSize(width: 100, height: 400))
    #expect(abs(rect.width - 100) < 0.01)
    #expect(abs(rect.height - 56.25) < 0.01)
}

@Test func anEmptyOrNonsensicalSpaceFitsNothing() {
    #expect(CameraPreviewFit.fit(aspect: 16.0 / 9.0, in: .zero) == .zero)
    #expect(CameraPreviewFit.fit(aspect: 0, in: CGSize(width: 10, height: 10)) == .zero)
    #expect(CameraPreviewFit.fit(aspect: -1, in: CGSize(width: 10, height: 10)) == .zero)
}

// MARK: - Names that cannot collide

private let noon = Date(timeIntervalSince1970: 1_757_764_800)

/// `AVCaptureFileOutput` fails if the file exists, and it fails
/// ASYNCHRONOUSLY -- so a collision reads as "the clip vanished" rather than
/// as an error at the call site.
@Test func twoCapturesInTheSameSecondGetDifferentNames() {
    let first = CaptureFileNaming.name(for: .still, at: noon, suffix: "a1b2",
                                       timeZone: TimeZone(identifier: "UTC")!)
    let second = CaptureFileNaming.name(for: .still, at: noon, suffix: "c3d4",
                                        timeZone: TimeZone(identifier: "UTC")!)
    #expect(first != second)
}

@Test func aNameCarriesItsKindAndExtension() {
    let still = CaptureFileNaming.name(for: .still, at: noon, suffix: "a1b2",
                                       timeZone: TimeZone(identifier: "UTC")!)
    let clip = CaptureFileNaming.name(for: .clip, at: noon, suffix: "a1b2",
                                      timeZone: TimeZone(identifier: "UTC")!)

    #expect(still.hasPrefix("Photo "))
    #expect(still.hasSuffix(".jpg"))
    #expect(clip.hasPrefix("Clip "))
    #expect(clip.hasSuffix(".mov"))
}

/// The timestamp is the local wall clock, so a file named "at 14.30.00" is the
/// one taken at half past two -- not the same moment in UTC.
@Test func theTimestampIsTheLocalWallClock() {
    let utc = CaptureFileNaming.name(for: .still, at: noon, suffix: "x",
                                     timeZone: TimeZone(identifier: "UTC")!)
    let tokyo = CaptureFileNaming.name(for: .still, at: noon, suffix: "x",
                                       timeZone: TimeZone(identifier: "Asia/Tokyo")!)
    #expect(utc != tokyo)
    #expect(utc.contains("2025-09-13 at 12.00.00"))
}

// MARK: - Clip ceilings

/// An unbounded recording is not merely large: the shelf evicts by trashing
/// real files, so it is a way to lose other things.
@Test func theClipCeilingsAreDocumentedValues() {
    #expect(ClipLimits.maxDuration == 300)
    #expect(ClipLimits.maxBytes == 512 * 1024 * 1024)
}

/// The warning arrives before the stop, so a recording that ends at the limit
/// does not appear to stop for no reason.
@Test func aRecordingWarnsBeforeItReachesTheLimit() {
    #expect(ClipLimits.isNearingLimit(elapsed: 100) == false)
    #expect(ClipLimits.isNearingLimit(elapsed: 269) == false)
    #expect(ClipLimits.isNearingLimit(elapsed: 270))
    #expect(ClipLimits.isNearingLimit(elapsed: 300))
}
