import AppKit
import QuickLookUI
import SwiftUI
import XCTest
import CreativeNotchCore
@testable import CreativeNotchUI

/// Shelf Quick Look against the real window server: key focus, which no
/// headless suite can see, and the README's pictures of the preview and the
/// tile's menu, which are system windows the offscreen renders cannot draw.
///
/// **Opt-in, and it puts windows on screen.** Skipped unless
/// `CREATIVENOTCH_LIVE_QUICKLOOK` is set:
///
///     CREATIVENOTCH_LIVE_QUICKLOOK=1 swift test --filter ShelfQuickLookLive
///
/// For a few seconds the test process becomes an accessory app, as the
/// packaged app is, with a real `NotchPanel` at the top of the main screen
/// and Quick Look's real panel under it. Keys are posted to this process
/// alone (`CGEvent.postToPid`), so nothing reaches the app you are typing
/// in, and the pointer is never moved. The shelf is a temporary folder, the
/// opener is the sandboxed one and the Trash a test folder — only the
/// preview is real. Screenshots are of this process's own windows, which
/// needs no Screen Recording permission. Writes `shelf-quicklook-preview.png`
/// and `shelf-quicklook-menu.png` into `docs/assets/features/` when
/// `CREATIVENOTCH_RENDER_DOCS` is also set.
///
/// **XCTest, not Swift Testing**, the one suite in the package that is. A
/// Swift Testing test runs as a job *on* the main dispatch queue, so while
/// it pumps events nothing else queued there runs — Quick Look's preview
/// never finishes loading — and if it yields instead, the main run loop it
/// returns to is stopped by AppKit's event thread, which ends the process.
/// XCTest calls a test from the main thread's plain stack, where a nested
/// event loop drains the main queue the way `NSApp.run` does.
@MainActor
final class ShelfQuickLookLive: XCTestCase {

    fileprivate static let writesDocs = ProcessInfo.processInfo.environment["CREATIVENOTCH_RENDER_DOCS"] != nil

