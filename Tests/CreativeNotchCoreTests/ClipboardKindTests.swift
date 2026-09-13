import Foundation
import Testing
@testable import CreativeNotchCore

/// Which tile a clipboard row gets. Display only; the content is untouched.
struct ClipboardKindTests {
    @Test func aBareURLIsALink() {
        #expect(ClipboardKind.classify(.text("https://developer.apple.com/x")) == .link)
        #expect(ClipboardKind.classify(.text("  https://a.b  ")) == .link)
    }

    @Test func proseWithAURLInsideIsText() {
        #expect(ClipboardKind.classify(.text("see https://a.b for details")) == .text)
    }

    /// A scheme alone is not a link: `swift:` or `foo:bar` are words.
    @Test func aSchemeWithoutAHostIsText() {
        #expect(ClipboardKind.classify(.text("swift:")) == .text)
    }

    @Test func newlinesOrBracesAreCode() {
        #expect(ClipboardKind.classify(.text("let a = 1\nlet b = 2")) == .code)
        #expect(ClipboardKind.classify(.text("func f() { }")) == .code)
    }

    @Test func imagesAreImages() {
        #expect(ClipboardKind.classify(.image(Data([1]), ext: "png")) == .image)
    }

    @Test func everyKindHasADistinctSymbol() {
        let all: [ClipboardKind] = [.text, .link, .code, .image]
        #expect(Set(all.map(\.symbolName)).count == all.count)
    }
}

/// A clock time, not a relative one (spec §9).
struct ClipboardTimeLabelTests {
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_GB")
        return c
    }()

    private func date(_ s: String) -> Date {
        ISO8601DateFormatter().date(from: s)!
    }

    @Test func sameDayIsAClockTime() {
        let t = ClipboardTimeLabel.text(addedAt: date("2026-09-13T23:38:00Z"),
                                        now: date("2026-09-13T23:41:00Z"), calendar: cal)
        #expect(t == "23:38")
    }

    @Test func anotherDayIsADate() {
        let t = ClipboardTimeLabel.text(addedAt: date("2026-09-12T23:38:00Z"),
                                        now: date("2026-09-13T00:01:00Z"), calendar: cal)
        #expect(t == "12 Sept" || t == "12 Sep")
    }

    /// The label is a function of two instants and nothing else — no
    /// "2m ago" that goes stale while the panel is open.
    @Test func theLabelDoesNotDependOnHowLongAgo() {
        let a = ClipboardTimeLabel.text(addedAt: date("2026-09-13T10:00:00Z"),
                                        now: date("2026-09-13T10:01:00Z"), calendar: cal)
        let b = ClipboardTimeLabel.text(addedAt: date("2026-09-13T10:00:00Z"),
                                        now: date("2026-09-13T22:00:00Z"), calendar: cal)
        #expect(a == b)
        #expect(a == "10:00")
    }
}
