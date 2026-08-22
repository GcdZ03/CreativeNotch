import Testing
@testable import CreativeNotchCore

@Test func versionIsNonEmpty() {
    #expect(!CoreInfo.version.isEmpty)
}