    fileprivate static var output: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/assets/features", isDirectory: true)
    }

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CREATIVENOTCH_LIVE_QUICKLOOK"] != nil,
                          "puts windows on screen; set CREATIVENOTCH_LIVE_QUICKLOOK to run")
    }

    // MARK: - The keyboard

    /// The reviewer's case, end to end: Space in the key notch panel opens
    /// the preview, and the preview — not the frontmost app — then has the
    /// keyboard: → pages it, Space closes it, the keyboard comes back to the
    /// notch panel, and Space there opens it again; Esc closes it too.
    func testThePreviewKeepsTheKeyboardInsideTheApp() throws {
        let live = try Live()
        defer { live.tearDown() }

        live.key(Live.space)                           // to the notch panel
        let panel = try XCTUnwrap(QLPreviewPanel.shared())
        XCTAssertTrue(live.waitUntil { panel.isVisible && panel.isKeyWindow }, "the preview never took the keyboard")
        XCTAssertFalse(live.notchPanel.isKeyWindow)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertEqual(panel.currentPreviewItemIndex, live.quickLook.request?.index)
        live.settle()

        let before = panel.currentPreviewItemIndex
        live.key(Live.rightArrow)                      // to the preview: pages it
        XCTAssertTrue(live.waitUntil { panel.currentPreviewItemIndex == before + 1 }, "→ did not page")

        live.key(Live.space)                           // to the preview: closes it
        XCTAssertTrue(live.waitUntil { !panel.isVisible }, "Space did not close the preview")
        XCTAssertTrue(live.waitUntil { live.notchPanel.isKeyWindow }, "the keyboard did not come back")

        live.key(Live.space)                           // to the notch panel again
        XCTAssertTrue(live.waitUntil { panel.isVisible && panel.isKeyWindow }, "Space did not preview again")
        live.settle()

        live.key(Live.escape)                          // to the preview: closes it
        XCTAssertTrue(live.waitUntil { !panel.isVisible }, "Esc did not close the preview")
        XCTAssertTrue(live.waitUntil { live.notchPanel.isKeyWindow })
        // Quick Look's Esc is its own: the notch panel never saw it.
        XCTAssertEqual(live.delegate.state.state, .open(.shelf))
    }

    // MARK: - The hover buttons

    /// A click on a tile's hover Remove button removes it without selecting
    /// it first: the button is not inside the tile's select gesture.
    func testRemovingATileDoesNotSelectIt() throws {
        let live = try Live()
        defer { live.tearDown() }
        let hero = live.item(named: "Hero shot.png")
        let frame = live.notchPanel.frame
        // Hero shot's thumbnail spans x 278–342 and starts 82 pt below the
        // panel's top; Remove sits on its top-right corner.
        try live.hover(at: CGPoint(x: frame.minX + 310, y: frame.maxY - 114))
        try live.click(at: CGPoint(x: frame.minX + 339, y: frame.maxY - 85))
        XCTAssertTrue(live.waitUntil { !live.shelf.items.contains { $0.id == hero.id } }, "Remove was not hit")
        XCTAssertNil(live.delegate.state.shelfSelection)
    }

    /// The control: a click on the same tile away from the buttons selects it.
    func testClickingATileSelectsIt() throws {
        let live = try Live()
        defer { live.tearDown() }
        let hero = live.item(named: "Hero shot.png")
        let frame = live.notchPanel.frame
        try live.hover(at: CGPoint(x: frame.minX + 310, y: frame.maxY - 114))
        try live.click(at: CGPoint(x: frame.minX + 300, y: frame.maxY - 120))
        XCTAssertTrue(live.waitUntil { live.delegate.state.shelfSelection == hero.id })
        XCTAssertTrue(live.shelf.items.contains { $0.id == hero.id })
    }

    // MARK: - The pictures

    /// The preview opened from the selected tile, under the open shelf.
    func testPreviewScreenshot() throws {
        let live = try Live()
        defer { live.tearDown() }
        live.delegate.state.shelfSelection = live.item(named: "Hero shot.png").id
        live.key(Live.space)
        let panel = try XCTUnwrap(QLPreviewPanel.shared())
        XCTAssertTrue(live.waitUntil { panel.isVisible && panel.isKeyWindow })
        live.placeUnderNotch(panel)
        live.pump(3)                                   // let the preview draw
        guard Self.writesDocs else { return }
        try live.capture([panel, live.notchPanel], to: "shelf-quicklook-preview.png")
    }

    /// A right-click on a tile: the real context menu, Open and Quick Look
    /// first.
    func testContextMenuScreenshot() throws {
        let live = try Live()
        defer { live.tearDown() }
        // The middle tile, Hero shot.png, where the 620×260 panel lays it
        // out at the default text size with no media column (the preview
        // picture shows the same layout). SwiftUI builds its accessibility
        // tree only for an assistive client, so the tile cannot be looked
        // up in process; the menu's titles below prove a tile was hit.
        let panelFrame = live.notchPanel.frame
        let point = CGPoint(x: panelFrame.minX + 310, y: panelFrame.maxY - 114)

        let probe = MenuProbe(live: live, writeTo: Self.writesDocs ? "shelf-quicklook-menu.png" : nil)
        defer { probe.stop() }

        try live.rightClick(at: point)
        XCTAssertEqual(Array(probe.titles.prefix(2)), ["Open", "Quick Look"])
        XCTAssertTrue(probe.titles.contains("Remove"))
        XCTAssertFalse(probe.menuWindows.isEmpty)
    }
}

// MARK: - The rig

/// Catches the context menu as it opens and photographs it. Menu tracking
/// runs its own loop; a common-mode timer still fires inside it, so the
/// menu is captured while open and then dismissed.
@MainActor
private final class MenuProbe: NSObject {
    private let live: Live
    private let name: String?
    private var menu: NSMenu?
    private(set) var titles: [String] = []
    private(set) var menuWindows: [CGWindowID] = []

