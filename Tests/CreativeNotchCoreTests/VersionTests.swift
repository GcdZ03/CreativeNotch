import Testing
@testable import CreativeNotchCore

@Test func versionIsNonEmpty() {
    #expect(!CreativeNotchCore.version.isEmpty)
}
