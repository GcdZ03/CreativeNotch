import Foundation
import Testing
@testable import CreativeNotchCore

/// What the updater reads out of GitHub's `releases/latest` (2026-10-24),
/// and what it makes of each reply.
///
/// The JSON here is trimmed from a real response's shape; every field the
/// parser does not read is left out, except one or two that prove extra
/// fields are ignored.
struct UpdateReleaseTests {

    static func json(
        tag: String = "v0.13.0",
        html: String = "https://github.com/GcdZ03/CreativeNotch/releases/tag/v0.13.0",
        assets: [(String, String)]? = nil
    ) -> Data {
        let list = assets ?? [
            ("CreativeNotch-\(tag).tar.gz",
             "https://github.com/GcdZ03/CreativeNotch/releases/download/\(tag)/CreativeNotch-\(tag).tar.gz"),
            ("CreativeNotch-\(tag).tar.gz.sha256",
             "https://github.com/GcdZ03/CreativeNotch/releases/download/\(tag)/CreativeNotch-\(tag).tar.gz.sha256"),
        ]
        let assetJSON = list.map { name, url in
            #"{"name": "\#(name)", "size": 1234, "browser_download_url": "\#(url)"}"#
        }.joined(separator: ",")
        return Data(#"""
        {"url": "https://api.github.com/repos/GcdZ03/CreativeNotch/releases/1",
         "tag_name": "\#(tag)", "name": "CreativeNotch \#(tag)", "draft": false,
         "html_url": "\#(html)", "assets": [\#(assetJSON)]}
        """#.utf8)
    }

    // MARK: - Parsing

    @Test func parsesTheTagNotesAndBothAssets() throws {
        let release = try #require(Release.parse(Self.json()))
        #expect(release.tag == "v0.13.0")
        #expect(release.version == SemanticVersion(major: 0, minor: 13, patch: 0))
        #expect(release.notesURL.absoluteString == "https://github.com/GcdZ03/CreativeNotch/releases/tag/v0.13.0")
        #expect(release.archiveURL?.lastPathComponent == "CreativeNotch-v0.13.0.tar.gz")
        #expect(release.checksumURL?.lastPathComponent == "CreativeNotch-v0.13.0.tar.gz.sha256")
        #expect(release.isInstallable)
    }

    /// The names `release.yml` gives them: `CreativeNotch-<tag>.tar.gz` and
    /// that name plus `.sha256`.
    @Test func theAssetNamesFollowTheReleaseWorkflow() throws {
        let release = try #require(Release.parse(Self.json(tag: "v1.2.3")))
        #expect(release.archiveName == "CreativeNotch-v1.2.3.tar.gz")
        #expect(release.checksumName == "CreativeNotch-v1.2.3.tar.gz.sha256")
    }

    /// Only the asset named for this tag is taken, not any `.tar.gz` — a
    /// stray source archive or a renamed upload must not be installed.
    @Test func anAssetWithAnotherNameIsIgnored() throws {
        let release = try #require(Release.parse(Self.json(assets: [
            ("source.tar.gz", "https://github.com/x/source.tar.gz"),
            ("CreativeNotch-v0.12.0.tar.gz", "https://github.com/x/CreativeNotch-v0.12.0.tar.gz"),
        ])))
        #expect(release.archiveURL == nil)
        #expect(release.checksumURL == nil)
        #expect(!release.isInstallable)
    }

    /// Without its checksum a release can be announced but not installed:
    /// nothing is installed unverified.
    @Test func anArchiveWithoutItsChecksumIsNotInstallable() throws {
        let release = try #require(Release.parse(Self.json(assets: [
            ("CreativeNotch-v0.13.0.tar.gz", "https://github.com/x/CreativeNotch-v0.13.0.tar.gz"),
        ])))
        #expect(release.archiveURL != nil)
        #expect(!release.isInstallable)
    }

    /// Plain HTTP is refused for everything the app downloads or opens.
    @Test func nonHTTPSLinksAreRefused() throws {
        let insecure = try #require(Release.parse(Self.json(assets: [
            ("CreativeNotch-v0.13.0.tar.gz", "http://github.com/x/CreativeNotch-v0.13.0.tar.gz"),
            ("CreativeNotch-v0.13.0.tar.gz.sha256", "http://github.com/x/CreativeNotch-v0.13.0.tar.gz.sha256"),
        ])))
        #expect(insecure.archiveURL == nil)
        #expect(insecure.checksumURL == nil)
        #expect(Release.parse(Self.json(html: "http://github.com/GcdZ03/CreativeNotch")) == nil)
        #expect(Release.parse(Self.json(html: "file:///etc/passwd")) == nil)
    }

    @Test func malformedReplies() {
        #expect(Release.parse(Data()) == nil)
        #expect(Release.parse(Data("not json".utf8)) == nil)
        #expect(Release.parse(Data(#"{"message": "Not Found"}"#.utf8)) == nil)
        #expect(Release.parse(Data(#"{"tag_name": "v1.0.0"}"#.utf8)) == nil)
    }

    /// A release with no assets array still parses: it can be announced,
    /// with its notes, even though it cannot be installed.
    @Test func aReleaseWithNoAssetsStillParses() throws {
        let data = Data(#"{"tag_name": "v1.0.0", "html_url": "https://github.com/GcdZ03/CreativeNotch/releases/tag/v1.0.0"}"#.utf8)
        let release = try #require(Release.parse(data))
        #expect(!release.isInstallable)
    }

    /// A malformed tag parses — the reply was fine — and is simply never
    /// newer than anything.
    @Test func aMalformedTagParsesButHasNoVersion() throws {
        let release = try #require(Release.parse(Self.json(tag: "nightly")))
        #expect(release.version == nil)
    }

    @Test func roundTripsThroughCodableForTheCache() throws {
        let release = try #require(Release.parse(Self.json()))
        let data = try JSONEncoder().encode(release)
        #expect(try JSONDecoder().decode(Release.self, from: data) == release)
    }

    // MARK: - Replies

    private static func reply(
        _ status: Int, body: Data = Data(), etag: String? = nil, remaining: String? = nil
    ) -> HTTPReply {
        HTTPReply(status: status, body: body, etag: etag, rateLimitRemaining: remaining)
    }

    @Test func a200IsAFreshRelease() throws {
        let result = UpdateCheckResult.classify(Self.reply(200, body: Self.json(), etag: #"W/"abc""#))
        let release = try #require(Release.parse(Self.json()))
        #expect(result == .fresh(release, etag: #"W/"abc""#))
    }

    @Test func a304IsNotModified() {
        #expect(UpdateCheckResult.classify(Self.reply(304)) == .notModified)
    }

    /// GitHub signals its unauthenticated limit with a 403 whose remaining
    /// count is zero, or a 429. Either is quiet.
    @Test func rateLimitingIsRecognised() {
        #expect(UpdateCheckResult.classify(Self.reply(403, remaining: "0")) == .failed(.rateLimited))
        #expect(UpdateCheckResult.classify(Self.reply(429)) == .failed(.rateLimited))
        #expect(UpdateCheckResult.classify(Self.reply(403, remaining: "12")) == .failed(.unexpected))
    }

    @Test func noReplyAtAllIsOffline() {
        #expect(UpdateCheckResult.classify(nil) == .failed(.offline))
    }

    @Test func otherStatusesAndBadBodiesAreUnexpected() {
        #expect(UpdateCheckResult.classify(Self.reply(404)) == .failed(.unexpected))
        #expect(UpdateCheckResult.classify(Self.reply(500)) == .failed(.unexpected))
        #expect(UpdateCheckResult.classify(Self.reply(200, body: Data("{}".utf8))) == .failed(.unexpected))
    }

    // MARK: - The request

    @Test func theRequestNamesItselfAndAsksForTheAPIVersion() {
        let headers = UpdateEndpoint.headers(version: "0.12.0", etag: nil)
        #expect(headers["User-Agent"] == "CreativeNotch/0.12.0")
        #expect(headers["Accept"] == "application/vnd.github+json")
        #expect(headers["If-None-Match"] == nil)
    }

    @Test func anETagIsSentBack() {
        let headers = UpdateEndpoint.headers(version: "0.12.0", etag: #"W/"abc""#)
        #expect(headers["If-None-Match"] == #"W/"abc""#)
    }

    /// The same endpoint `Scripts/install.sh` asks.
    @Test func theEndpointIsTheInstallersOwn() throws {
        #expect(UpdateEndpoint.latestRelease.absoluteString
            == "https://api.github.com/repos/GcdZ03/CreativeNotch/releases/latest")
        let script = try String(contentsOf: Self.repoRoot.appendingPathComponent("Scripts/install.sh"), encoding: .utf8)
        #expect(script.contains(#"REPO="GcdZ03/CreativeNotch""#))
        #expect(script.contains(#"API="https://api.github.com/repos/$REPO/releases/latest""#))
    }

    /// The one-line command shown when the app cannot update itself is the
    /// README's.
    @Test func theInstallCommandIsTheREADMEs() throws {
        let readme = try String(contentsOf: Self.repoRoot.appendingPathComponent("README.md"), encoding: .utf8)
        #expect(readme.contains(UpdateInstallEligibility.installCommand))
    }

    // MARK: - Checksums

    static let digest = String(repeating: "ab", count: 32)

    /// `shasum -a 256 NAME > NAME.sha256` writes "<hex>  <name>\n".
    @Test func readsTheShasumLine() {
        let text = "\(Self.digest)  CreativeNotch-v0.13.0.tar.gz\n"
        #expect(ReleaseChecksum.expected(in: text, for: "CreativeNotch-v0.13.0.tar.gz") == Self.digest)
        // Binary-mode marker, and a bare digest.
        #expect(ReleaseChecksum.expected(in: "\(Self.digest) *CreativeNotch-v0.13.0.tar.gz", for: "CreativeNotch-v0.13.0.tar.gz") == Self.digest)
        #expect(ReleaseChecksum.expected(in: Self.digest.uppercased(), for: "x") == Self.digest)
    }

    @Test func refusesAChecksumForAnotherFileOrOfTheWrongShape() {
        #expect(ReleaseChecksum.expected(in: "\(Self.digest)  other.tar.gz", for: "CreativeNotch-v0.13.0.tar.gz") == nil)
        #expect(ReleaseChecksum.expected(in: "abc  CreativeNotch-v0.13.0.tar.gz", for: "CreativeNotch-v0.13.0.tar.gz") == nil)
        #expect(ReleaseChecksum.expected(in: String(repeating: "g", count: 64), for: "x") == nil)
        #expect(ReleaseChecksum.expected(in: "", for: "x") == nil)
    }

    @Test func comparesDigestsIgnoringCase() {
        #expect(ReleaseChecksum.matches(Self.digest, digest: Self.digest.uppercased()))
        #expect(!ReleaseChecksum.matches(Self.digest, digest: String(repeating: "cd", count: 32)))
        #expect(!ReleaseChecksum.matches(Self.digest, digest: ""))
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