    init(live: Live, writeTo name: String?) {
        self.live = live
        self.name = name
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(began(_:)),
                                               name: NSMenu.didBeginTrackingNotification, object: nil)
    }

    func stop() { NotificationCenter.default.removeObserver(self) }

    @objc private func began(_ note: Notification) {
        guard menu == nil, let menu = note.object as? NSMenu else { return }
        self.menu = menu
        titles = menu.items.map(\.title)
        RunLoop.main.add(Timer(timeInterval: 0.6, target: self, selector: #selector(shoot),
                               userInfo: nil, repeats: false), forMode: .common)
    }

    @objc private func shoot() {
        menuWindows = Live.windowIDs(ofPID: getpid(), above: live.notchPanel)
        if let name {
            // Front to back: the window server composites the array's
            // first window on top.
            try? live.capture(windowIDs: menuWindows + [CGWindowID(live.notchPanel.windowNumber)], to: name)
        }
        menu?.cancelTracking()
    }
}

/// A real, keyed notch panel over a three-file temporary shelf, the shelf
/// tab open, with the real `ShelfQuickLook` as the delegate's preview.
@MainActor
private final class Live {
    let delegate: AppDelegate
    let quickLook = ShelfQuickLook()
    let notchPanel: NotchPanel
    let shelf: ShelfStore

    init() throws {
        NSApplication.shared.setActivationPolicy(.accessory)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelf-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.writeFiles(into: dir)

        let delegate = AppDelegate()
        delegate.shelfTrash = TestTrash.shelf
        delegate.shelfDirectory = dir
        delegate.preferencesDefaults = TestDefaults.isolated()
        delegate.growthDelay = .zero
        delegate.playChime = { _ in }
        delegate.performHaptic = {}
        delegate.announce = { _ in }
        delegate.pointerLocation = { CGPoint(x: -10_000, y: -10_000) }
        delegate.screenDescriptors = { [] }
        delegate.shelfPreview = quickLook
        let screen = try XCTUnwrap(NSScreen.main)
        delegate.install(metrics: screen.metrics)
        // Isolated defaults are a first run; the welcome card would cover
        // the shelf.
        delegate.state.welcomeSeen = true
        self.delegate = delegate
        self.notchPanel = try XCTUnwrap(delegate.panel)
        self.shelf = try XCTUnwrap(delegate.shelf)

        notchPanel.orderFrontRegardless()
        delegate.state.transition(to: .open(.shelf), openedBy: .tap)
        notchPanel.makeKey()
        pump(0.8)
        guard notchPanel.isKeyWindow else {
            tearDown()
            throw XCTSkip("the notch panel never became key — is another app holding the keyboard?")
        }
    }

    /// Synchronous, for `defer`: the windows go at once, and nothing
    /// waits on their animations.
    func tearDown() {
        quickLook.close()
        notchPanel.orderOut(nil)
    }

    func item(named name: String) -> ShelfItem {
        shelf.items.first { $0.displayName == name }!
    }

    // MARK: Events

    /// Runs the event loop for `seconds`, as `NSApp.run` would.
    func pump(_ seconds: TimeInterval) {
        let end = Date(timeIntervalSinceNow: seconds)
        while Date() < end {
            if let event = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.02),
                                           inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
    }

    static let space: CGKeyCode = 49
    static let escape: CGKeyCode = 53
    static let rightArrow: CGKeyCode = 124

    /// Waits out Quick Look's opening zoom, during which it ignores Esc —
    /// as it does in Finder.
    func settle() { pump(0.8) }

    /// Pumps until `condition` holds, for up to three seconds.
    func waitUntil(_ condition: () -> Bool) -> Bool {
        let end = Date(timeIntervalSinceNow: 3)
        while Date() < end {
            if condition() { return true }
            pump(0.05)
        }
        return condition()
    }

