import Foundation
import CoreGraphics
import Testing
@testable import CreativeNotchCore

/// "Text size" (2026-10-24): the setting, what a stored value means, and
/// the one function every panel font and text-holding length goes through.
struct TextSizeTests {

    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "com.gcdz.creativenotch.text-size-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    // MARK: - The setting

    /// The default is today's look, exactly: a factor of one.
    @Test func theDefaultIsTheLookFromBeforeTheSetting() {
        #expect(TextSize.default == .standard)
        #expect(TextSize.standard.scale == 1)
    }

    @Test func eachStepIsLargerThanTheLast() {
        #expect(TextSize.allCases == [.standard, .large, .larger])
        #expect(TextSize.large.scale == 1.15)
        #expect(TextSize.larger.scale == 1.3)
    }

    // MARK: - What a stored value means

    @Test func anAbsentValueReadsAsTheDefault() {
        #expect(PreferenceKeys.resolveTextSize(nil) == .standard)
    }

    @Test func aKnownValueReadsAsItself() {
        for size in TextSize.allCases {
            #expect(PreferenceKeys.resolveTextSize(size.rawValue) == size)
        }
    }

    /// The policy every other key follows: a string naming nothing, or a
    /// value of the wrong type, reads as the default.
    @Test func aMangledValueReadsAsTheDefault() {
        #expect(PreferenceKeys.resolveTextSize("huge") == .standard)
        #expect(PreferenceKeys.resolveTextSize(NSNumber(value: 2)) == .standard)
    }

    @Test func theChoiceSurvivesAReloadAndAnEmptyDomainIsTheDefault() {
        let defaults = makeIsolatedDefaults()
        #expect(PreferencesStore(defaults: defaults).textSize == .standard)
        PreferencesStore(defaults: defaults).setTextSize(.larger)
        #expect(PreferencesStore(defaults: defaults).textSize == .larger)
        #expect(defaults.string(forKey: PreferenceKeys.textSize) == "larger")
    }

    /// Hand-typed junk is left in place for `defaults read`, not corrected.
    @Test func aMangledStoredValueIsNotRewritten() {
        let defaults = makeIsolatedDefaults()
        defaults.set("huge", forKey: PreferenceKeys.textSize)
        #expect(PreferencesStore(defaults: defaults).textSize == .standard)
        #expect(defaults.string(forKey: PreferenceKeys.textSize) == "huge")
    }

    // MARK: - The type scale

    /// At the default every size the panel uses comes back untouched, so
    /// routing the panel through the helper changes nothing on screen.
    @Test func atTheDefaultEverySizeIsUnchanged() {
        for nominal: CGFloat in [8, 9, 10, 11, 12, 13, 14, 16, 18, 22, 28, 34, 44] {
            #expect(NotchType.size(nominal, scale: TextSize.standard.scale) == nominal)
            #expect(NotchType.length(nominal, scale: TextSize.standard.scale) == nominal)
        }
    }

    /// Sizes snap to half points and lengths to whole ones, so a scaled
    /// panel lands on the pixel grid rather than between pixels.
    @Test func scaledSizesSnapToTheGrid() {
        #expect(NotchType.size(13, scale: 1.15) == 15)     // 14.95
        #expect(NotchType.size(11, scale: 1.3) == 14.5)    // 14.3
        #expect(NotchType.size(12, scale: 1.15) == 14)     // 13.8
        #expect(NotchType.length(212, scale: 1.3) == 276)  // 275.6
        #expect(NotchType.length(64, scale: 1.15) == 74)   // 73.6
    }

    @Test func aLargerStepNeverDrawsSmaller() {
        for nominal: CGFloat in [8, 9, 10, 11, 12, 13, 14, 16, 18, 22, 28, 34, 44] {
            let sizes = TextSize.allCases.map { NotchType.size(nominal, scale: $0.scale) }
            #expect(sizes == sizes.sorted())
            #expect(sizes.last! > nominal)
        }
    }

