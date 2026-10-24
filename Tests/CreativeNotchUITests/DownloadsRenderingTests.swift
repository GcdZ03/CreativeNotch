import AppKit
import SwiftUI
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// That the notch *draws* the downloads it is given -- the gap
/// `PowerPanelRenderingTests` describes: the wiring can be right and the view
/// can pass a constant.
///
/// Also holds the renders in `docs/assets/features/`, behind
/// `CREATIVENOTCH_RENDER_FEATURES`, so the normal suite never rewrites them:
///
///     CREATIVENOTCH_RENDER_FEATURES=1 swift test --filter DownloadsRenderingTests
@MainActor
struct DownloadsRenderingTests {

    /// 14" MacBook Pro: a 190×32 notch centred on a 1512-wide screen, the
    /// geometry `TextSizeRenderingTests` measures on.
    static let screen = TextSizeRenderingTests.screen

    static func state(downloads: DownloadSummary? = nil, showing: NotchState = .closed) -> AppState {
        let s = AppState()
        let anchor = NotchGeometry.anchor(for: screen)
        s.setGeometry(anchor: anchor, panelFrame: NotchGeometry.panelFrame(for: anchor, in: screen, textScale: 1))
        s.downloads = downloads
        s.transition(to: showing)
        return s
    }

    static func bitmap(_ s: AppState) -> NSBitmapImageRep? {
        let size = s.panelFrame.size
        let renderer = ImageRenderer(
            content: NotchRootView(app: s, now: Date(timeIntervalSinceReferenceDate: 0))
                .frame(width: size.width, height: size.height)
        )
        renderer.scale = 1
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)
    }

    static func png(_ s: AppState) -> Data? {
        bitmap(s)?.representation(using: .png, properties: [:])
    }

    private static func summary(_ count: Int, _ percent: Int?, _ name: String = "report.pdf") -> DownloadSummary {
        DownloadSummary(count: count, percent: percent, leadingName: name)
    }

    /// The trailing ear, panel-local and top-left origin: just past the
    /// housing, the band's height.
    static func ear(_ s: AppState) -> CGRect {
        let gap = s.anchor.rect.maxX - s.panelFrame.minX
        return CGRect(x: gap, y: 0, width: NotchGeometry.downloadsBadgeWidth, height: s.anchor.rect.height)
    }

    // MARK: - What is drawn

    @Test func theBadgeIsDrawnInTheTrailingEar() throws {
        let s = Self.state(downloads: Self.summary(1, 42))
        let b = try #require(Self.bitmap(s))
        #expect(PanelRenderingTests.ink(b, in: Self.ear(s)) > 0.02, "no ring in the ear")
        // And nothing behind the camera housing.
        #expect(PanelRenderingTests.ink(b, in: TextSizeRenderingTests.housing(s)) == 0)
    }

    @Test func theRingFollowsThePercent() throws {
        let low = try #require(Self.png(Self.state(downloads: Self.summary(1, 10))))
        let high = try #require(Self.png(Self.state(downloads: Self.summary(1, 90))))
        #expect(Render.differs(low, high))
    }

    @Test func aSecondDownloadAddsTheCount() throws {
        let one = try #require(Self.png(Self.state(downloads: Self.summary(1, 42))))
        let three = try #require(Self.png(Self.state(downloads: Self.summary(3, 42))))
        #expect(Render.differs(one, three))
    }

    @Test func theProgressPeekDrawsTheNameAndPercent() throws {
        let a = Self.summary(1, 42, "report.pdf")
        let b = Self.summary(1, 42, "holiday-photos.zip")
        let c = Self.summary(1, 80, "report.pdf")
        let pa = try #require(Self.png(Self.state(downloads: a, showing: .peek(.downloads(a)))))
        let pb = try #require(Self.png(Self.state(downloads: b, showing: .peek(.downloads(b)))))
        let pc = try #require(Self.png(Self.state(downloads: c, showing: .peek(.downloads(c)))))
        #expect(Render.differs(pa, pb), "the name is not drawn")
        #expect(Render.differs(pa, pc), "the percent is not drawn")
    }

    @Test func theCompletionPeekIsDrawn() throws {
        let progress = Self.summary(1, 100)
        let done = DownloadCompletion(name: "report.pdf", url: URL(fileURLWithPath: "/x/report.pdf"))
        let p = try #require(Self.png(Self.state(downloads: progress, showing: .peek(.downloads(progress)))))
        let d = try #require(Self.png(Self.state(showing: .peek(.downloadDone(done)))))
        #expect(Render.differs(p, d))
        let other = DownloadCompletion(name: "other.dmg", url: URL(fileURLWithPath: "/x/other.dmg"))
        let o = try #require(Self.png(Self.state(showing: .peek(.downloadDone(other)))))
        #expect(Render.differs(d, o), "the finished file's name is not drawn")
    }

    /// The peek's row hangs below the notch's band, like the battery's.
    @Test func thePeekSuppliesTheAnchorsBandHeight() {
        let s = Self.state()
        #expect(NotchRootView.downloadPeek(for: s, content: .progress(Self.summary(1, 1))).bandHeight
                == s.anchor.rect.height)
    }

    // MARK: - The feature renders (opt-in)

    /// Renders the feature in its real panel context, on a stand-in desktop,
    /// to `docs/assets/features/downloads-*.png`. Skipped unless
    /// `CREATIVENOTCH_RENDER_FEATURES` is set, so an ordinary run never
    /// rewrites a committed file.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CREATIVENOTCH_RENDER_FEATURES"] != nil))
    func renderFeatureImages() throws {
        let out = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/assets/features", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let one = Self.summary(1, 42, "Quarterly report.pdf")
        let three = Self.summary(3, 67, "Quarterly report.pdf")
        let done = DownloadCompletion(
            name: "Quarterly report.pdf", url: URL(fileURLWithPath: "/Users/you/Downloads/Quarterly report.pdf")
        )

        try write(Self.desk(Self.state(downloads: one), height: 64), to: out.appendingPathComponent("downloads-badge.png"))
        try write(Self.desk(Self.state(downloads: three), height: 64), to: out.appendingPathComponent("downloads-badge-multiple.png"))
        let hovering = Self.state(downloads: one, showing: .peek(.downloads(one)))
        try write(Self.desk(hovering, height: 92), to: out.appendingPathComponent("downloads-progress-peek.png"))
        try write(Self.desk(Self.state(showing: .peek(.downloadDone(done))), height: 92),
                  to: out.appendingPathComponent("downloads-done-peek.png"))
        try write(Self.settingsRow(access: .denied), to: out.appendingPathComponent("downloads-settings-denied.png"))
    }

    private func write(_ data: Data?, to url: URL) throws {
        let data = try #require(data, "nothing rendered for \(url.lastPathComponent)")
        try data.write(to: url)
    }

    /// The panel over a stand-in desktop -- a gradient and a translucent menu
    /// bar with a few generic status glyphs -- cropped to the top `height`
    /// points, at 2x. The layout is exact; the desktop is not.
    static func desk(_ s: AppState, height: CGFloat) -> Data? {
        let size = s.panelFrame.size
        let band = s.anchor.rect.height
        // Wider than the panel, so the stand-in status items sit where a
        // real menu bar keeps them -- far right, clear of the ear -- rather
        // than crowding the badge inside a panel-wide crop.
        let width: CGFloat = 900
        let content = ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [Color(red: 0.36, green: 0.42, blue: 0.78), Color(red: 0.78, green: 0.47, blue: 0.62)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            HStack(spacing: 16) {
                Text("File").fontWeight(.semibold)
                Text("Edit")
                Text("View")
                Spacer()
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
                Text("Sat 24 Oct  9:41")
            }
            .font(.system(size: 13))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(width: width, height: band)
            .background(.black.opacity(0.18))
            NotchRootView(app: s, now: Date(timeIntervalSinceReferenceDate: 0))
                .frame(width: size.width, height: size.height)
                .offset(x: (width - size.width) / 2)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .clipped()
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// The Settings row, in the window's own grouped form, with its warning
    /// and button -- drawn by AppKit through a hosting view, since the
    /// switch is an AppKit control `ImageRenderer` cannot draw.
    static func settingsRow(access: DownloadsAccess) -> Data? {
        let delegate = AppDelegate()
        delegate.preferencesDefaults = TestDefaults.isolated("downloads-render")
        delegate.state.preferences.downloads = true
        delegate.state.downloadsAccess = access
        let controller = PreferencesController(
            switchboard: delegate.switchboard, state: delegate.state,
            launchAtLogin: delegate.launchAtLogin, presenter: { _ in }
        )
        guard let row = PreferencesView.rows.first(where: { $0.module == .downloads }) else { return nil }
        let view = PreferencesView(controller: controller)
        let form = Form {
            Section {
                view.moduleRow(row)
            } header: {
                Text(PreferencesSection.notch.title)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 210)

        let host = NSHostingView(rootView: form)
        host.frame = CGRect(x: 0, y: 0, width: 520, height: 210)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.display()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
