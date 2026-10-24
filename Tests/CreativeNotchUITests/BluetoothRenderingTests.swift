import AppKit
import SwiftUI
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// That the Bluetooth peek is actually drawn, and the feature renders for
/// the README and the pull request.
///
/// The first three tests are `PeekRenderingTests`' guard against this
/// project's only Critical bug, for the new case: an unhandled `PeekContent`
/// falls through `NotchRootView`'s `default` and draws the literal app name.
///
/// The last one writes `docs/assets/features/bluetooth-*.png`, and runs only
/// when asked: `CREATIVENOTCH_RENDER_FEATURES=1 swift test --filter
/// BluetoothRenderingTests`. The normal suite never rewrites a file.
@MainActor
struct BluetoothRenderingTests {

    private static let pods = BluetoothAudioEvent(name: "Gerald’s AirPods Pro", kind: .airPodsPro, connected: true)
    private static let phones = BluetoothAudioEvent(name: "WH-1000XM5", kind: .headphones, connected: false)

    /// `PanelRenderingTests`' 14" geometry: a 190×32 notch in a 620×260
    /// panel, so the notch band is x 215…405, y 0…32 in the image.
    private static func state(_ content: PeekContent) -> AppState {
        let s = AppState()
        let anchor: CreativeNotchCore.Anchor = .notch(CGRect(x: 661, y: 950, width: 190, height: 32))
        s.setGeometry(anchor: anchor, panelFrame: CGRect(x: 446, y: anchor.rect.maxY - 260, width: 620, height: 260))
        s.transition(to: .peek(content))
        return s
    }

