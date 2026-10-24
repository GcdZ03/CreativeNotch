import AppKit
import CreativeNotchCore

/// Owns the colour picker: the sampler, the history, and what a copy writes
/// (2026-10-24).
///
/// **Nothing here runs at rest.** There is no observer, no timer and no
/// process: the sampler exists only between a click on the dropper and a
/// click on the screen, and the history is five values in memory. That is
/// why the module ships on, and why the switchboard leg has nothing to stop
/// beyond forgetting the history and dropping a pick still in flight.
///
/// It decides nothing about the panel. Closing it for the loupe, reopening
/// it and showing the result are `AppDelegate.pickColor()`'s, which is the
/// one place that already moves the panel.
@MainActor
final class ColorPickerController {

    private let sampler: ColorSampling
    private let pasteboard: NSPasteboard

    /// What a copy writes. Applied from the store at install and by
    /// `AppState.onSetColorFormat`, never read from defaults here.
    var format: ColorFormat = .default

    private(set) var history = ColorHistory()

    /// Whether the loupe is up. A second click on the dropper while it is
    /// would otherwise stack a second sampler on the first.
    private(set) var isSampling = false

    private(set) var isEnabled = true

    /// Bumped by switching off. `NSColorSampler` has no cancel, so a pick
    /// started before the switch went off still finishes; its completion
    /// checks this and drops a result that belongs to a module now off.
    private var generation = 0

    /// Told the history after every change, to publish it. Set by
    /// `AppDelegate`.
    var onChange: ((ColorHistory) -> Void)?

    init(sampler: ColorSampling, pasteboard: NSPasteboard) {
        self.sampler = sampler
        self.pasteboard = pasteboard
    }

    /// Shows the loupe. `completion` gets the colour, already copied and
    /// recorded, or `nil` for Esc. Returns `false`, and calls nothing, while
    /// switched off or while a pick is already in progress; a pick dropped by
    /// switching off never calls `completion` at all.
    @discardableResult
    func pick(completion: @escaping (SampledColor?) -> Void) -> Bool {
        guard isEnabled, !isSampling else { return false }
        isSampling = true
        let started = generation
        sampler.sample { [weak self] color in
            guard let self, started == self.generation else { return }
            self.isSampling = false
            if let color { self.copy(color) }
            completion(color)
        }
        return true
    }

    /// Writes `color` to the pasteboard in the current format and moves it to
    /// the front of the history. The pick's last step, and what a swatch does.
    func copy(_ color: SampledColor) {
        guard isEnabled else { return }
        pasteboard.clearContents()
        pasteboard.setString(format.string(for: color), forType: .string)
        history.record(color)
        onChange?(history)
    }

    /// Off forgets every colour and drops a pick still in flight; on only
    /// lets the dropper work again. Idempotent either way.
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        guard !enabled else { return }
        generation &+= 1
        isSampling = false
        history.clear()
        onChange?(history)
    }
}