    /// The scale only ever grows the panel. A broken factor is treated as
    /// none rather than drawing a zero-point font.
    @Test func aBrokenOrShrinkingScaleIsIgnored() {
        #expect(NotchType.size(13, scale: .nan) == 13)
        #expect(NotchType.size(13, scale: .infinity) == 13)
        #expect(NotchType.size(13, scale: 0.5) == 13)
        #expect(NotchType.length(64, scale: 0) == 64)
    }

    // MARK: - The panel grows with it

    private let notched = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1470, height: 956),
        safeAreaTopInset: 38, auxiliaryTopLeftWidth: 620, auxiliaryTopRightWidth: 620, menuBarHeight: 38
    )

    @Test func theDefaultPanelIsTheSizeItAlwaysWas() {
        let anchor = NotchGeometry.anchor(for: notched)
        #expect(NotchGeometry.panelFrame(for: anchor, in: notched, textScale: 1)
                == NotchGeometry.panelFrame(for: anchor, in: notched))
        #expect(NotchGeometry.panelFrame(for: anchor, in: notched).size == NotchGeometry.expandedSize)
    }

    /// Larger text, larger panel, by the same factor -- still centred on
    /// the notch and flush with the top of the screen.
    @Test func aLargerTextSizeGrowsThePanelByTheSameFactor() {
        let anchor = NotchGeometry.anchor(for: notched)
        let frame = NotchGeometry.panelFrame(for: anchor, in: notched, textScale: TextSize.larger.scale)
        #expect(frame.width == 806)   // 620 × 1.3
        #expect(frame.height == 338)  // 260 × 1.3
        #expect(frame.midX == anchor.rect.midX)
        #expect(frame.maxY == anchor.rect.maxY)
    }

    /// Clamped to the screen -- but never below the default size, which is
    /// what the panel has always been regardless of the screen.
    @Test func theGrownPanelIsClampedToTheScreenButNeverShrinks() {
        let small = ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 700, height: 300),
            safeAreaTopInset: 0, auxiliaryTopLeftWidth: 0, auxiliaryTopRightWidth: 0, menuBarHeight: 24
        )
        let anchor = NotchGeometry.anchor(for: small)
        let frame = NotchGeometry.panelFrame(for: anchor, in: small, textScale: TextSize.larger.scale)
        #expect(frame.width == 700)
        #expect(frame.height == 300)
        #expect(frame.minX >= small.frame.minX)
        #expect(frame.maxX <= small.frame.maxX)

        let tiny = ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 500, height: 200),
            safeAreaTopInset: 0, auxiliaryTopLeftWidth: 0, auxiliaryTopRightWidth: 0, menuBarHeight: 24
        )
        let tinyFrame = NotchGeometry.panelFrame(
            for: NotchGeometry.anchor(for: tiny), in: tiny, textScale: TextSize.larger.scale
        )
        #expect(tinyFrame.size == NotchGeometry.expandedSize)
    }

    /// The media column holds text, so it grows with it; the ears still
    /// span the (wider) panel exactly.
    @Test func theMediaColumnGrowsWithTheText() {
        let anchor = NotchGeometry.anchor(for: notched)
        let scale = TextSize.larger.scale
        let frame = NotchGeometry.panelFrame(for: anchor, in: notched, textScale: scale)
        let layout = PanelLayout.resolve(anchor: anchor, panelFrame: frame, showsMedia: true, textScale: scale)
        #expect(layout.mediaColumnWidth == 276)
        #expect(layout.leadingEarWidth + layout.notchGap + layout.trailingEarWidth == frame.width)
        #expect(PanelLayout.resolve(anchor: anchor, panelFrame: frame, showsMedia: false, textScale: scale)
                    .mediaColumnWidth == 0)
        #expect(PanelLayout.resolve(anchor: anchor, panelFrame: frame, showsMedia: true)
                    .mediaColumnWidth == PanelLayout.mediaColumnWidth)
    }
}
