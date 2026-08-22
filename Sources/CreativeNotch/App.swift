import AppKit
import CreativeNotchUI

@main
struct CreativeNotchApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // no Dock icon
        // `NSApplication.delegate` is `weak`, and this function has no use of
        // `delegate` after assignment, so ARC has no obligation to keep it
        // alive through `app.run()`'s indefinite runloop without this.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
