import Foundation

/// When an entry was copied, as a clock time — never as "2m ago".
///
/// Relative text is wrong within a minute of being drawn unless something
/// redraws it, and this app has no timer to do that with. A clock time
/// stays true for as long as the panel is open (spec §5.6, §9). `now` is
/// only consulted to decide whether the entry is from today.
public enum ClipboardTimeLabel {
    public static func text(addedAt: Date, now: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .current
        if calendar.isDate(addedAt, inSameDayAs: now) {
            formatter.setLocalizedDateFormatFromTemplate("HH:mm")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("d MMM")
        }
        return formatter.string(from: addedAt)
    }
}
