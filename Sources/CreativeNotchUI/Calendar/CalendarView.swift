import SwiftUI
import CreativeNotchCore

/// The calendar pane: the next three events of today and tomorrow, and how
/// many reminders are due.
///
/// Presentation only. Which rows show and every word on them come from Core
/// (`CalendarGlance`, `CalendarText`) given the instant `body` is drawn at --
/// so a snapshot read a minute ago still says "in 14 min", not the "in 15
/// min" it would have said then. The calendar and locale come from the
/// environment, which is the system's in the app and pinned in a render.
///
/// Nothing here reads EventKit, schedules anything, or opens anything: the
/// two buttons call closures, routed through `AppState` like every other
/// pane's verbs.
struct CalendarView: View {
    let snapshot: CalendarSnapshot?
    let now: Date
    var onRequestAccess: () -> Void = {}
    var onOpenPrivacySettings: () -> Void = {}

    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale

    /// How many rows the glance shows. Three fit the pane at every text size
    /// with the reminder line under them.
    static let rowLimit = 3

    /// The rows `body` draws. Static so a test can check which events the
    /// pane picks, and in what order, without rendering it.
    static func rows(for snapshot: CalendarSnapshot, now: Date, calendar: Calendar) -> [CalendarEvent] {
        CalendarGlance.upcoming(snapshot.events, now: now, calendar: calendar, limit: rowLimit)
    }

    var body: some View {
        switch snapshot?.pane {
        case nil:
            // Reachable only for the instant between the module switching on
            // and its first status read.
            Text("Reading your calendar…")
                .notchFont(12, weight: .medium, design: .rounded)
                .foregroundStyle(.ink(0.6))
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .needsAccess:
            message(
                symbol: "calendar",
                title: "See what's next",
                detail: "Your next events and today's reminders, read on this Mac and kept nowhere else.",
                button: ("Allow Access\u{2026}", onRequestAccess)
            )

        case .denied:
            message(
                symbol: "calendar.badge.exclamationmark",
                title: "CreativeNotch can't read your calendars",
                detail: "Turn on Calendars and Reminders for CreativeNotch in Privacy & Security.",
                button: ("Open Privacy Settings", onOpenPrivacySettings)
            )

        case .restricted:
            message(
                symbol: "lock",
                title: "Calendar access is restricted",
                detail: "A profile or Screen Time manages it on this Mac.",
                button: nil
            )

        case .glance(let showsEvents, let showsReminders):
            if let snapshot {
                glance(snapshot, showsEvents: showsEvents, showsReminders: showsReminders)
            }
        }
    }

    // MARK: - The glance

    private func glance(_ snapshot: CalendarSnapshot, showsEvents: Bool, showsReminders: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsEvents {
                let rows = Self.rows(for: snapshot, now: now, calendar: calendar)
                if rows.isEmpty {
                    // Inset like a row's contents, so it lines up with the
                    // reminder line under it.
                    quietLine(symbol: "calendar", text: "Nothing else today or tomorrow")
                        .padding(.leading, 8)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(rows) { event in
                            CalendarRow(event: event, now: now, calendar: calendar, locale: locale)
                        }
                    }
                }
            } else {
                accessLine(for: snapshot.eventsAccess, noun: "Calendar")
                    .padding(.leading, 8)
            }

            if showsReminders {
                let tally = CalendarGlance.tally(snapshot.reminders, now: now, calendar: calendar)
                // The words carry "overdue"; the glyph changes too, so the
                // state never rests on one signal alone.
                quietLine(
                    symbol: tally.overdue > 0 ? "exclamationmark.circle" : "checklist",
                    text: CalendarText.reminders(tally),
                    emphasised: tally.overdue > 0
                )
                .padding(.leading, 8)
            } else {
                accessLine(for: snapshot.remindersAccess, noun: "Reminders")
                    .padding(.leading, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The line for a grant the glance lacks while it has the other: a button
    /// while macOS can still ask, a sentence once it has been refused.
    @ViewBuilder
    private func accessLine(for access: CalendarAccess, noun: String) -> some View {
        if access.isRequestable {
            Button("Show \(noun)\u{2026}", action: onRequestAccess)
                .buttonStyle(NotchButtonStyle(.quiet, compact: true))
        } else {
            quietLine(symbol: "lock", text: "\(noun) access is off in System Settings")
        }
    }

    private func quietLine(symbol: String, text: String, emphasised: Bool = false) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .notchFont(11, weight: .semibold)
                .foregroundStyle(.ink(emphasised ? 0.85 : 0.5))
            Text(text)
                .notchFont(12, weight: .medium, design: .rounded)
                .foregroundStyle(.ink(emphasised ? 0.85 : 0.6))
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    // MARK: - The other states

    private func message(
        symbol: String,
        title: String,
        detail: String,
        button: (label: String, perform: () -> Void)?
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .notchFont(24, weight: .medium)
                .foregroundStyle(.ink(0.55))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .notchFont(13, weight: .semibold, design: .rounded)
                    .foregroundStyle(.ink(0.92))
                Text(detail)
                    .notchFont(12, weight: .medium, design: .rounded)
                    .foregroundStyle(.ink(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                if let button {
                    Button(button.label, action: button.perform)
                        .buttonStyle(NotchButtonStyle(.prominent, compact: true))
                        .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.bottom, 8)
    }
}

/// One event: the calendar's colour, the title, and when.
private struct CalendarRow: View {
    let event: CalendarEvent
    let now: Date
    let calendar: Calendar
    let locale: Locale

    var body: some View {
        let underWay = !event.isAllDay && event.start <= now
        HStack(spacing: 9) {
            Circle()
                .fill(Color(red: event.color.red, green: event.color.green, blue: event.color.blue))
                .notchFrame(width: 8, height: 8)

            Text(CalendarText.title(of: event))
                .notchFont(13, weight: .medium, design: .rounded)
                .foregroundStyle(.ink(0.92))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            Text(CalendarText.when(event, now: now, calendar: calendar, locale: locale))
                .notchFont(11, weight: .medium, design: .rounded)
                .monospacedDigit()
                .foregroundStyle(.ink(underWay ? 0.85 : 0.5))
                .lineLimit(1)
                .layoutPriority(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            // The event under way is the one row that is "now": a faint
            // fill as well as its "Now, until …" words, so neither signal
            // stands alone.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.hairline(underWay ? 0.10 : 0.05))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(CalendarText.spoken(event, now: now, calendar: calendar, locale: locale))
    }
}
