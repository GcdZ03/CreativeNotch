import AppKit
import Carbon.HIToolbox
import CreativeNotchCore

/// Registers key combinations with the window server.
///
/// **Not a global event monitor**, and that distinction is the whole reason
/// this module is allowed to exist. `NSEvent.addGlobalMonitorForEvents` runs a
/// closure on every keystroke you type, forever, which `ARCHITECTURE.md` names
/// as not allowed. `RegisterEventHotKey` hands the combination to the window
/// server, which delivers an event only when that combination is pressed.
/// Nothing runs in between, and it needs no Accessibility permission because
/// it never sees any key but the one it registered.
///
/// Registration is **exclusive**. Not for the conflict detection -- virtually
/// nothing ships with that option, so `eventHotKeyExistsErr` will rarely fire
/// -- but for delivery: it stops other registrants' handlers running for the
/// combination, so a hotkey the user chose does one thing rather than two.
@MainActor
final class HotKeyCenter {

    /// Four characters, 'CNKY'. The handler is installed on the application
    /// event target and sees EVERY `kEventHotKeyPressed` in the process,
    /// including any a dependency registers, so it checks this and returns
    /// `eventNotHandledErr` for anything else.
    static let signature: OSType = 0x434E4B59

    /// A nonisolated mirror so the C callback can reject someone else's event
    /// without an actor hop.
    nonisolated static var signatureForCallback: OSType { 0x434E4B59 }

    static let shared = HotKeyCenter()

    private struct Entry {
        let ref: EventHotKeyRef
        let action: () -> Void
    }

    private var entries: [UInt32: Entry] = [:]
    private var nextID: UInt32 = 1
    private var handlerRef: EventHandlerRef?

    private init() {}

    /// How many combinations are registered. Exposed for the same reason
    /// `PowerObserver.registrationCount` is: a stop that is asserted rather
    /// than observed is the failure this project keeps finding.
    var registrationCount: Int { entries.count }

    /// Whether the process-wide Carbon handler is installed.
    var isHandlerInstalled: Bool { handlerRef != nil }

    // MARK: - The one handler

    private func installHandlerIfNeeded() throws {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var ref: EventHandlerRef?

        // THE TRAP, and it is three traps wearing one coat.
        //
        // This closure captures NOTHING, which is what lets it convert to
        // `@convention(c)`. Add one capture -- `self`, a local, anything --
        // and it fails to build with "a C function pointer cannot be formed
        // from a closure that captures context". That diagnostic comes out of
        // SILGen, NOT the type checker, so `swiftc -typecheck` and every
        // editor reports the capturing version CLEAN.
        //
        // Context therefore travels as the `EventHotKeyID` carried by the
        // event. The canonical blog pattern -- `Unmanaged.passUnretained(self)
        // .toOpaque()` in `userData` -- works right up until the owner
        // deallocates, and then it is a use-after-free. There is no lifetime
        // here to get wrong.
        //
        // And `MainActor.assumeIsolated` is not ceremony. The Carbon
        // dispatcher running on the main run loop is an INFERENCE -- Apple's
        // header says only "not thread safe" -- so this asserts it, trapping
        // loudly if it is ever false. Calling a `@MainActor` method straight
        // from here is merely a WARNING under Swift 6 strict concurrency: it
        // compiles, works by luck, and would have shipped before CI grew a
        // warning gate.
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var hkID = EventHotKeyID()
                let read = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                guard read == noErr else { return read }
                guard hkID.signature == HotKeyCenter.signatureForCallback else {
                    // Someone else's hotkey. Returning `noErr` here would tell
                    // the Carbon dispatcher we consumed their event.
                    return OSStatus(eventNotHandledErr)
                }
                MainActor.assumeIsolated {
                    HotKeyCenter.shared.fire(id: hkID.id)
                }
                return noErr
            },
            1, &spec, nil, &ref
        )

        guard status == noErr else { throw HotKeyError.handlerInstallFailed(status) }
        handlerRef = ref
    }

    private func fire(id: UInt32) {
        entries[id]?.action()
    }

    // MARK: - Register and unregister

    @discardableResult
    func register(_ combo: HotKeyCombo, action: @escaping () -> Void) throws -> UInt32 {
        try installHandlerIfNeeded()
        let id = nextID
        nextID &+= 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.carbonModifiers,
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(),
            // **Exclusive, and no test bites this line.** Said plainly rather
            // than left to be discovered: swapping it for
            // `kEventHotKeyNoOptions` leaves the whole suite green, because
            // exclusivity's only observable effect is cross-process --
            // suppressing another application's handler -- and a single-process
            // suite cannot see it.
            //
            // The duplicate detection this file relies on is a different rule:
            // `CarbonEventsCore.h` returns -9878 for a hotkey already
            // registered IN THE CURRENT PROCESS whatever the options are. So
            // `registeringTheSameCombinationTwiceIsRefused` passes either way
            // and proves the error mapping, not the option.
            //
            // It is kept because it is what makes a chosen hotkey do one thing
            // instead of two. Measured cross-process in the probe; see
            // `docs/research/2026-09-13-hotkey-probe.md`.
            OptionBits(kEventHotKeyExclusive),
            &ref
        )

        guard status == noErr, let ref else {
            // Three outcomes needing three different things said to the user.
            // `eventInternalErr` is the system's modifier-policy rejection,
            // not a generic failure -- measured as -9868 when macOS 15 refused
            // shift/option-only combinations.
            switch status {
            case OSStatus(eventHotKeyExistsErr): throw HotKeyError.exclusiveConflict
            case OSStatus(eventInternalErr):     throw HotKeyError.rejectedBySystem(status)
            default:                             throw HotKeyError.other(status)
            }
        }

        entries[id] = Entry(ref: ref, action: action)
        return id
    }

    /// Drops a registration, and the handler with it when the last one goes.
    ///
    /// Leaving the handler installed would be cheap, and it would violate this
    /// module's own rule: switching the feature off in Settings must stop the
    /// subsystem, and for this module the subsystem IS the registration plus
    /// the process-wide handler.
    ///
    /// Not needed at termination. Apple's header is explicit that the system
    /// reclaims registrations when the process exits, so teardown there would
    /// defend against something that cannot happen.
    func unregister(_ id: UInt32) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(entry.ref)
        removeHandlerIfEmpty()
    }

    func unregisterAll() {
        for entry in entries.values { UnregisterEventHotKey(entry.ref) }
        entries.removeAll()
        removeHandlerIfEmpty()
    }

    private func removeHandlerIfEmpty() {
        guard entries.isEmpty, let handlerRef else { return }
        RemoveEventHandler(handlerRef)
        self.handlerRef = nil
    }
}

enum HotKeyError: Error, Equatable, Sendable {
    /// −9878, and **only** ever for exclusive-versus-exclusive. An ordinary
    /// conflict does not produce this; it produces a silent double-fire.
    case exclusiveConflict
    /// −9868. The system's modifier policy refused the combination.
    case rejectedBySystem(OSStatus)
    case other(OSStatus)
    case handlerInstallFailed(OSStatus)
}
