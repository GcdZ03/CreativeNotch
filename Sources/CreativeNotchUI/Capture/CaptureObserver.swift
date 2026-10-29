import AVFoundation
import AppKit
import CoreAudio
import CoreMediaIO
import CreativeNotchCore

/// Watches for another application using the microphone or the camera.
///
/// **Notification-driven, never polled.** Both properties are listenable, so
/// this costs nothing between events -- which is what lets the module join the
/// activity gate without being suspended, like the power module.
///
/// **Registered on GLOBAL scope**, and that is measured rather than assumed.
/// The directional scope that `VolumeObserver` uses -- correct there, because
/// volume genuinely is per-direction -- registers with `noErr` here and then
/// **never fires**, while its property value reads correctly the whole time.
/// So polling to check it would pass and the indicator would never update. See
/// `docs/research/2026-09-13-capture-listener-scope.md`.
@MainActor
final class CaptureObserver {

    /// Called with a fresh reading whenever anything changes. The reading is
    /// taken by re-reading the properties, never inferred from the callback --
    /// CoreMediaIO fires three events per camera start, and reacting to each
    /// would flicker.
    var onChange: ((CaptureUse) -> Void)?

    private var audioListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var cmioListeners: [(CMIOObjectID, CMIOObjectPropertyAddress, CMIOObjectPropertyListenerBlock)] = []

    /// The two listeners on the device *lists*, kept apart from the per-device
    /// ones above because a list change tears those down and rebuilds them,
    /// and must not tear down itself.
    private var audioListListener: (AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)?
    private var cmioListListener: (CMIOObjectPropertyAddress, CMIOObjectPropertyListenerBlock)?

    /// How many listeners are installed. Exposed for the same reason
    /// `PowerObserver.registrationCount` is: a stop that is asserted rather
    /// than observed is not a stop.
    var registrationCount: Int {
        audioListeners.count + cmioListeners.count
            + (audioListListener == nil ? 0 : 1) + (cmioListListener == nil ? 0 : 1)
    }

    /// **A backstop, and it is not paranoia.** There is an unanswered radar
    /// claiming `CMIOObjectRemovePropertyListenerBlock` returns `noErr` and
    /// keeps delivering. If that reproduces, a registration count of zero would
    /// mean "removal was asked for" rather than "it stopped" -- the same class
    /// of failure as the media helper's activity gate. So the handler checks
    /// this before doing anything.
    private var isStopped = true

    /// The `uniqueID` of the camera this app's own preview holds, or `nil`.
    ///
    /// `IsRunningSomewhere` cannot say *who* is capturing, so without this the
    /// indicator lights for our own preview. A change re-reads: releasing the
    /// camera while somebody else is still on it must light the badge now,
    /// not at their next edge -- and that edge may never come.
    var ownCameraUID: String? {
        didSet {
            guard ownCameraUID != oldValue else { return }
            publish()
        }
    }

    /// Overridable so tests never touch CoreAudio or CoreMediaIO.
    var readCurrentUse: () -> CaptureUse = { .none }

    init() {
        readCurrentUse = { [weak self] in
            CaptureObserver.readSystem(ownCameraUID: self?.ownCameraUID)
        }
    }

    func start() {
        guard isStopped else { return }
        isStopped = false
        installDeviceListListeners()
        installAudioListeners()
        installCameraListeners()
        publish()
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true

        removeDeviceListeners()

        if let (address, block) = audioListListener {
            var address = address
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
            audioListListener = nil
        }
        if let (address, block) = cmioListListener {
            var address = address
            CMIOObjectRemovePropertyListenerBlock(
                CMIOObjectID(kCMIOObjectSystemObject), &address, .main, block)
            cmioListListener = nil
        }
    }

    /// Test seam: drives the same path a listener callback does, so the
    /// stopped-flag backstop can be exercised without a system that refuses to
    /// remove a listener.
    func publishForTesting() { publish() }

    /// Test seam: drives the path a device-list callback does, without
    /// plugging anything in.
    func devicesChangedForTesting() { devicesChanged() }

    private func publish() {
        guard !isStopped else { return }
        onChange?(readCurrentUse())
    }

    /// A device arrived or left. Rebuild the per-device listeners against the
    /// list as it is now, then re-read: a device unplugged mid-capture never
    /// fires its own "stopped" edge, so without the re-read the badge would
    /// stay lit for hardware that is no longer there.
    ///
    /// Removing a listener from a device that has already gone fails, and
    /// that is fine -- the device took the listener with it.
    private func devicesChanged() {
        guard !isStopped else { return }
        removeDeviceListeners()
        installAudioListeners()
        installCameraListeners()
        publish()
    }

    private func removeDeviceListeners() {
        for (id, address, block) in audioListeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(id, &address, .main, block)
        }
        audioListeners.removeAll()

