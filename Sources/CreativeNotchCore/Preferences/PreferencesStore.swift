import Foundation

/// Reads and writes the module toggles, and the adjustable limits.
///
/// Takes an injectable suite, so tests run against an isolated store rather
/// than the developer's real `com.gcdz.creativenotch` domain.
///
/// **It caches nothing.** A cached `Preferences` is a second source of truth
/// that has to be invalidated, and the pattern it would copy — a `let` that
/// reads the defaults domain once at construction — is precisely the one this
/// module must not repeat: a preference read once at construction is a
/// preference that appears to work in the window and changes nothing until
/// relaunch.
public final class PreferencesStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> Preferences {
        var preferences = Preferences()
        for module in ModuleID.allCases {
            preferences[module] = PreferenceKeys.resolveEnabled(
                defaults.object(forKey: PreferenceKeys.enabled(module)),
                shippedDefault: module.shippedDefault
            )
        }
        return preferences
    }

    public func setEnabled(_ enabled: Bool, for module: ModuleID) {
        defaults.set(enabled, forKey: PreferenceKeys.enabled(module))
    }

    /// Whether the welcome card has been dismissed. Read through
    /// `resolveEnabled` like every other flag, so a hand-typed string reads as
    /// not seen and is left in place.
    public var hasSeenWelcome: Bool {
        PreferenceKeys.resolveEnabled(
            defaults.object(forKey: PreferenceKeys.welcomeSeen), shippedDefault: false
        )
    }

    /// Which display the notch lives on. Read on every call, never cached.
    public var displayChoice: DisplayChoice {
        PreferenceKeys.resolveDisplayChoice(defaults.object(forKey: PreferenceKeys.showOn))
    }

    public func setDisplayChoice(_ choice: DisplayChoice) {
        defaults.set(choice.rawValue, forKey: PreferenceKeys.showOn)
    }

    /// Whether the pill moves clear of the frontmost app's menus. Read on
    /// every call, never cached; off unless switched on, and a hand-typed
    /// string reads as off and is left in place.
    public var pillClearsMenus: Bool {
        PreferenceKeys.resolveEnabled(
            defaults.object(forKey: PreferenceKeys.pillClearsMenus), shippedDefault: false
        )
    }

    public func setPillClearsMenus(_ enabled: Bool) {
        defaults.set(enabled, forKey: PreferenceKeys.pillClearsMenus)
    }

    /// How large the open panel's text is. Read on every call, never cached.
    public var textSize: TextSize {
        PreferenceKeys.resolveTextSize(defaults.object(forKey: PreferenceKeys.textSize))
    }

    public func setTextSize(_ size: TextSize) {
        defaults.set(size.rawValue, forKey: PreferenceKeys.textSize)
    }

    /// The layout options (2026-10-24). Read on every call, never cached;
    /// every key through a resolver, so a missing or hand-mangled value reads
    /// as the default and is left in place for `defaults read`.
    public func loadLayout() -> LayoutOptions {
        LayoutOptions(
            width: PreferenceKeys.resolveChoice(
                defaults.object(forKey: PreferenceKeys.layoutWidth), default: PanelWidth.default
            ),
            corners: PreferenceKeys.resolveChoice(
                defaults.object(forKey: PreferenceKeys.layoutCorners), default: PanelCorners.default
            ),
            tabsSide: PreferenceKeys.resolveChoice(
                defaults.object(forKey: PreferenceKeys.layoutTabsSide), default: EarSide.default
            ),
            showsBattery: PreferenceKeys.resolveEnabled(
                defaults.object(forKey: PreferenceKeys.layoutShowsBattery)
            ),
            showsNowPlayingBadge: PreferenceKeys.resolveEnabled(
                defaults.object(forKey: PreferenceKeys.layoutShowsNowPlayingBadge)
            ),
            showsTimerBadge: PreferenceKeys.resolveEnabled(
                defaults.object(forKey: PreferenceKeys.layoutShowsTimerBadge)
            ),
            showsDownloadsBadge: PreferenceKeys.resolveEnabled(
                defaults.object(forKey: PreferenceKeys.layoutShowsDownloadsBadge)
            ),
            animatesNowPlayingBars: PreferenceKeys.resolveEnabled(
                defaults.object(forKey: PreferenceKeys.layoutAnimatesNowPlayingBars), shippedDefault: false
            )
        )
    }

    /// Writes every option, not only the one that changed, for the reason
    /// `saveLimits` does.
    public func saveLayout(_ layout: LayoutOptions) {
        defaults.set(layout.width.rawValue, forKey: PreferenceKeys.layoutWidth)
        defaults.set(layout.corners.rawValue, forKey: PreferenceKeys.layoutCorners)
        defaults.set(layout.tabsSide.rawValue, forKey: PreferenceKeys.layoutTabsSide)
        defaults.set(layout.showsBattery, forKey: PreferenceKeys.layoutShowsBattery)
        defaults.set(layout.showsNowPlayingBadge, forKey: PreferenceKeys.layoutShowsNowPlayingBadge)
        defaults.set(layout.showsTimerBadge, forKey: PreferenceKeys.layoutShowsTimerBadge)
        defaults.set(layout.showsDownloadsBadge, forKey: PreferenceKeys.layoutShowsDownloadsBadge)
        defaults.set(layout.animatesNowPlayingBars, forKey: PreferenceKeys.layoutAnimatesNowPlayingBars)
    }

    /// How a picked colour is copied. Read on every call, never cached.
    public var colorFormat: ColorFormat {
        PreferenceKeys.resolveColorFormat(defaults.object(forKey: PreferenceKeys.colorFormat))
    }

    public func setColorFormat(_ format: ColorFormat) {
        defaults.set(format.rawValue, forKey: PreferenceKeys.colorFormat)
    }

    /// Whether a timer finishing behind a full-screen app posts a
    /// notification. Absent means on. Read on every call, never cached.
    public var timerNotifyWhenHidden: Bool {
        PreferenceKeys.resolveEnabled(defaults.object(forKey: PreferenceKeys.timerNotifyWhenHidden))
    }

    public func setTimerNotifyWhenHidden(_ enabled: Bool) {
        defaults.set(enabled, forKey: PreferenceKeys.timerNotifyWhenHidden)
    }

    /// The apps whose copies clipboard history ignores. Read on every call,
    /// never cached.
    public var clipboardExcludedApps: [String] {
        ClipboardExclusions.resolve(defaults.object(forKey: PreferenceKeys.clipboardExcludedApps))
    }

    public func setClipboardExcludedApps(_ ids: [String]) {
        defaults.set(ids, forKey: PreferenceKeys.clipboardExcludedApps)
    }

    /// Whether the updater checks without being asked (2026-10-24). Absent
    /// means on. Read on every call, never cached.
    public var checksForUpdatesAutomatically: Bool {
        PreferenceKeys.resolveEnabled(defaults.object(forKey: PreferenceKeys.updatesAutomatic))
    }

    public func setChecksForUpdatesAutomatically(_ enabled: Bool) {
        defaults.set(enabled, forKey: PreferenceKeys.updatesAutomatic)
    }

    /// What the updater remembers: the last answered check, its ETag and
    /// the release it described. Read through `UpdateRecord.resolve`, so a
    /// hand-mangled value reads as absent and is left in place.
    public func loadUpdateRecord() -> UpdateRecord {
        UpdateRecord.resolve(
            lastCheck: defaults.object(forKey: PreferenceKeys.updatesLastCheck),
            etag: defaults.object(forKey: PreferenceKeys.updatesETag),
            release: defaults.object(forKey: PreferenceKeys.updatesRelease)
        )
    }

    /// Writes all three together, for `saveLimits`'s reason; an absent
    /// field removes its key rather than writing a blank.
    public func saveUpdateRecord(_ record: UpdateRecord) {
        set(record.lastCheck?.timeIntervalSince1970, forKey: PreferenceKeys.updatesLastCheck)
        set(record.etag, forKey: PreferenceKeys.updatesETag)
        set(record.release.flatMap { try? JSONEncoder().encode($0) }, forKey: PreferenceKeys.updatesRelease)
    }

    private func set(_ value: Any?, forKey key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    /// `false` removes the key rather than writing `false`, so "Show Welcome
    /// Again" leaves the domain reading exactly like a fresh install's.
    public func setHasSeenWelcome(_ seen: Bool) {
        if seen {
            defaults.set(true, forKey: PreferenceKeys.welcomeSeen)
        } else {
            defaults.removeObject(forKey: PreferenceKeys.welcomeSeen)
        }
    }

    /// The adjustable limits (2026-10-24). Every key read through the
    /// resolvers on `Limits`, so a missing or hand-mangled value reads as the
    /// old hard-coded number and is left in place for `defaults read`.
    public func loadLimits() -> Limits {
        Limits(
            shelfCapacity: Limits.resolveChoice(
                defaults.object(forKey: PreferenceKeys.shelfCapacity),
                among: Limits.shelfCapacityChoices, default: Limits.defaultShelfCapacity
            ),
            shelfExpiry: Limits.resolveExpiry(defaults.object(forKey: PreferenceKeys.shelfExpiryDays)),
            clipboardCapacity: Limits.resolveChoice(
                defaults.object(forKey: PreferenceKeys.clipboardCapacity),
                among: Limits.clipboardCapacityChoices, default: Limits.defaultClipboardCapacity
            ),
            timerPresets: Limits.resolvePresets(defaults.object(forKey: PreferenceKeys.timerPresets)),
            chime: Limits.resolveChime(defaults.object(forKey: PreferenceKeys.timerChime))
        )
    }

    /// Writes every limit, not only the one that changed: they arrive as one
    /// value, and a partial write is a second way for the domain and the app
    /// to disagree.
    public func saveLimits(_ limits: Limits) {
        defaults.set(limits.shelfCapacity, forKey: PreferenceKeys.shelfCapacity)
        defaults.set(limits.shelfExpiry.rawValue, forKey: PreferenceKeys.shelfExpiryDays)
        defaults.set(limits.clipboardCapacity, forKey: PreferenceKeys.clipboardCapacity)
        defaults.set(limits.timerPresets, forKey: PreferenceKeys.timerPresets)
        defaults.set(limits.chime.rawValue, forKey: PreferenceKeys.timerChime)
    }
}