    /// A key press delivered to this process only — routed by AppKit to our
    /// key window, exactly as a typed key would be.
    func key(_ code: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)?.postToPid(getpid())
        }
        pump(0.25)
    }

    /// A right-click at `point` (AppKit screen coordinates), handed to the
    /// view under it the way `NSWindow.sendEvent` hands one on. Neither a
    /// mouse event posted to the process (it arrives with no window: the
    /// window server's hit test is what names one) nor a queued AppKit event
    /// reaches SwiftUI's menu; the real pointer stays where it is. Returns
    /// once the menu has closed — `MenuProbe` closes it.
    func rightClick(at point: CGPoint) throws {
        let inWindow = notchPanel.convertPoint(fromScreen: point)
        let view = try XCTUnwrap(notchPanel.contentView?.hitTest(inWindow), "nothing under \(point)")
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: inWindow, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: notchPanel.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1
        ))
        view.rightMouseDown(with: event)
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint) throws -> (NSView, NSEvent) {
        let inWindow = notchPanel.convertPoint(fromScreen: point)
        let view = try XCTUnwrap(notchPanel.contentView?.hitTest(inWindow), "nothing under \(point)")
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: inWindow, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: notchPanel.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1
        ))
        return (view, event)
    }

    /// The pointer arriving over `point` — the real pointer stays where it
    /// is. SwiftUI's `onHover` is fed by tracking areas, so every area under
    /// the point, from the hit view up, is told the pointer entered it; the
    /// event carries the area, which is how its owner tells its areas apart.
    func hover(at point: CGPoint) throws {
        let inWindow = notchPanel.convertPoint(fromScreen: point)
        var node = notchPanel.contentView?.hitTest(inWindow)
        while let view = node {
            let local = view.convert(inWindow, from: nil)
            for area in view.trackingAreas where area.options.contains(.inVisibleRect) || area.rect.contains(local) {
                guard let entered = NSEvent.enterExitEvent(
                    with: .mouseEntered, location: inWindow, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: notchPanel.windowNumber, context: nil, eventNumber: 0,
                    trackingNumber: Int(bitPattern: Unmanaged.passUnretained(area).toOpaque()),
                    userData: nil
                ) else { continue }
                (area.owner as? NSResponder)?.mouseEntered(with: entered)
            }
            node = view.superview
        }
        let (_, moved) = try mouseEvent(.mouseMoved, at: point)
        notchPanel.sendEvent(moved)
        pump(0.3)
    }

    /// A left click at `point`, through the window as AppKit routes one.
    func click(at point: CGPoint) throws {
        let (_, down) = try mouseEvent(.leftMouseDown, at: point)
        let (_, up) = try mouseEvent(.leftMouseUp, at: point)
        notchPanel.sendEvent(down)
        notchPanel.sendEvent(up)
        pump(0.5)
    }

    /// Quick Look sizes itself for the file; for the picture it sits just
    /// under the notch panel, the size a reader can take in beside it.
    func placeUnderNotch(_ panel: NSPanel) {
        let size = CGSize(width: 560, height: 420)
        let origin = CGPoint(x: notchPanel.frame.midX - size.width / 2,
                             y: notchPanel.frame.minY - size.height - 16)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }

    // MARK: Capture

    /// `CGWindowListCreateImageFromArray`, looked up at run time: the SDK
    /// marks it obsolete in favour of ScreenCaptureKit, which would need
    /// Screen Recording permission even for our own windows.
    private typealias CreateImageFromArray = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?

    func capture(_ windows: [NSWindow], to name: String) throws {
        try capture(windowIDs: windows.map { CGWindowID($0.windowNumber) }, to: name)
    }

    /// Our windows `ids`, front first, composited by the window server,
    /// laid over the renders' wallpaper gradient.
    func capture(windowIDs ids: [CGWindowID], to name: String) throws {
        let symbol = try XCTUnwrap(dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImageFromArray"))
        let create = unsafeBitCast(symbol, to: CreateImageFromArray.self)
        // The array holds the window numbers themselves as its values, not
        // CFNumbers: `CFArrayCreate` with no callbacks.
        var values: [UnsafeRawPointer?] = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        let array = try XCTUnwrap(CFArrayCreate(nil, &values, values.count, nil))
        // kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution
        let image = try XCTUnwrap(create(.null, array, (1 << 0) | (1 << 3))?.takeRetainedValue())

        let width = image.width, height = image.height
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let colors = [CGColor(srgbRed: 0.36, green: 0.30, blue: 0.62, alpha: 1),
                      CGColor(srgbRed: 0.86, green: 0.52, blue: 0.62, alpha: 1)] as CFArray
        let gradient = try XCTUnwrap(CGGradient(colorsSpace: nil, colors: colors, locations: [0, 1]))
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)),
                                   end: CGPoint(x: CGFloat(width), y: 0), options: [])
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let composed = try XCTUnwrap(context.makeImage())
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: composed).representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: ShelfQuickLookLive.output, withIntermediateDirectories: true)
        try png.write(to: ShelfQuickLookLive.output.appendingPathComponent(name))
    }

    /// This process's on-screen windows ordered above `window` — an open
    /// menu's, here.
    static func windowIDs(ofPID pid: pid_t, above window: NSWindow) -> [CGWindowID] {
        let options: CGWindowListOption = [.optionOnScreenAboveWindow, .excludeDesktopElements]
        let list = CGWindowListCopyWindowInfo(options, CGWindowID(window.windowNumber)) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid else { return nil }
            return info[kCGWindowNumber as String] as? CGWindowID
        }
    }

    // MARK: Files

    /// Three real files, oldest first so the shelf (newest first) reads
    /// Brief, Hero shot, Notes: a picture worth previewing, a note and a
    /// one-page PDF.
    private static func writeFiles(into dir: URL) throws {
        let notes = dir.appendingPathComponent("Notes.txt")
        try """
        Launch checklist

        - Hero shot for the landing page
        - Brief signed off
        - Press kit to the shelf, AirDrop to the team
        """.write(to: notes, atomically: true, encoding: .utf8)

        let hero = dir.appendingPathComponent("Hero shot.png")
        try heroImage().write(to: hero)

        let brief = dir.appendingPathComponent("Brief.pdf")
        try briefPDF().write(to: brief)

        for (offset, url) in [notes, hero, brief].enumerated() {
            try FileManager.default.setAttributes(
                [.creationDate: Date(timeIntervalSinceNow: Double(offset - 10) * 60)],
                ofItemAtPath: url.path
            )
        }
    }

    /// A dusk landscape: sky gradient, a sun and two ridges.
    private static func heroImage() throws -> Data {
        let size = CGSize(width: 1600, height: 1000)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let sky = [CGColor(srgbRed: 0.98, green: 0.62, blue: 0.40, alpha: 1),
                   CGColor(srgbRed: 0.42, green: 0.28, blue: 0.62, alpha: 1)] as CFArray
        context.drawLinearGradient(CGGradient(colorsSpace: nil, colors: sky, locations: [0, 1])!,
                                   start: CGPoint(x: 0, y: 300), end: CGPoint(x: 0, y: size.height), options: [])
        context.setFillColor(CGColor(srgbRed: 1, green: 0.86, blue: 0.55, alpha: 1))
        context.fillEllipse(in: CGRect(x: 980, y: 380, width: 260, height: 260))
        func ridge(_ points: [CGPoint], _ color: CGColor) {
            context.beginPath()
            context.move(to: CGPoint(x: 0, y: 0))
            for p in points { context.addLine(to: p) }
            context.addLine(to: CGPoint(x: size.width, y: 0))
            context.closePath()
            context.setFillColor(color)
            context.fillPath()
        }
        ridge([CGPoint(x: 0, y: 460), CGPoint(x: 380, y: 620), CGPoint(x: 760, y: 430),
               CGPoint(x: 1180, y: 560), CGPoint(x: 1600, y: 400)],
              CGColor(srgbRed: 0.30, green: 0.20, blue: 0.42, alpha: 1))
        ridge([CGPoint(x: 0, y: 260), CGPoint(x: 520, y: 380), CGPoint(x: 1000, y: 240),
               CGPoint(x: 1600, y: 330)],
              CGColor(srgbRed: 0.16, green: 0.11, blue: 0.26, alpha: 1))
        let image = try XCTUnwrap(context.makeImage())
        return try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }

    private static func briefPDF() throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        ("Creative brief" as NSString).draw(at: CGPoint(x: 72, y: 690),
                                             withAttributes: [.font: NSFont.boldSystemFont(ofSize: 28)])
        ("Spring launch — landing page and press kit." as NSString).draw(
            at: CGPoint(x: 72, y: 650), withAttributes: [.font: NSFont.systemFont(ofSize: 14)])
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}

