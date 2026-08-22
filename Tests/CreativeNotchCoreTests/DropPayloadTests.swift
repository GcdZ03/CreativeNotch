import Foundation
import Testing
@testable import CreativeNotchCore

struct DropPayloadTests {

    @Test func aFileKeepsItsOwnName() {
        let payload = DropPayload.file(URL(fileURLWithPath: "/tmp/Report Q3.pdf"))
        #expect(payload.suggestedName == "Report Q3.pdf")
    }

    @Test func aFileWithNoExtensionKeepsItsName() {
        let payload = DropPayload.file(URL(fileURLWithPath: "/tmp/Makefile"))
        #expect(payload.suggestedName == "Makefile")
    }

    @Test func textGetsAGenericName() {
        #expect(DropPayload.text("hello").suggestedName == "Dropped Text.txt")
    }

    @Test func anImageUsesItsExtension() {
        #expect(DropPayload.image(Data(), ext: "png").suggestedName == "Dropped Image.png")
        #expect(DropPayload.image(Data(), ext: "jpeg").suggestedName == "Dropped Image.jpeg")
    }

    @Test func aShelfItemCarriesItsIdentity() {
        let id = UUID()
        let when = Date(timeIntervalSince1970: 1_000)
        let item = ShelfItem(
            id: id,
            url: URL(fileURLWithPath: "/tmp/a.txt"),
            displayName: "a.txt",
            addedAt: when
        )
        #expect(item.id == id)
        #expect(item.displayName == "a.txt")
        #expect(item.addedAt == when)
    }
}
