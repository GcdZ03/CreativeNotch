import AppKit
import CreativeNotchCore

public extension NSPasteboard {

    /// What this pasteboard offers the shelf, with AppKit stripped away.
    ///
    /// File URLs are checked first and win outright: dragging a file also
    /// puts its path on the pasteboard as a string, and taking both would
    /// stash the same file twice.
    func dropPayloads() -> [DropPayload] {
        if let urls = readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           !urls.isEmpty {
            return urls.map { .file($0) }
        }

        if let image = readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
           let data = image.pngData {
            return [.image(data, ext: "png")]
        }

        if let text = string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [.text(text)]
        }

        return []
    }
}

private extension NSImage {
    var pngData: Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