    private static func render(_ content: PeekContent, scale: CGFloat = 1) -> NSBitmapImageRep? {
        let renderer = ImageRenderer(
            content: NotchRootView(app: state(content), now: Date(timeIntervalSinceReferenceDate: 0))
                .frame(width: 620, height: 260)
                .environment(\.animatesEqualizer, false)
        )
        renderer.scale = scale
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)
    }

    private static func png(_ content: PeekContent) -> Data? {
        render(content)?.representation(using: .png, properties: [:])
    }

    @Test func renderingTheSamePeekTwiceIsIdentical() throws {
        let once = try #require(Self.png(.bluetooth(Self.pods)))
        let twice = try #require(Self.png(.bluetooth(Self.pods)))
        #expect(Render.same(once, twice))
    }

    /// Delete `case .peek(.bluetooth…)` from `NotchRootView` and this draws
    /// the fallback label, the same image the drag-target peek draws.
    @Test func theBluetoothPeekDoesNotDrawTheFallbackLabel() throws {
        let peek = try #require(Self.png(.bluetooth(Self.pods)))
        let fallback = try #require(Self.png(.dragTarget))
        #expect(Render.differs(peek, fallback))
    }

    @Test func itDrawsTheDeviceItself() throws {
        let a = try #require(Self.png(.bluetooth(Self.pods)))
        let b = try #require(Self.png(.bluetooth(Self.phones)))
        #expect(Render.differs(a, b))
    }

    /// The row hangs below the band and leaves the camera housing black.
    @Test func nothingIsDrawnBehindTheCameraHousing() throws {
        let bitmap = try #require(Self.render(.bluetooth(Self.pods)))
        #expect(PanelRenderingTests.ink(bitmap, in: CGRect(x: 220, y: 2, width: 180, height: 28)) == 0)
        #expect(PanelRenderingTests.ink(bitmap, in: CGRect(x: 145, y: 34, width: 330, height: 28)) > 0.01)
    }

    // MARK: - Feature renders (opt-in)

    private static var assets: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/assets/features", isDirectory: true)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CREATIVENOTCH_RENDER_FEATURES"] != nil))
    func writeFeatureRenders() throws {
        try FileManager.default.createDirectory(at: Self.assets, withIntermediateDirectories: true)

        try Self.writePeek(.bluetooth(Self.pods), to: "bluetooth-connected.png")
        try Self.writePeek(.bluetooth(Self.phones), to: "bluetooth-disconnected.png")
        try Self.writeSettings(denied: true, to: "bluetooth-settings-denied.png")
        try Self.writeSettings(denied: false, to: "bluetooth-settings.png")
    }

    /// The peek over a stand-in desktop: a wallpaper gradient and a menu bar
    /// either side of the notch, so the glance is seen where it really sits.
    /// The layout is exact; the desktop is not.
    private static func writePeek(_ content: PeekContent, to name: String) throws {
        let scale: CGFloat = 2
        let width: CGFloat = 620, height: CGFloat = 96
        let panel = try #require(render(content, scale: scale)?.cgImage)

        let pixelsWide = Int(width * scale), pixelsHigh = Int(height * scale)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try #require(CGContext(
            data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.scaleBy(x: scale, y: scale)

        // Wallpaper: a dusk gradient, top to bottom.
        let colors = [
            CGColor(srgbRed: 0.16, green: 0.20, blue: 0.42, alpha: 1),
            CGColor(srgbRed: 0.55, green: 0.33, blue: 0.52, alpha: 1),
            CGColor(srgbRed: 0.93, green: 0.58, blue: 0.45, alpha: 1),
        ] as CFArray
        let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.55, 1])!
        context.drawLinearGradient(
            gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )

        // The menu bar, one notch tall.
        context.setFillColor(CGColor(gray: 0, alpha: 0.12))
        context.fill(CGRect(x: 0, y: height - 32, width: width, height: 32))
        let ns = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        let bold: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: NSColor.white,
        ]
        let plain: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.white,
        ]
        NSAttributedString(string: "Music", attributes: bold).draw(at: CGPoint(x: 44, y: height - 24))
        var x: CGFloat = 96
        for item in ["File", "Edit", "Song"] {
            let s = NSAttributedString(string: item, attributes: plain)
            s.draw(at: CGPoint(x: x, y: height - 24))
            x += s.size().width + 16
        }
        let clock = NSAttributedString(string: "Sat 24 Oct  9:41", attributes: plain)
        clock.draw(at: CGPoint(x: width - clock.size().width - 14, y: height - 24))
        if let apple = NSImage(systemSymbolName: "apple.logo", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) {
            let tinted = NSImage(size: apple.size, flipped: false) { rect in
                apple.draw(in: rect)
                NSColor.white.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(at: CGPoint(x: 16, y: height - 25), from: .zero, operation: .sourceOver, fraction: 1)
        }
        NSGraphicsContext.restoreGraphicsState()

        // The panel, its top flush with the top of the screen.
        context.draw(panel, in: CGRect(x: 0, y: height - 260, width: 620, height: 260))

        let image = try #require(context.makeImage())
        try write(image, to: name)
    }

    /// The Settings form, with Bluetooth alerts switched on, granted or
    /// denied. Drawn into an offscreen window that is never ordered front,
    /// so nothing appears on the screen of whoever runs this.
    private static func writeSettings(denied: Bool, to name: String) throws {
        let delegate = AppDelegate()
        delegate.shelfTrash = TestTrash.shelf
        delegate.preferencesDefaults = TestDefaults.isolated("bluetooth-render")
        delegate.growthDelay = .zero
        delegate.announce = { _ in }
        delegate.screenDescriptors = { [] }
        delegate.bluetoothSource = FakeBluetoothSource()
        delegate.bluetoothAccess = FakeBluetoothAccess(denied ? .denied : .allowed)
        delegate.install(metrics: NotchedDelegate.metrics)
        delegate.switchboard.setEnabled(true, for: .bluetooth)

        let controller = PreferencesController(
            switchboard: delegate.switchboard, state: delegate.state,
            launchAtLogin: delegate.launchAtLogin, presenter: { _ in }
        )
        let size = CGSize(width: 520, height: 1500)
        let host = NSHostingView(rootView: PreferencesView(controller: controller).frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()

        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let full = try #require(rep.cgImage)

        // Crop to the "In the notch" section, found by its rows' position.
        let crop = try #require(cropRect(full, pointsHigh: size.height))
        let cropped = try #require(full.cropping(to: crop))
        try write(cropped, to: name)
        delegate.activity.stop()
    }

    /// Where the crop starts and ends: the "In the notch" section of the
    /// form at 520pt wide, measured from a full render. Overridable with
    /// `CREATIVENOTCH_RENDER_CROP=y,height` (points) if the form moves.
    private static func cropRect(_ image: CGImage, pointsHigh: CGFloat) -> CGRect? {
        let scale = CGFloat(image.height) / pointsHigh
        let spec = ProcessInfo.processInfo.environment["CREATIVENOTCH_RENDER_CROP"] ?? "605,600"
        let parts = spec.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return CGRect(x: 0, y: CGFloat(parts[0]) * scale, width: CGFloat(image.width), height: CGFloat(parts[1]) * scale)
    }

    private static func write(_ image: CGImage, to name: String) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: assets.appendingPathComponent(name))
    }
}
