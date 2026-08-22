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

    @Test func anEmptyPasteboardYieldsNothing() {
        #expect(makePasteboard().dropPayloads().isEmpty)
    }

    @Test func whitespaceOnlyTextIsIgnored() {
        let pb = makePasteboard()
        pb.setString("   \n  ", forType: .string)
        #expect(pb.dropPayloads().isEmpty)
    }
}
