import Testing
import CoreGraphics
@testable import CreativeNotchCore

// A notched MacBook: 1470x956pt, 38pt notch inset, 620pt of menu bar
// usable on each side of the notch.
private let notched = ScreenMetrics(
    frame: CGRect(x: 0, y: 0, width: 1470, height: 956),
    safeAreaTopInset: 38,
    auxiliaryTopLeftWidth: 620,
    auxiliaryTopRightWidth: 620,
    menuBarHeight: 38
)

// An external display: no safe area, no auxiliary areas.
private let external = ScreenMetrics(
    frame: CGRect(x: 1470, y: 0, width: 2560, height: 1440),
    safeAreaTopInset: 0,
    auxiliaryTopLeftWidth: 0,
    auxiliaryTopRightWidth: 0,
    menuBarHeight: 24
)

@Test func notchedScreenProducesNotchAnchor() {
    guard case .notch(let r) = NotchGeometry.anchor(for: notched) else {
        Issue.record("expected .notch"); return
    }
    #expect(r.width == 230)          // 1470 - (620 + 620)
    #expect(r.height == 38)
    #expect(r.minX == 620)
    #expect(r.maxY == 956)           // flush with the top of the screen
}

@Test func externalScreenProducesPillAnchor() {
    guard case .pill(let r) = NotchGeometry.anchor(for: external) else {
        Issue.record("expected .pill"); return
    }
    #expect(r.width == NotchGeometry.pillSize.width)
    #expect(r.midX == external.frame.midX)
    #expect(r.maxY == 1440 - NotchGeometry.pillMenuBarInset)
    #expect(r.height == 24 - 2 * NotchGeometry.pillMenuBarInset)
}

/// The reported bug (2026-10-26): the pill hung 8pt below the menu bar, so
/// on an external display it covered the top of every maximised window -- a
/// browser's tab strip first. It now sits inside the menu bar, the band no
/// window reaches, at the 24pt bar of older macOS and the 30pt one of macOS 26.
@Test func thePillNeverReachesBelowTheMenuBar() {
    for bar: CGFloat in [24, 30, 37] {
        var m = external
        m.menuBarHeight = bar
        guard case .pill(let r) = NotchGeometry.anchor(for: m) else {
            Issue.record("expected .pill"); return
        }
        #expect(r.minY >= m.frame.maxY - bar)
        #expect(r.maxY <= m.frame.maxY)
        #expect(r.height > 0)
    }
}

// MARK: - Keeping clear of app menus (2026-10-26)

// A portrait external display: narrow enough that an app's menus reach past
// its centre.
private let portrait = ScreenMetrics(
    frame: CGRect(x: 1512, y: 69, width: 1080, height: 1920),
    safeAreaTopInset: 0, auxiliaryTopLeftWidth: 0, auxiliaryTopRightWidth: 0,
    menuBarHeight: 30
)

private func pill(_ m: ScreenMetrics, menusEnd: CGFloat) -> CGRect? {
    guard case .pill(let r) = NotchGeometry.anchor(for: m, menusEnd: menusEnd) else { return nil }
    return r
}

/// Menus that end short of the closed pill leave it centred.
@Test func shortMenusLeaveThePillCentred() {
    #expect(pill(portrait, menusEnd: 300)?.midX == portrait.frame.midX)
    #expect(pill(portrait, menusEnd: 0)?.midX == portrait.frame.midX)
}

/// The reported case: menus reaching past the centre. The pill moves right
/// until even its widest closed shape -- the idle capsule, or every activity
/// at once (2026-10-29) -- starts `pillMenuGap` past the last menu.
@Test func longMenusPushThePillJustPastThem() throws {
    for end: CGFloat in [450, 500, 600] {
        let r = try #require(pill(portrait, menusEnd: end))
        let widestLeft = r.midX - NotchGeometry.pillClosedMaxWidth / 2
        #expect(widestLeft == portrait.frame.minX + end + NotchGeometry.pillMenuGap)
    }
}

