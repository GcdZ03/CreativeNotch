import Foundation
import CoreGraphics
import Testing
@testable import CreativeNotchCore

/// "Layout" in Settings (2026-10-24): the panel's width, its corners, which
/// ear holds the tabs, the header's battery and the closed notch's badges --
/// what a stored value means, and what each option does to the geometry.
struct LayoutOptionsTests {

    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "com.gcdz.creativenotch.layout-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    /// 14" MacBook Pro: a 190×32 notch centred on a 1512-wide screen.
    private let fourteen = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        safeAreaTopInset: 32, auxiliaryTopLeftWidth: 661, auxiliaryTopRightWidth: 661, menuBarHeight: 32
    )

    /// An external display: no notch, so a pill under the menu bar.
    private let external = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        safeAreaTopInset: 0, auxiliaryTopLeftWidth: 0, auxiliaryTopRightWidth: 0, menuBarHeight: 24
    )

    // MARK: - The setting

    /// Every default is the look from before the setting.
    @Test func theDefaultsAreTheLookFromBeforeTheSetting() {
        let o = LayoutOptions()
        #expect(o == .default)
        #expect(o.width == .standard)
        #expect(o.corners == .standard)
        #expect(o.tabsSide == .left)
        #expect(o.showsBattery)
        #expect(o.showsNowPlayingBadge)
        #expect(o.showsTimerBadge)
        #expect(o.hiddenBadges.isEmpty)
        #expect(PanelWidth.standard.nominalWidth == NotchGeometry.expandedSize.width)
        #expect(PanelCorners.standard.radius == NotchGeometry.panelCornerRadius)
    }

    @Test func theChoicesAreOrderedForTheMenus() {
        #expect(PanelWidth.allCases == [.compact, .standard, .wide])
        #expect(PanelCorners.allCases == [.tight, .standard, .round])
        #expect(EarSide.allCases == [.left, .right])
        #expect(PanelWidth.compact.nominalWidth < PanelWidth.standard.nominalWidth)
        #expect(PanelWidth.wide.nominalWidth > PanelWidth.standard.nominalWidth)
        #expect(PanelCorners.tight.radius < PanelCorners.standard.radius)
        #expect(PanelCorners.round.radius > PanelCorners.standard.radius)
    }

    @Test func anEmptyDomainIsTheDefault() {
        let defaults = makeIsolatedDefaults()
        #expect(PreferencesStore(defaults: defaults).loadLayout() == .default)
    }

    @Test func everyOptionSurvivesAReload() {
        let defaults = makeIsolatedDefaults()
        var o = LayoutOptions()
        o.width = .wide
        o.corners = .round
        o.tabsSide = .right
        o.showsBattery = false
        o.showsNowPlayingBadge = false
        o.showsTimerBadge = false
        PreferencesStore(defaults: defaults).saveLayout(o)
        #expect(PreferencesStore(defaults: defaults).loadLayout() == o)
        #expect(defaults.string(forKey: PreferenceKeys.layoutWidth) == "wide")
        #expect(defaults.string(forKey: PreferenceKeys.layoutCorners) == "round")
        #expect(defaults.string(forKey: PreferenceKeys.layoutTabsSide) == "right")
        #expect(defaults.object(forKey: PreferenceKeys.layoutShowsBattery) as? Bool == false)
    }

    /// Hand-typed junk reads as the default and is left in place for
    /// `defaults read`, the policy every other key follows.
    @Test func aMangledStoredValueReadsAsTheDefaultAndIsNotRewritten() {
        let defaults = makeIsolatedDefaults()
        defaults.set("huge", forKey: PreferenceKeys.layoutWidth)
        defaults.set(3, forKey: PreferenceKeys.layoutCorners)
        defaults.set("middle", forKey: PreferenceKeys.layoutTabsSide)
        defaults.set("no", forKey: PreferenceKeys.layoutShowsBattery)
        #expect(PreferencesStore(defaults: defaults).loadLayout() == .default)
        #expect(defaults.string(forKey: PreferenceKeys.layoutWidth) == "huge")
        #expect(defaults.string(forKey: PreferenceKeys.layoutShowsBattery) == "no")
    }

    // MARK: - Width

    /// Default is exactly the frame the panel has always had, at every text
    /// size, on a notch and on a pill.
    @Test func theDefaultWidthIsTheFrameFromBeforeTheSetting() {
        for m in [fourteen, external] {
            let anchor = NotchGeometry.anchor(for: m)
            for size in TextSize.allCases {
                #expect(NotchGeometry.panelFrame(for: anchor, in: m, textScale: size.scale, width: .standard)
                        == NotchGeometry.panelFrame(for: anchor, in: m, textScale: size.scale))
            }
        }
        let anchor = NotchGeometry.anchor(for: fourteen)
        #expect(NotchGeometry.panelFrame(for: anchor, in: fourteen, width: .standard).size
                == NotchGeometry.expandedSize)
    }

    /// Wide is wider, still centred on the notch and flush with the top.
    @Test func wideIsWiderAndStillCentredOnTheNotch() {
        let anchor = NotchGeometry.anchor(for: fourteen)
        let frame = NotchGeometry.panelFrame(for: anchor, in: fourteen, width: .wide)
        #expect(frame.width == PanelWidth.wide.nominalWidth)
        #expect(frame.height == NotchGeometry.expandedSize.height)
        #expect(frame.midX == anchor.rect.midX)
        #expect(frame.maxY == anchor.rect.maxY)
    }

    /// Wide grows with the text like the default does.
    @Test func wideGrowsWithTheText() {
        let anchor = NotchGeometry.anchor(for: fourteen)
        let frame = NotchGeometry.panelFrame(
            for: anchor, in: fourteen, textScale: TextSize.larger.scale, width: .wide
        )
        #expect(frame.width == NotchType.length(PanelWidth.wide.nominalWidth, scale: TextSize.larger.scale))
        #expect(frame.height == 338)
    }

    /// On a pill there is no housing, so Compact is its nominal width.
    @Test func compactOnAPillIsItsNominalWidth() {
        let anchor = NotchGeometry.anchor(for: external)
        let frame = NotchGeometry.panelFrame(for: anchor, in: external, width: .compact)
        #expect(frame.width == PanelWidth.compact.nominalWidth)
        #expect(frame.midX == anchor.rect.midX)
    }

    /// Beside a real notch, Compact goes no narrower than the tabs need:
    /// with every tab showing on a 14" notch that is wider than nominal,
    /// with four it is not.
    @Test func compactBesideANotchKeepsRoomForTheTabs() {
        let anchor = NotchGeometry.anchor(for: fourteen)
        let five = NotchGeometry.panelFrame(for: anchor, in: fourteen, width: .compact, tabCount: 5)
        #expect(five.width == anchor.rect.width + 2 * PanelLayout.tabEarWidth(tabCount: 5))
        #expect(five.width > PanelWidth.compact.nominalWidth)
        #expect(five.width < PanelWidth.standard.nominalWidth)
        #expect(five.midX == anchor.rect.midX)

        let four = NotchGeometry.panelFrame(for: anchor, in: fourteen, width: .compact, tabCount: 4)
        #expect(four.width == PanelWidth.compact.nominalWidth)
    }

    /// The tabs' ear fits them, at every width, text size and tab count, on
    /// a 14" notch -- whichever side holds them.
    @Test func theTabsAlwaysFitTheirEarOnAFourteenInchNotch() {
        let anchor = NotchGeometry.anchor(for: fourteen)
        for width in PanelWidth.allCases {
            for size in TextSize.allCases {
                for count in 0...Tab.allCases.count {
                    for side in EarSide.allCases {
                        let frame = NotchGeometry.panelFrame(
                            for: anchor, in: fourteen, textScale: size.scale, width: width, tabCount: count
                        )
                        let layout = PanelLayout.resolve(
                            anchor: anchor, panelFrame: frame, showsMedia: true,
                            textScale: size.scale, tabsSide: side
                        )
                        #expect(layout.tabsEarWidth >= PanelLayout.tabEarWidth(tabCount: count, scale: size.scale),
                                "\(count) tabs overflow a \(width) panel at \(size) on the \(side)")
                    }
                }
            }
        }
    }

    /// Clamped to a screen narrower than the panel, never pushed off it.
    @Test func everyWidthStaysOnASmallScreen() {
        let small = ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 680, height: 400),
            safeAreaTopInset: 0, auxiliaryTopLeftWidth: 0, auxiliaryTopRightWidth: 0, menuBarHeight: 24
        )
        let anchor = NotchGeometry.anchor(for: small)
        for width in PanelWidth.allCases {
            let frame = NotchGeometry.panelFrame(
                for: anchor, in: small, textScale: TextSize.larger.scale, width: width
            )
            #expect(frame.minX >= small.frame.minX)
            #expect(frame.maxX <= small.frame.maxX)
        }
    }

    // MARK: - Which ear holds the tabs

    /// Left is today's header; Right swaps the two ears' contents and
    /// leaves their widths, and the housing between them, alone.
    @Test func theTabsSideNamesTheEarWithoutMovingTheHousing() {
        let anchor = NotchGeometry.anchor(for: fourteen)
        let frame = NotchGeometry.panelFrame(for: anchor, in: fourteen)
        let left = PanelLayout.resolve(anchor: anchor, panelFrame: frame, showsMedia: true)
        let right = PanelLayout.resolve(anchor: anchor, panelFrame: frame, showsMedia: true, tabsSide: .right)
        #expect(left.tabsSide == .left)
        #expect(left.tabsEarWidth == left.leadingEarWidth)
        #expect(left.statusEarWidth == left.trailingEarWidth)
        #expect(right.tabsSide == .right)
        #expect(right.tabsEarWidth == right.trailingEarWidth)
        #expect(right.statusEarWidth == right.leadingEarWidth)
        #expect(left.leadingEarWidth == right.leadingEarWidth)
        #expect(left.notchGap == right.notchGap)
        #expect(left.mediaColumnWidth == right.mediaColumnWidth)
    }

    /// Off-centre, clamped to a screen edge, the tabs still get the ear on
    /// their side -- measured from the real notch, not the panel's centre.
    @Test func theTabsSideFollowsTheRealNotchOnAClampedPanel() {
        let anchor = Anchor.notch(CGRect(x: 100, y: 950, width: 190, height: 32))
        let frame = CGRect(x: 0, y: 722, width: 620, height: 260)
        let right = PanelLayout.resolve(anchor: anchor, panelFrame: frame, showsMedia: false, tabsSide: .right)
        #expect(right.leadingEarWidth == 100)
        #expect(right.tabsEarWidth == 330)
    }

    // MARK: - Corners

    /// The corner style rounds the open panel only. The closed notch keeps
    /// the hardware's radius and a peek keeps the panel's own, both being
    /// sized into the camera housing's band.
    @Test func theCornerStyleRoundsTheOpenPanelOnly() {
        let notch = NotchGeometry.anchor(for: fourteen)
        for corners in PanelCorners.allCases {
            let open = NotchShape.cornerRadii(presentation: .expanded, anchor: notch, corners: corners)
            #expect(open.bottomLeading == corners.radius)
            #expect(open.bottomTrailing == corners.radius)
            #expect(open.topLeading == 0)
            #expect(open.topTrailing == 0)
            for presentation in [NotchShape.Presentation.closed, .peek, .statusPeek, .mediaPeek] {
                #expect(NotchShape.cornerRadii(presentation: presentation, anchor: notch, corners: corners)
                        == NotchShape.cornerRadii(presentation: presentation, anchor: notch))
            }
        }
    }

    /// A pill's open panel rounds every corner by the style.
    @Test func aPillsOpenPanelRoundsEveryCornerByTheStyle() {
        let pill = NotchGeometry.anchor(for: external)
        let r = NotchShape.cornerRadii(presentation: .expanded, anchor: pill, corners: .round)
        #expect([r.topLeading, r.bottomLeading, r.bottomTrailing, r.topTrailing]
                == Array(repeating: PanelCorners.round.radius, count: 4))
        #expect(NotchShape.cornerRadii(presentation: .closed, anchor: pill, corners: .round)
                == NotchShape.cornerRadii(presentation: .closed, anchor: pill))
    }

    @Test func theDefaultCornersAreTheRadiiFromBeforeTheSetting() {
        let notch = NotchGeometry.anchor(for: fourteen)
        #expect(NotchShape.cornerRadii(presentation: .expanded, anchor: notch, corners: .standard)
                == NotchShape.cornerRadii(presentation: .expanded, anchor: notch))
    }

    // MARK: - Badges

    private let now = Date(timeIntervalSinceReferenceDate: 0)
    private var running: Countdown { Countdown(duration: 600, startingAt: now)! }
    private let playing = TrackSnapshot(title: "Song", artist: "Artist", isPlaying: true)

    @Test func aHiddenTimerBadgeGivesTheSlotToMedia() {
        var o = LayoutOptions()
        o.showsTimerBadge = false
        #expect(o.hiddenBadges == [.timer])
        #expect(NotchShape.badgeSlot(countdown: running, nowPlaying: playing, hiding: o.hiddenBadges, at: now)
                == .nowPlaying)
        #expect(NotchShape.badgeSlot(countdown: running, nowPlaying: nil, hiding: o.hiddenBadges, at: now)
                == .none)
    }

    @Test func aHiddenNowPlayingBadgeLeavesTheNotchBare() {
        var o = LayoutOptions()
        o.showsNowPlayingBadge = false
        #expect(o.hiddenBadges == [.nowPlaying])
        #expect(NotchShape.badgeSlot(countdown: nil, nowPlaying: playing, hiding: o.hiddenBadges, at: now)
                == .none)
        #expect(NotchShape.badgeSlot(countdown: running, nowPlaying: playing, hiding: o.hiddenBadges, at: now)
                == .timer)
    }

    /// Both hidden: nothing of the user's own grows the notch.
    @Test func bothHiddenLeaveTheNotchBare() {
        var o = LayoutOptions()
        o.showsNowPlayingBadge = false
        o.showsTimerBadge = false
        #expect(NotchShape.badgeSlot(countdown: running, nowPlaying: playing, hiding: o.hiddenBadges, at: now)
                == .none)
    }

    /// The recording dot and the capture indicator cannot be hidden here:
    /// the first is what explains a camera left on after the panel closed,
    /// the second is a module of its own with its own switch.
    @Test func theRecordingAndCaptureBadgesCannotBeHidden() {
        let everything: Set<BadgeSlot> = [.nowPlaying, .timer, .recording, .capture]
        #expect(NotchShape.badgeSlot(countdown: running, nowPlaying: playing, isRecording: true,
                                     hiding: everything, at: now) == .recording)
        #expect(NotchShape.badgeSlot(countdown: running, nowPlaying: playing,
                                     capture: CaptureUse(microphone: true, camera: false),
                                     hiding: everything, at: now) == .capture)
    }

    @Test func nothingHiddenIsTheRuleFromBeforeTheSetting() {
        #expect(NotchShape.badgeSlot(countdown: running, nowPlaying: playing, hiding: [], at: now)
                == NotchShape.badgeSlot(countdown: running, nowPlaying: playing, at: now))
    }
}