        for (id, address, block) in cmioListeners {
            var address = address
            CMIOObjectRemovePropertyListenerBlock(id, &address, .main, block)
        }
        cmioListeners.removeAll()
    }

    // MARK: - Registration

    /// Listens to the device lists themselves, on the system objects.
    ///
    /// The per-device listeners below can only be attached to devices that
    /// exist at the time, and AirPods connecting, a USB webcam being plugged
    /// in or Continuity Camera waking all happen later. Still one notification
    /// per change and nothing between -- no polling for new hardware.
    private func installDeviceListListeners() {
        var audioAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let audioBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.devicesChanged() }
        }
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &audioAddress, .main, audioBlock) == noErr {
            audioListListener = (audioAddress, audioBlock)
        }

        var cmioAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        let cmioBlock: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.devicesChanged() }
        }
        // `.main`, never `nil`, for the reason given in
        // `installCameraListeners`.
        if CMIOObjectAddPropertyListenerBlock(
            CMIOObjectID(kCMIOObjectSystemObject), &cmioAddress, .main, cmioBlock) == noErr {
            cmioListListener = (cmioAddress, cmioBlock)
        }
    }

    private func installAudioListeners() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            // GLOBAL, measured. Input scope registers and never fires.
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        for device in Self.audioInputDevices() {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.publish() }
            }
            if AudioObjectAddPropertyListenerBlock(device, &address, .main, block) == noErr {
                audioListeners.append((device, address, block))
            }
        }
    }

    private func installCameraListeners() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        for device in Self.cameraDevices() {
            let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.publish() }
            }
            // `.main`, never `nil`: the header says a NULL queue invokes the
            // block directly on the DAL thread, which under `assumeIsolated`
            // would trap.
            if CMIOObjectAddPropertyListenerBlock(device, &address, .main, block) == noErr {
                cmioListeners.append((device, address, block))
            }
        }
    }

    // MARK: - Reading the system

    /// `ownCameraUID` is the camera this app's own preview holds; it is
    /// attributed to us by `CaptureAttribution`, so our preview does not light
    /// the indicator that exists to report somebody else.
    static func readSystem(ownCameraUID: String?) -> CaptureUse {
        let cameras = cameraDevices().map {
            CaptureAttribution.Camera(
                uid: deviceUID(camera: $0) ?? "",
                isRunningSomewhere: isRunningSomewhere(camera: $0)
            )
        }
        return CaptureUse(
            microphone: audioInputDevices().contains { isRunningSomewhere(audio: $0) },
            camera: CaptureAttribution.othersAreUsingCamera(
                cameras: cameras, ownDeviceUID: ownCameraUID)
        )
    }

    /// Read on **input** scope, though the listener is global.
    ///
    /// Global scope answers "is this device running", and a combined
    /// input/output device -- a USB headset, AirPods -- runs to *play*, so a
    /// song lit "Microphone in use". The research note measured the
    /// input-scope value as accurate on both edges; it is only the input-scope
    /// *notification* that never fires. So: subscribe global, read input.
    private static func isRunningSomewhere(audio device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
        else { return false }
        return value != 0
    }

    private static func isRunningSomewhere(camera device: CMIOObjectID) -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard CMIOObjectGetPropertyData(device, &address, 0, nil,
                                        size, &size, &value) == noErr
        else { return false }
        return value != 0
    }

    /// The camera's `kCMIODevicePropertyDeviceUID`, which is the string
    /// AVFoundation vends as `AVCaptureDevice.uniqueID` -- the join between
    /// the device our preview opened and the device this observer sees.
    private static func deviceUID(camera device: CMIOObjectID) -> String? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        // Returned +1, per the CoreAudio/CoreMediaIO convention for CFType
        // properties, so it is taken retained.
        var uid: Unmanaged<CFString>?
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var used: UInt32 = 0
        let status = withUnsafeMutablePointer(to: &uid) {
            CMIOObjectGetPropertyData(device, &address, 0, nil, size, &used, $0)
        }
        guard status == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }

    private static func audioInputDevices() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }

        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }

        return ids.filter { hasInputStreams($0) }
    }

    private static func hasInputStreams(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr
        else { return false }
        return size > 0
    }

    private static func cameraDevices() -> [CMIOObjectID] {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }

        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil,
            size, &used, &ids) == noErr
        else { return [] }

        return ids
    }
}

/// Who is using the camera and microphone right now, as the delegate's
/// indicator reads it (2026-10-29).
///
/// A seam like `PowerStateObserver`: the delegate holds
/// `SandboxCaptureReading`, which reads nothing, and only
/// `configureForRealLaunch()` hands it the CoreAudio and CoreMediaIO read.
/// Every suite that built a delegate used to have to switch the real read
/// off by hand, or pass or fail by whether its developer was on a call --
/// the capture badge widens the closed notch the way the low-battery peek
/// did.
@MainActor
protocol CaptureReading {
    func currentUse(ownCameraUID: String?) -> CaptureUse
}

/// The default: nobody is ever using anything.
struct SandboxCaptureReading: CaptureReading {
    func currentUse(ownCameraUID: String?) -> CaptureUse { .none }
}

/// The real read, `CaptureObserver.readSystem(ownCameraUID:)`.
struct SystemCaptureReading: CaptureReading {
    func currentUse(ownCameraUID: String?) -> CaptureUse {
        CaptureObserver.readSystem(ownCameraUID: ownCameraUID)
    }
}