/// Every badge fits inside the width the pill keeps clear for.
@Test func theClearedWidthHoldsEveryBadge() {
    let slots: [BadgeSlot] = [.nowPlaying, .timer, .recording, .capture, .downloads]
    for slot in slots {
        #expect(slot.width + slot.leadingWidth <= NotchGeometry.pillClosedMaxWidth)
    }
    #expect(NotchGeometry.pillIdleWidth <= NotchGeometry.pillClosedMaxWidth)
}

/// Menus too long to clear stop the pill where the open panel still fits on
/// the display around it, rather than at the edge where it would be cut off.
@Test func menusTooLongToClearStopThePillWhereThePanelStillFits() throws {
    let r = try #require(pill(portrait, menusEnd: 1000))
    #expect(r.midX == portrait.frame.maxX - NotchGeometry.expandedSize.width / 2)
}

/// A real notch is where the hardware is; the menus never move it.
@Test func menusNeverMoveARealNotch() {
    #expect(NotchGeometry.anchor(for: notched, menusEnd: 900) == NotchGeometry.anchor(for: notched))
}

/// An auto-hidden menu bar measures 0, leaving no band to sit in: the pill
/// keeps its old place, a gap below the top edge at its full size.
@Test func withNoMenuBarThePillHangsBelowTheTopEdge() {
    var m = external
    m.menuBarHeight = 0
    guard case .pill(let r) = NotchGeometry.anchor(for: m) else {
        Issue.record("expected .pill"); return
    }
    #expect(r.size == NotchGeometry.pillSize)
    #expect(r.midX == m.frame.midX)
    #expect(r.maxY == 1440 - NotchGeometry.pillTopGap)
}

@Test func zeroAuxiliaryWidthsFallBackToPill() {
    // A safe-area inset with no auxiliary areas is not a usable notch.
    let odd = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1470, height: 956),
        safeAreaTopInset: 38,
        auxiliaryTopLeftWidth: 0,
        auxiliaryTopRightWidth: 0,
        menuBarHeight: 38
    )
    guard case .pill = NotchGeometry.anchor(for: odd) else {
        Issue.record("expected .pill"); return
    }
}

@Test func panelIsCenteredOnAnchorAndTopAligned() {
    let anchor = NotchGeometry.anchor(for: notched)
    let frame = NotchGeometry.panelFrame(for: anchor, in: notched)
    #expect(frame.width == NotchGeometry.expandedSize.width)
    #expect(frame.height == NotchGeometry.expandedSize.height)
    #expect(frame.midX == anchor.rect.midX)
    #expect(frame.maxY == anchor.rect.maxY)
}

@Test func panelIsClampedToScreenBounds() {
    // A pill hard against the left edge must not push the panel off-screen.
    let narrow = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 800, height: 600),
        safeAreaTopInset: 0,
        auxiliaryTopLeftWidth: 0,
        auxiliaryTopRightWidth: 0,
        menuBarHeight: 24
    )
    let anchor = Anchor.pill(CGRect(x: 0, y: 560, width: 180, height: 32))
    let frame = NotchGeometry.panelFrame(for: anchor, in: narrow)
    #expect(frame.minX >= narrow.frame.minX)
    #expect(frame.maxX <= narrow.frame.maxX)
}

@Test func panelIsClampedAtRightEdge() {
    // A pill hard against the right edge must not push the panel off-screen.
    let narrow = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 800, height: 600),
        safeAreaTopInset: 0,
        auxiliaryTopLeftWidth: 0,
        auxiliaryTopRightWidth: 0,
        menuBarHeight: 24
    )
    let anchor = Anchor.pill(CGRect(x: 620, y: 560, width: 180, height: 32))
    let frame = NotchGeometry.panelFrame(for: anchor, in: narrow)
    #expect(frame.maxX <= narrow.frame.maxX)
    #expect(frame.minX == 180)  // Clamped: 800 - 620 = 180
}

