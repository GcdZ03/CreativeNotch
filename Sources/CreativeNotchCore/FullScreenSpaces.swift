/// Reads the window server's per-display Space list (`CGSCopyManagedDisplaySpaces`)
/// to tell whether the notch's display is showing a full-screen app
/// (2026-10-17).
///
/// The notch used to hide over full-screen apps without any of this: omitting
/// `.fullScreenAuxiliary` was enough. Since it moved into a Space of its own,
/// above every other, so a desktop swipe would not carry it (#34), it shows
/// over them instead — over a film, over the auto-hiding menu bar. So the app
/// asks, on each Space change, and hides it itself.
///
/// Measured on 2026-10-17, macOS 26: desktops report `type` 0, and the Space
/// a full-screen window makes reports `type` 4.
public enum FullScreenSpaces {
    public static let fullScreenType = 4

    /// Anything unreadable answers `false`: a notch that fails to hide is a
    /// nuisance, one that hides by mistake looks like the app quit.
    public static func isFullScreen(displays: [[String: Any]], displayUUID: String?) -> Bool {
        guard let displayUUID else { return false }
        // With "Displays have separate Spaces" off there is one entry,
        // "Main", for all of them.
        let entry = displays.first { ($0["Display Identifier"] as? String) == displayUUID }
            ?? displays.first { ($0["Display Identifier"] as? String) == "Main" }
        guard let current = entry?["Current Space"] as? [String: Any],
              let type = current["type"] as? Int
        else { return false }
        return type == fullScreenType
    }
}
