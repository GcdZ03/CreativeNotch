import AppKit
import Darwin

/// The window server calls `NotchSpace` needs, behind a protocol so tests
/// can stand in a fake. The real one must never run in a test: it creates
/// Spaces in the session of whoever runs the suite.
protocol SpaceServer: AnyObject {
    func createSpace(level: Int32) -> UInt64
    func show(_ space: UInt64)
    func hide(_ space: UInt64)
    func add(window: Int, to space: UInt64)
    func remove(window: Int, from space: UInt64)
    func destroy(_ space: UInt64)
}

/// Keeps the notch still while Spaces switch (2026-10-17).
///
/// The panel joins every Space and is `.stationary`, which in principle
/// keeps it put during a desktop swipe. In practice macOS still slides it
/// out with the old Space and in with the new one, so two notches show
/// mid-swipe. Hosting it in a Space of its own, above every other, takes it
/// out of the slide entirely — the approach Boring Notch ships.
///
/// That needs the window server's private CGS* functions. They are free —
/// already part of macOS — but undocumented and unpromised, so they are
/// looked up at runtime (`SkyLightSpaceServer.load`) and a macOS without them
/// gets `nil` here and today's behaviour, never a failed launch.
///
/// **Torn down on quit.** A Space created here belongs to the window server
/// until it is destroyed; `AppDelegate.applicationWillTerminate` calls
/// `tearDown()`.
@MainActor
final class NotchSpace {
    /// Above every ordinary Space.
    static let level: Int32 = .max

    private let server: SpaceServer
    private var space: UInt64?
    private var hosted: Int?

    init?(server: SpaceServer?) {
        guard let server else { return nil }
        self.server = server
    }

    /// Puts `windowNumber` in the Space, creating the Space the first time.
    /// A different window replaces the one hosted before.
    func host(windowNumber: Int) {
        guard windowNumber > 0, windowNumber != hosted else { return }
        let id: UInt64
        if let space {
            id = space
        } else {
            id = server.createSpace(level: Self.level)
            server.show(id)
            space = id
        }
        if let hosted { server.remove(window: hosted, from: id) }
        server.add(window: windowNumber, to: id)
        hosted = windowNumber
    }

    /// Undoes `host`, once.
    func tearDown() {
        guard let id = space else { return }
        if let hosted { server.remove(window: hosted, from: id) }
        server.hide(id)
        server.destroy(id)
        space = nil
        hosted = nil
    }
}

/// The real `SpaceServer`: SkyLight's CGS* functions, resolved with `dlsym`.
///
/// Not linked with `@_silgen_name`: a symbol a future macOS removes would
/// then stop the app launching at all. Resolved here, a missing one makes
/// `load()` return `nil` and the app carries on without the fixed Space.
final class SkyLightSpaceServer: SpaceServer {
    private typealias Connection = @convention(c) () -> Int32
    private typealias Create = @convention(c) (Int32, Int32, CFDictionary?) -> UInt64
    private typealias SetLevel = @convention(c) (Int32, UInt64, Int32) -> Void
    private typealias SpacesOp = @convention(c) (Int32, CFArray) -> Void
    private typealias WindowsOp = @convention(c) (Int32, CFArray, CFArray) -> Void
    private typealias Destroy = @convention(c) (Int32, UInt64) -> Void

    private let connection: Int32
    private let create: Create
    private let setLevel: SetLevel
    private let showSpaces: SpacesOp
    private let hideSpaces: SpacesOp
    private let addWindows: WindowsOp
    private let removeWindows: WindowsOp
    private let destroySpace: Destroy

    private init(
        connection: Int32, create: Create, setLevel: SetLevel,
        showSpaces: SpacesOp, hideSpaces: SpacesOp,
        addWindows: WindowsOp, removeWindows: WindowsOp, destroySpace: Destroy
    ) {
        self.connection = connection
        self.create = create
        self.setLevel = setLevel
        self.showSpaces = showSpaces
        self.hideSpaces = hideSpaces
        self.addWindows = addWindows
        self.removeWindows = removeWindows
        self.destroySpace = destroySpace
    }

    /// `nil` if any of the functions is missing. Resolving them creates
    /// nothing.
    static func load() -> SkyLightSpaceServer? {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY
        ) else { return nil }

        func symbol<T>(_ name: String, as: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }

        guard
            let connection = symbol("CGSMainConnectionID", as: Connection.self),
            let create = symbol("CGSSpaceCreate", as: Create.self),
            let setLevel = symbol("CGSSpaceSetAbsoluteLevel", as: SetLevel.self),
            let show = symbol("CGSShowSpaces", as: SpacesOp.self),
            let hide = symbol("CGSHideSpaces", as: SpacesOp.self),
            let add = symbol("CGSAddWindowsToSpaces", as: WindowsOp.self),
            let remove = symbol("CGSRemoveWindowsFromSpaces", as: WindowsOp.self),
            let destroy = symbol("CGSSpaceDestroy", as: Destroy.self)
        else { return nil }

        return SkyLightSpaceServer(
            connection: connection(), create: create, setLevel: setLevel,
            showSpaces: show, hideSpaces: hide,
            addWindows: add, removeWindows: remove, destroySpace: destroy
        )
    }

    /// The flag must be 1: other values make Finder draw desktop icons into
    /// the new Space (documented by the projects that found this API).
    func createSpace(level: Int32) -> UInt64 {
        let id = create(connection, 1, nil)
        setLevel(connection, id, level)
        return id
    }

    func show(_ space: UInt64) { showSpaces(connection, [NSNumber(value: space)] as CFArray) }
    func hide(_ space: UInt64) { hideSpaces(connection, [NSNumber(value: space)] as CFArray) }

    func add(window: Int, to space: UInt64) {
        addWindows(connection, [NSNumber(value: window)] as CFArray, [NSNumber(value: space)] as CFArray)
    }

    func remove(window: Int, from space: UInt64) {
        removeWindows(connection, [NSNumber(value: window)] as CFArray, [NSNumber(value: space)] as CFArray)
    }

    func destroy(_ space: UInt64) { destroySpace(connection, space) }
}