// MARK: - Off-origin screens
//
// Everything above places the screen at the global origin, which makes
// `frame.minX == 0` and `frame.maxY == frame.height` — so a geometry
// expression that dropped `frame.minX` or confused `frame.maxY` with
// `frame.height` would still pass. macOS puts the *primary* screen at the
// origin, not the built-in one: set an external display as primary and the
// notched built-in gets a non-zero `minX`, and a non-zero `minY` if it sits
// below the primary. These tests pin the absolute positions.

// The same notched MacBook as above, but repositioned to the right of and
// above the global origin, as it would be when an external display is
// primary.
private let notchedOffOrigin = ScreenMetrics(
    frame: CGRect(x: 1470, y: 200, width: 1470, height: 956),
    safeAreaTopInset: 38,
    auxiliaryTopLeftWidth: 620,
    auxiliaryTopRightWidth: 620,
    menuBarHeight: 38
)

@Test func notchAnchorLandsInAbsoluteScreenCoordinates() {
    guard case .notch(let r) = NotchGeometry.anchor(for: notchedOffOrigin) else {
        Issue.record("expected .notch"); return
    }
    // x: screen origin + the left auxiliary area, not the auxiliary area alone.
    #expect(r.minX == 2090)          // 1470 + 620
    #expect(r.width == 230)
    // y: measured down from the screen's *top edge in global space*
    // (200 + 956), not from its height.
    #expect(r.maxY == 1156)
    #expect(r.minY == 1118)          // 1156 - 38
}

@Test func panelFrameLandsInAbsoluteScreenCoordinates() {
    let anchor = NotchGeometry.anchor(for: notchedOffOrigin)
    let frame = NotchGeometry.panelFrame(for: anchor, in: notchedOffOrigin)
    #expect(frame == CGRect(x: 1895, y: 896, width: 620, height: 260))
    #expect(frame.midX == anchor.rect.midX)
    #expect(frame.maxY == anchor.rect.maxY)
}

@Test func panelOnASecondaryScreenClampsToThatScreenNotTheGlobalOrigin() {
    // A narrow display parked to the right of the primary. The anchor sits
    // hard against *its* left edge, so the 620pt panel must clamp to
    // `frame.minX` (1470) — clamping to a global 0 would fling the panel
    // onto the primary display.
    let secondary = ScreenMetrics(
        frame: CGRect(x: 1470, y: 0, width: 800, height: 600),
        safeAreaTopInset: 0,
        auxiliaryTopLeftWidth: 0,
        auxiliaryTopRightWidth: 0,
        menuBarHeight: 24
    )
    let anchor = Anchor.pill(CGRect(x: 1470, y: 560, width: 180, height: 32))
    let frame = NotchGeometry.panelFrame(for: anchor, in: secondary)
    #expect(frame.minX == 1470)      // unclamped would be 1560 - 310 = 1250
    #expect(frame.maxX <= secondary.frame.maxX)
}

// MARK: - F11: a screen narrower than the panel

/// The clamp keeps the panel on screen from both edges, but the right
/// bound sits left of the left bound once the screen is narrower than the
/// panel. Left has to win, or clamping pushes the panel off the near edge
/// while trying to hold the far one.
@Test func aScreenNarrowerThanThePanelClampsToItsLeftEdge() {
    let tiny = ScreenMetrics(
        frame: CGRect(x: 300, y: 0, width: 400, height: 300),
        safeAreaTopInset: 0,
        auxiliaryTopLeftWidth: 0,
        auxiliaryTopRightWidth: 0,
        menuBarHeight: 24
    )
    let anchor = NotchGeometry.anchor(for: tiny)
    let frame = NotchGeometry.panelFrame(for: anchor, in: tiny)

    // The panel is wider than the screen, so it cannot fit -- but it must
    // still start at the screen's left edge rather than left of it.
    #expect(frame.width == NotchGeometry.expandedSize.width)
    #expect(frame.minX == tiny.frame.minX)
}
