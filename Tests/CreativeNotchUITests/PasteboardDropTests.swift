import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// Converting a real `NSPasteboard` into AppKit-free payloads.
///
/// A named pasteboard is used rather than the general one so the tests
/// cannot disturb the machine's actual clipboard.
@MainActor
struct PasteboardDropTests {

    private func makePasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("CreativeNotchTest-\(UUID().uuidString)"))
        pb.clearContents()
        return pb
    }

    @Test func fileURLsBecomeFilePayloads() throws {
        let pb = makePasteboard()
        let a = URL(fileURLWithPath: "/tmp/one.txt")
        let b = URL(fileURLWithPath: "/tmp/two.txt")
        pb.writeObjects([a as NSURL, b as NSURL])

        #expect(pb.dropPayloads() == [.file(a), .file(b)])
    }

    @Test func plainTextBecomesATextPayload() throws {
        let pb = makePasteboard()
        pb.setString("hello there", forType: .string)

        #expect(pb.dropPayloads() == [.text("hello there")])
    }

    @Test func aFileURLWinsOverTheStringRepresentation() throws {
        // Dragging a file also puts its path on the pasteboard as a string.
        // Taking both would stash the file twice.
        let pb = makePasteboard()
        let url = URL(fileURLWithPath: "/tmp/thing.pdf")
        pb.writeObjects([url as NSURL])
        pb.setString("/tmp/thing.pdf", forType: .string)

        #expect(pb.dropPayloads() == [.file(url)])
    }

    /// A link dragged from a browser is an `NSURL` too. Read as a file it
    /// became `.file(https://...)`, `copyItem` threw, and the whole drop was
    /// refused -- rather than falling through to the kinds that can hold it.
    @Test func aWebURLIsNotTreatedAsAFile() throws {
        let pb = makePasteboard()
        let link = try #require(URL(string: "https://example.com/picture.png"))
        pb.writeObjects([link as NSURL])

        let payloads = pb.dropPayloads()

        #expect(payloads.contains { if case .file = $0 { true } else { false } } == false,
                "a web link was offered to the shelf as a file it can never copy")
    }

    @Test func anEmptyPasteboardYieldsNothing() {
        #expect(makePasteboard().dropPayloads().isEmpty)
    }

    @Test func whitespaceOnlyTextIsIgnored() {
        let pb = makePasteboard()
        pb.setString("   \n  ", forType: .string)
        #expect(pb.dropPayloads().isEmpty)
    }
}
