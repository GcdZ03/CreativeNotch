import Foundation

/// Names for the files a capture produces.
///
/// **`AVCaptureFileOutput` fails if the file already exists**, and it fails
/// *asynchronously*: the error arrives in the delegate long after the call
/// that started the recording returned, so a collision reads as "the clip
/// vanished" rather than as an error at the call site. The names are therefore
/// collision-free by construction rather than by checking the filesystem.
public enum CaptureFileNaming {

    /// Timestamp to the second, plus a short random suffix.
    ///
    /// The suffix is not decoration. Two stills a second apart get distinct
    /// timestamps, but two inside the same second do not -- and a shutter is
    /// exactly the control a person presses twice quickly.
    public static func name(
        for kind: Kind,
        at date: Date,
        suffix: String,
        calendar: Calendar = Calendar(identifier: .gregorian),
        timeZone: TimeZone = .current
    ) -> String {
        var calendar = calendar
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)

        // The digits are fixed, so names sort by time in any language; only
        // the word between them is translated, as Screenshot's is.
        let day = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        let time = String(format: "%02d.%02d.%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        let stamp = String(localized: "\(day) at \(time)", bundle: .creativeNotch, comment: "Capture file name: date, then time")
        return "\(kind.prefix) \(stamp) \(suffix).\(kind.fileExtension)"
    }

    public enum Kind: Equatable, Sendable {
        case still
        case clip

        var prefix: String {
            switch self {
            case .still: return String(localized: "Photo", bundle: .creativeNotch, comment: "Capture file name prefix")
            case .clip: return String(localized: "Clip", bundle: .creativeNotch, comment: "Capture file name prefix")
            }
        }

        var fileExtension: String {
            switch self {
            case .still: return "jpg"
            case .clip: return "mov"
            }
        }
    }
}
