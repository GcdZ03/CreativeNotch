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

    /// How many listeners are installed. Exposed for the same reason
    /// `PowerObserver.registrationCount` is: a stop that is asserted rather
    /// than observed is not a stop.
    var registrationCount: Int { audioListeners.count + cmioListeners.count }

    /// **A backstop, and it is not paranoia.** There is an unanswered radar
    /// claiming `CMIOObjectRemovePropertyListenerBlock` returns `noErr` and
    /// keeps delivering. If that reproduces, a registration count of zero would
    /// mean "removal was asked for" rather than "it stopped" -- the same class
    /// of failure as the media helper's activity gate. So the handler checks
    /// this before doing anything.
    private var isStopped = true

    /// Overridable so tests never touch CoreAudio or CoreMediaIO.
    var readCurrentUse: () -> CaptureUse = { CaptureObserver.readSystem() }

    func start() {
        guard isStopped else { return }
        isStopped = false
        installAudioListeners()
        installCameraListeners()
        publish()
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true

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

    /// Test seam: drives the same path a listener callback does, so the
    /// stopped-flag backstop can be exercised without a system that refuses to
    /// remove a listener.
    func publishForTesting() { publish() }

    private func publish() {
        guard !isStopped else { return }
        onChange?(readCurrentUse())
    }

    // MARK: - Registration

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

    static func readSystem() -> CaptureUse {
        CaptureUse(
            microphone: audioInputDevices().contains { isRunningSomewhere(audio: $0) },
            camera: cameraDevices().contains { isRunningSomewhere(camera: $0) }
        )
    }

    private static func isRunningSomewhere(audio device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
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
