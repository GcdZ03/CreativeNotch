import Foundation
import PackagePlugin

/// Compiles a target's `Localizable.xcstrings` into the `.lproj` tables
/// Foundation actually reads at runtime.
///
/// Why a plugin at all: SwiftPM on the command line copies a String
/// Catalog into the resource bundle *as is*, and `Bundle` cannot read raw
/// `.xcstrings` — every lookup silently falls back to the key. For most
/// strings the key *is* the English text, so that failure is invisible
/// until a plural: `"%lld files"` comes back as "1 files". Only Xcode's
/// build system runs `xcstringstool compile`; this does the same for
/// `swift build`, `swift test` and `Scripts/bundle.sh`, so every way of
/// building the app resolves strings identically.
///
/// The catalog is listed under the target's `exclude:` so SwiftPM does not
/// also copy the raw JSON; this plugin reads it by path instead.
@main
struct StringCatalogCompiler: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        guard let target = target as? SourceModuleTarget else { return [] }
        let catalog = target.directoryURL.appending(path: "Localizable.xcstrings")
        guard FileManager.default.fileExists(atPath: catalog.path) else { return [] }

        let output = context.pluginWorkDirectoryURL.appending(path: "Strings")
        // Outputs must be declared up front, and xcstringstool only writes
        // a table it has something to put in (no `.strings` when every
        // string is its own English text, no `.stringsdict` without a
        // plural). So the command touches every declared file afterwards:
        // an empty table is valid and simply resolves nothing, where a
        // declared-but-missing output would rebuild on every build.
        var outputs: [URL] = []
        for language in try Self.languages(in: catalog) {
            let lproj = output.appending(path: "\(language).lproj")
            outputs.append(lproj.appending(path: "Localizable.strings"))
            outputs.append(lproj.appending(path: "Localizable.stringsdict"))
        }

        let touch = outputs.map { "'\($0.path)'" }.joined(separator: " ")
        let script = """
            set -e
            /usr/bin/xcrun xcstringstool compile '\(catalog.path)' --output-directory '\(output.path)'
            for f in \(touch); do mkdir -p "$(dirname "$f")"; [ -e "$f" ] || /bin/echo -n > "$f"; done
            """
        return [
            .buildCommand(
                displayName: "Compiling \(target.name) string catalog",
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", script],
                inputFiles: [catalog],
                outputFiles: outputs
            ),
        ]
    }

    /// The source language plus every language with at least one entry.
    /// Read from the catalog itself so adding a language is only ever an
    /// edit to the catalog, never to this plugin or to Package.swift.
    static func languages(in catalog: URL) throws -> [String] {
        let data = try Data(contentsOf: catalog)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ["en"] }
        var languages: Set<String> = [root["sourceLanguage"] as? String ?? "en"]
        for case let entry as [String: Any] in (root["strings"] as? [String: Any] ?? [:]).values {
            for language in (entry["localizations"] as? [String: Any] ?? [:]).keys {
                languages.insert(language)
            }
        }
        return languages.sorted()
    }
}
