import Foundation
import Testing
@testable import CreativeNotchCore

/// The in-app updater's version arithmetic (2026-10-24).
///
/// Compared as numbers, never as strings: "0.12.10" sorts before "0.12.9"
/// as text, and an updater that compared tags that way would offer a
/// downgrade the day the patch number reached two digits.
struct UpdateVersionTests {

    @Test func parsesATagWithOrWithoutTheLeadingV() throws {
        let tagged = try #require(SemanticVersion("v0.13.0"))
        #expect(tagged == SemanticVersion(major: 0, minor: 13, patch: 0))
        #expect(SemanticVersion("0.13.0") == tagged)
        #expect(SemanticVersion("V1.2.3") == SemanticVersion(major: 1, minor: 2, patch: 3))
        #expect(SemanticVersion(" v1.2.3\n") == SemanticVersion(major: 1, minor: 2, patch: 3))
    }

    /// A shorter version is padded, so "0.13" and "0.13.0" are one release.
    @Test func missingComponentsAreZero() {
        #expect(SemanticVersion("0.13") == SemanticVersion(major: 0, minor: 13, patch: 0))
        #expect(SemanticVersion("2") == SemanticVersion(major: 2, minor: 0, patch: 0))
    }

    @Test func comparesNumericallyNotAsText() throws {
        let v0_13_0 = try #require(SemanticVersion("0.13.0"))
        let v0_12_10 = try #require(SemanticVersion("0.12.10"))
        let v0_12_9 = try #require(SemanticVersion("0.12.9"))
        #expect(v0_13_0 > v0_12_10)
        #expect(v0_12_10 > v0_12_9)
        #expect(v0_12_9 < v0_13_0)
        #expect(try #require(SemanticVersion("1.0.0")) > v0_13_0)
        #expect(!(v0_12_9 < v0_12_9))
    }

    /// Anything that is not one to three dot-separated numbers is refused,
    /// and a refused tag is "no update" — never a guess.
    @Test(arguments: [
        "", "v", "vv1.2.3", "1..2", "1.2.", ".1.2", "1.2.3.4", "1.2.3-beta",
        "1.2.3+build", "one.two", "1.-2.3", "1.2.x", "latest", "１.２.３",
        "99999999999999999999.0.0",
    ])
    func malformedTagsAreRefused(_ text: String) {
        #expect(SemanticVersion(text) == nil, "\(text.debugDescription) parsed")
    }

    @Test func describesItselfWithoutTheV() {
        #expect(SemanticVersion("v0.13.0")?.description == "0.13.0")
        #expect(SemanticVersion("0.13")?.description == "0.13.0")
    }

    // MARK: - Availability

    private static let notes = URL(string: "https://github.com/GcdZ03/CreativeNotch/releases/tag/v0.13.0")!

    private static func release(_ tag: String) -> Release {
        Release(tag: tag, notesURL: notes, archiveURL: nil, checksumURL: nil)
    }

    @Test func aNewerReleaseIsOffered() {
        let newer = Self.release("v0.13.0")
        #expect(UpdateAvailability.newer(newer, than: "0.12.0") == newer)
        #expect(UpdateAvailability.newer(Self.release("v0.12.10"), than: "0.12.9") != nil)
    }

    @Test func theSameOrAnOlderReleaseIsNot() {
        #expect(UpdateAvailability.newer(Self.release("v0.12.0"), than: "0.12.0") == nil)
        #expect(UpdateAvailability.newer(Self.release("v0.11.4"), than: "0.12.0") == nil)
        #expect(UpdateAvailability.newer(Self.release("0.12.9"), than: "0.12.10") == nil)
        #expect(UpdateAvailability.newer(nil, than: "0.12.0") == nil)
    }

    /// A malformed tag, or a malformed running version, offers nothing.
    @Test func aMalformedTagIsNoUpdate() {
        #expect(UpdateAvailability.newer(Self.release("nightly"), than: "0.12.0") == nil)
        #expect(UpdateAvailability.newer(Self.release("v9.0.0-rc1"), than: "0.12.0") == nil)
        #expect(UpdateAvailability.newer(Self.release("v9.0.0"), than: "dev") == nil)
    }

    /// The version this build reports must itself parse, or no release
    /// could ever be offered to it.
    @Test func theRunningVersionParses() {
        #expect(SemanticVersion(CoreInfo.version) != nil)
    }
}
