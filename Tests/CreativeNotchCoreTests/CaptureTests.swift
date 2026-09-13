import Foundation
import Testing
@testable import CreativeNotchCore

// MARK: - What the indicator shows

@Test func nothingCapturingShowsNothing() {
    #expect(CaptureIndicator(CaptureUse.none) == .none)
}

@Test func eachDeviceHasItsOwnIndicator() {
    #expect(CaptureIndicator(CaptureUse(microphone: true)) == .microphone)
    #expect(CaptureIndicator(CaptureUse(camera: true)) == .camera)
}

/// Both at once is ONE state, not two badges. The closed notch has a single
/// trailing slot, and two icons competing for it is how the badge width
/// becomes a fitted measurement -- which `NotchGeometry` documents at length
/// as the thing to avoid.
@Test func bothAtOnceIsOneState() {
    #expect(CaptureIndicator(CaptureUse(microphone: true, camera: true)) == .both)
}

@Test func captureUseKnowsWhetherAnythingIsHappening() {
    #expect(CaptureUse.none.isAnythingCapturing == false)
    #expect(CaptureUse(microphone: true).isAnythingCapturing)
    #expect(CaptureUse(camera: true).isAnythingCapturing)
}

// MARK: - It must not point at itself

private let me: pid_t = 501
private let somebodyElse: pid_t = 9001

/// **The requirement this module could most easily get wrong.**
/// `IsRunningSomewhere` reports THAT something is capturing, never WHO -- so an
/// indicator built on it alone lights up when CreativeNotch opens its own
/// camera preview, which tells the user nothing and reads as a bug.
@Test func ourOwnCaptureDoesNotCount() {
    let processes = [CaptureAttribution.Process(pid: me, isRunningInput: true)]
    #expect(CaptureAttribution.isSomebodyElseCapturing(processes: processes, ownPID: me) == false)
}

@Test func anotherApplicationsCaptureCounts() {
    let processes = [CaptureAttribution.Process(pid: somebodyElse, isRunningInput: true)]
    #expect(CaptureAttribution.isSomebodyElseCapturing(processes: processes, ownPID: me))
}

/// The case that separates a correct implementation from one that merely
/// subtracts us: somebody else capturing WHILE we are must still light it.
@Test func anotherApplicationCountsEvenWhileWeAreCapturingToo() {
    let processes = [
        CaptureAttribution.Process(pid: me, isRunningInput: true),
        CaptureAttribution.Process(pid: somebodyElse, isRunningInput: true),
    ]
    #expect(CaptureAttribution.isSomebodyElseCapturing(processes: processes, ownPID: me))
}

/// A process that is registered but idle is not capturing. Every app that has
/// ever touched CoreAudio appears in this list.
@Test func aRegisteredButIdleProcessDoesNotCount() {
    let processes = [
        CaptureAttribution.Process(pid: somebodyElse, isRunningInput: false),
        CaptureAttribution.Process(pid: 1234, isRunningInput: false),
    ]
    #expect(CaptureAttribution.isSomebodyElseCapturing(processes: processes, ownPID: me) == false)
}

/// The device flag is the notification; the process list is the attribution.
/// Neither alone is the answer.
@Test func theDeviceFlagAndTheProcessListAreBothRequired() {
    let others = [CaptureAttribution.Process(pid: somebodyElse, isRunningInput: true)]

    // Device says nothing is running: believe it, whatever the list says.
    #expect(CaptureAttribution.othersAreCapturing(
        deviceIsRunningSomewhere: false, processes: others, ownPID: me) == false)

    // Device says something is running, and it is not us.
    #expect(CaptureAttribution.othersAreCapturing(
        deviceIsRunningSomewhere: true, processes: others, ownPID: me))

    // Device says something is running, and it is only us.
    let onlyUs = [CaptureAttribution.Process(pid: me, isRunningInput: true)]
    #expect(CaptureAttribution.othersAreCapturing(
        deviceIsRunningSomewhere: true, processes: onlyUs, ownPID: me) == false)
}

// MARK: - Three events on start, one on stop

/// **Measured.** CoreMediaIO fires three events when a camera starts -- 0, 1, 1
/// within about 56ms -- and one when it stops. An indicator that toggled state
/// per callback would flicker every time any application opened a camera.
@Test func repeatedIdenticalReadingsPublishOnce() {
    var debounce = CaptureDebounce()

    #expect(debounce.accept(.none) == nil, "the first reading already matches the initial state")
    #expect(debounce.accept(CaptureUse(camera: true)) == CaptureUse(camera: true))
    #expect(debounce.accept(CaptureUse(camera: true)) == nil, "the second event redrew")
    #expect(debounce.accept(CaptureUse(camera: true)) == nil, "the third event redrew")
}

@Test func aRealChangeStillPublishes() {
    var debounce = CaptureDebounce(initial: CaptureUse(camera: true))
    #expect(debounce.accept(.none) == CaptureUse())
    #expect(debounce.state == .none)
}

/// Each device moves independently: the microphone starting while the camera
/// is already on is a change, not a repeat.
@Test func oneDeviceChangingWhileTheOtherHoldsIsAChange() {
    var debounce = CaptureDebounce(initial: CaptureUse(camera: true))

    let next = debounce.accept(CaptureUse(microphone: true, camera: true))

    #expect(next == CaptureUse(microphone: true, camera: true))
    #expect(CaptureIndicator(debounce.state) == .both)
}
