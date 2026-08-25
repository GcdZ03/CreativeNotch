import CoreAudio
import AudioToolbox
import CreativeNotchCore

/// Watches the default output device's volume and mute state.
///
/// Observes the **value**, not the keypress. That needs no permission —
/// CoreAudio is public API and not TCC-gated — and it catches every change
/// whatever caused it: Control Center, Siri, another application, or the
/// keys. Apple's own HUD only appears for the keys, so this is what fills
/// the gap.
@MainActor
public final class VolumeObserver {

    public var onChange: (HUDKind) -> Void = { _ in }

    private(set) var isRunning = false
    private var device = AudioDeviceID(0)

    /// A listener block registered on `device`, kept alongside the address
    /// it was registered with so `stop()` can pass the *same* block back to
    /// `AudioObjectRemovePropertyListenerBlock` — passing a freshly built
    /// block there cannot match the one that was installed, so removal
    /// would silently do nothing and the listener would leak.
    private struct Registration {
        var address: AudioObjectPropertyAddress
        var block: AudioObjectPropertyListenerBlock
    }
    private var registrations: [Registration] = []

    /// How many CoreAudio listeners are currently registered. Exposed so
    /// the lifecycle is provable: `isRunning` alone is a boolean that
    /// flips whether or not removal actually happened, which is exactly
    /// how a `stop()` that silently leaked would have passed review.
    var registrationCount: Int { registrations.count }

    /// The system-object listener that tracks default-device changes. It is
    /// registered on `kAudioObjectSystemObject`, not `device`, so it is
    /// tracked separately from `registrations` and removed from the object
    /// it was actually added to.
    private var systemRegistration: (address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)?

    public init() {}

    public func start() {
        guard !isRunning else { return }
        device = Self.defaultOutputDevice()
        guard device != 0 else { return }

        subscribe(to: kAudioHardwareServiceDeviceProperty_VirtualMainVolume) { [weak self] in
            guard let self, let level = self.currentLevel() else { return }
            self.onChange(.volume(level))
        }
        subscribe(to: kAudioDevicePropertyMute) { [weak self] in
            guard let self, let muted = self.isMuted() else { return }
            self.onChange(.mute(muted))
        }

        // The default output device changes when headphones are plugged in
        // or a display is connected. Without re-subscribing, the volume
        // half silently stops working.
        subscribeToSystem(kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            guard let self else { return }
            self.stop()
            self.start()
        }

        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        for var registration in registrations {
            AudioObjectRemovePropertyListenerBlock(
                device, &registration.address, DispatchQueue.main, registration.block
            )
        }
        registrations.removeAll()

        if var systemRegistration {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &systemRegistration.address,
                DispatchQueue.main,
                systemRegistration.block
            )
        }
        systemRegistration = nil

        isRunning = false
    }

    public func currentLevel() -> Double? {
        read(Float32.self, kAudioHardwareServiceDeviceProperty_VirtualMainVolume).map(Double.init)
    }

    public func isMuted() -> Bool? {
        read(UInt32.self, kAudioDevicePropertyMute).map { $0 != 0 }
    }

    // MARK: - CoreAudio plumbing

    private static func defaultOutputDevice() -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        ) == noErr else { return 0 }
        return id
    }

    private func read<T>(_ type: T.Type, _ selector: AudioObjectPropertySelector) -> T? {
        // `device` is only populated by `start()`. `currentLevel()` and
        // `isMuted()` are public and documented to work whether or not the
        // observer is running (the tests call them on a fresh, unstarted
        // observer), so a stopped observer resolves the default device
        // fresh on every read instead of reporting nil regardless of the
        // machine's actual hardware.
        let target = isRunning ? device : Self.defaultOutputDevice()
        guard target != 0 else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(target, &address) else { return nil }
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        var size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectGetPropertyData(target, &address, 0, nil, &size, value) == noErr
        else { return nil }
        return value.pointee
    }

    private func subscribe(
        to selector: AudioObjectPropertySelector,
        handler: @escaping @MainActor () -> Void
    ) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return }
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { handler() }
        }
        let status = AudioObjectAddPropertyListenerBlock(device, &address, DispatchQueue.main, block)
        if status == noErr {
            registrations.append(Registration(address: address, block: block))
        }
    }

    private func subscribeToSystem(
        _ selector: AudioObjectPropertySelector,
        handler: @escaping @MainActor () -> Void
    ) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { handler() }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
        if status == noErr {
            systemRegistration = (address: address, block: block)
        }
    }
}
