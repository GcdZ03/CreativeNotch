import Foundation

extension Bundle {
    /// The bundle every user-facing string is looked up in — Core's and
    /// the UI's alike. There is one String Catalog for the whole app
    /// (`Localizable.xcstrings`, next to this file) so a translator has one
    /// file to fill in, and so a string moving between Core and the UI
    /// never moves between catalogs. Use it as
    /// `String(localized: "…", bundle: .creativeNotch)` or
    /// `Text("…", bundle: .creativeNotch)`; a literal without it is looked
    /// up in the *main* bundle, which has no strings, and
    /// `LocalizationTests` fails the build.
    ///
    /// Why not `Bundle.module` directly: SwiftPM's generated accessor looks
    /// for the resource bundle at the root of the `.app`, beside
    /// `Contents/`, and anything there breaks the code signature
    /// ("unsealed contents present in the bundle root"). `Scripts/bundle.sh`
    /// puts it in `Contents/Resources/` where it belongs, so this looks
    /// there first and only falls back to SwiftPM's accessor — which finds
    /// the build directory — under `swift run` and `swift test`.
    public static let creativeNotch: Bundle = shipped(in: Bundle.main.resourceURL) ?? .module

    /// The strings bundle inside an app's `Contents/Resources`, if it is
    /// there. Separate so the lookup is testable without a packaged app.
    static func shipped(in resources: URL?) -> Bundle? {
        guard let resources else { return nil }
        return Bundle(url: resources.appendingPathComponent(stringsBundleName))
    }

    /// What SwiftPM names Core's resource bundle, and what `bundle.sh`
    /// copies into the app under the same name.
    static let stringsBundleName = "CreativeNotch_CreativeNotchCore.bundle"
}
