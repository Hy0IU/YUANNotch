import AppKit
import EventKit
import SwiftUI

private struct FixtureService: ScheduleServing {
    let calendarAccess: ScheduleAuthorization
    let reminderAccess: ScheduleAuthorization
    let sourceValues: [ScheduleSource]
    let values: [ScheduleEntry]
    var failsCalendar = false

    func authorization(for kind: ScheduleSourceKind) -> ScheduleAuthorization {
        kind == .calendar ? calendarAccess : reminderAccess
    }

    func requestAccess(for kind: ScheduleSourceKind) async throws -> ScheduleAuthorization {
        preconditionFailure("The schedule must never request access without a user action")
    }

    func sources(for kind: ScheduleSourceKind) async -> [ScheduleSource] {
        authorization(for: kind).canRead ? sourceValues.filter { $0.kind == kind } : []
    }

    func entries(in range: DateInterval, sources: [ScheduleSource]) async throws -> [ScheduleEntry] {
        if failsCalendar && sources.contains(where: { $0.kind == .calendar }) {
            throw NSError(domain: "ScheduleProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Calendar unavailable"])
        }
        let keys = Set(sources.map(\.key))
        return values.filter {
            keys.contains("\($0.kind.rawValue):\($0.sourceID)")
                && $0.start < range.end && ($0.end ?? $0.start) >= range.start
        }
    }

    func changes() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

private struct DelayedService: ScheduleServing {
    let source: ScheduleSource
    let pivot: Date
    func authorization(for kind: ScheduleSourceKind) -> ScheduleAuthorization { .fullAccess }
    func requestAccess(for kind: ScheduleSourceKind) async throws -> ScheduleAuthorization { .fullAccess }
    func sources(for kind: ScheduleSourceKind) async -> [ScheduleSource] { kind == .calendar ? [source] : [] }
    func entries(in range: DateInterval, sources: [ScheduleSource]) async throws -> [ScheduleEntry] {
        // Deliberately ignore cancellation: an older backend response may still arrive.
        try? await Task.sleep(for: range.start < pivot ? .milliseconds(150) : .milliseconds(10))
        guard !sources.isEmpty else { return [] }
        return [ScheduleEntry(id: "response", sourceID: source.id, kind: .calendar,
                              title: range.start < pivot ? "old" : "new", start: range.start,
                              end: range.start.addingTimeInterval(60), isAllDay: false, location: nil)]
    }
    func changes() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

@main
private struct ScheduleProbe {
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        await ScheduleAuthorizationScenarios.run()
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
        }
        let day = date(2026, 3, 8)
        let nextDay = date(2026, 3, 9)
        precondition(nextDay.timeIntervalSince(day) == 23 * 3600)
        let midnightEnd = ScheduleEntry(id: "midnight", sourceID: "events", kind: .calendar,
                                        title: "Previous evening", start: date(2026, 3, 7, 23), end: day,
                                        isAllDay: false, location: nil)
        let overnight = ScheduleEntry(id: "overnight", sourceID: "events", kind: .calendar,
                                      title: "Overnight", start: date(2026, 3, 7, 23), end: date(2026, 3, 8, 3),
                                      isAllDay: false, location: nil)
        let allDay = ScheduleEntry(id: "all-day", sourceID: "events", kind: .calendar,
                                   title: "All day", start: day, end: nextDay, isAllDay: true, location: nil)
        let earlyReminder = ScheduleEntry(id: "early", sourceID: "tasks", kind: .reminders,
                                          title: "Before 04:00", start: date(2026, 3, 8, 1), end: nil,
                                          isAllDay: false, location: nil)
        let tomorrowReminder = ScheduleEntry(id: "tomorrow", sourceID: "tasks", kind: .reminders,
                                             title: "Tomorrow", start: nextDay, end: nil, isAllDay: true, location: nil)
        let grouped = ScheduleDay.make(date: day, entries: [midnightEnd, overnight, allDay, earlyReminder, tomorrowReminder], calendar: calendar)
        precondition(grouped.events.map(\.id) == ["all-day", "overnight"])
        precondition(grouped.reminders.map(\.id) == ["early"])
        precondition(!allDay.occurs(on: nextDay, calendar: calendar))
        print("PASS half-open midnight/all-day boundaries, cross-day events, 23-hour DST day and reminders before 04:00")

        let eventStore = EKEventStore()
        let reminderCalendar = EKCalendar(for: .reminder, eventStore: eventStore)
        let reminder = EKReminder(eventStore: eventStore)
        reminder.calendar = reminderCalendar
        reminder.title = "Date-only reminder"
        precondition(AppleRemindersService.entry(from: reminder, calendar: calendar) == nil)
        let dateOnly = DateComponents(calendar: calendar, timeZone: TimeZone(identifier: "Asia/Tokyo"),
                                      year: 2026, month: 3, day: 8)
        let projected = AppleRemindersService.dueDate(from: dateOnly, calendar: calendar)
        precondition(projected?.isAllDay == true && projected?.date == day)
        let timed = DateComponents(calendar: calendar, timeZone: calendar.timeZone,
                                   year: 2026, month: 3, day: 8, hour: 14, minute: 30)
        precondition(AppleRemindersService.dueDate(from: timed, calendar: calendar)?.date == date(2026, 3, 8, 14, 30))
        precondition(AppleRemindersService.dueDate(from: DateComponents(hour: 14), calendar: calendar) == nil)
        reminder.dueDateComponents = timed
        reminder.isCompleted = true
        precondition(AppleRemindersService.entry(from: reminder, calendar: calendar) == nil)
        let firstOccurrence = AppleRemindersService.occurrenceID(sourceID: "events", itemID: "same-series", occurrenceDate: day)
        let secondOccurrence = AppleRemindersService.occurrenceID(sourceID: "events", itemID: "same-series", occurrenceDate: nextDay)
        precondition(firstOccurrence != secondOccurrence)
        print("PASS production date projection preserves floating civil dates and explicit timed zones, rejects undated/completed reminders, and distinguishes recurring occurrences")

        let sources = [
            ScheduleSource(id: "events", title: "Research", account: "iCloud", kind: .calendar,
                           color: ScheduleColor(red: 0.35, green: 0.65, blue: 1)),
            ScheduleSource(id: "tasks", title: "Work", account: "iCloud", kind: .reminders,
                           color: ScheduleColor(red: 1, green: 0.6, blue: 0.12)),
            ScheduleSource(id: "ideas", title: "Ideas", account: "On My Mac", kind: .reminders,
                           color: ScheduleColor(red: 0.7, green: 0.5, blue: 1))
        ]
        let suite = "schedule-probe.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let range = DateInterval(start: day, end: nextDay)
        let fixture = FixtureService(calendarAccess: .fullAccess, reminderAccess: .fullAccess,
                                     sourceValues: sources, values: [allDay, earlyReminder])
        let store = ScheduleStore(service: fixture, defaults: defaults, calendar: calendar)
        await store.refresh(in: range)
        precondition(store.entries.contains { $0.id == "early" } && store.entries.contains { $0.id == "all-day" })
        for source in store.sources { store.setSelected(source, isSelected: false) }
        await store.refresh(in: range)
        precondition(store.entries.isEmpty)
        let restored = ScheduleStore(service: fixture, defaults: defaults, calendar: calendar)
        await restored.refresh(in: range)
        precondition(restored.sources.allSatisfy { !restored.isSelected($0) } && restored.entries.isEmpty)
        print("PASS all providers are queried independent of the drawer selection; explicitly selecting no sources survives reload")
        for source in restored.sources { restored.setSelected(source, isSelected: true) }
        let partial = ScheduleStore(service: FixtureService(calendarAccess: .fullAccess, reminderAccess: .fullAccess,
                                                            sourceValues: sources, values: [allDay, earlyReminder], failsCalendar: true),
                                    defaults: defaults, calendar: calendar)
        await partial.refresh(in: range)
        precondition(partial.entries.contains { $0.id == "early" } && !partial.errors.isEmpty)
        print("PASS a failed calendar read is visible without hiding successful reminder results")
        let stale = ScheduleStore(service: DelayedService(source: sources[0], pivot: nextDay), defaults: defaults, calendar: calendar)
        let oldTask = Task { await stale.refresh(in: range) }
        try await Task.sleep(for: .milliseconds(25))
        await stale.refresh(in: DateInterval(start: nextDay, end: date(2026, 3, 10)))
        await oldTask.value
        precondition(stale.entries.map(\.title) == ["new"])
        print("PASS a late previous-date response cannot overwrite the latest visible range")

        let nowCalendar = Calendar.autoupdatingCurrent
        let today = nowCalendar.startOfDay(for: Date())
        func offset(_ days: Int, hour: Int = 0, minute: Int = 0) -> Date {
            let day = nowCalendar.date(byAdding: .day, value: days, to: today)!
            return nowCalendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
        }
        var displayEntries = [
            ScheduleEntry(id: "meeting", sourceID: "events", kind: .calendar, title: "Research group meeting",
                          start: offset(0, hour: 14), end: offset(0, hour: 15), isAllDay: false, location: "Room 302"),
            ScheduleEntry(id: "deadline", sourceID: "tasks", kind: .reminders, title: "Submit experiment notes",
                          start: offset(0, hour: 18), end: nil, isAllDay: false, location: nil),
            ScheduleEntry(id: "idea", sourceID: "ideas", kind: .reminders, title: "Review the contrastive learning idea",
                          start: today, end: nil, isAllDay: true, location: nil),
            ScheduleEntry(id: "multi", sourceID: "events", kind: .calendar, title: "Workshop · all-day multi-day event",
                          start: offset(1), end: offset(3), isAllDay: true, location: nil),
            ScheduleEntry(id: "previous", sourceID: "tasks", kind: .reminders, title: "Read reference paper",
                          start: offset(-1), end: nil, isAllDay: true, location: nil)
        ]
        for index in 0..<12 {
            displayEntries.append(ScheduleEntry(id: "dense-\(index)", sourceID: "tasks", kind: .reminders,
                                                title: "Follow up on task \(index + 1)", start: offset(2, hour: 9 + index),
                                                end: nil, isAllDay: false, location: nil))
        }
        let displayStore = ScheduleStore(service: FixtureService(calendarAccess: .fullAccess, reminderAccess: .fullAccess,
                                                                 sourceValues: sources, values: displayEntries), defaults: defaults)
        await displayStore.refresh(in: DateInterval(start: offset(-30), end: offset(31)))
        for typography in InterfaceTextSize.allCases {
            for size in [CGSize(width: 300, height: 310), CGSize(width: 520, height: 370), CGSize(width: 760, height: 450)] {
                let host = makeHost(SchedulePanelView(store: displayStore, size: size, isDrawerExpanded: true, onOpenSettings: {})
                    .environment(\.appTypography, AppTypography(interfaceSize: typography)), size: size)
                await settle(host)
                try render(host, at: output.appendingPathComponent("schedule-\(Int(size.width))-\(typography.rawValue).png"))
            }
        }
        let navigationSize = CGSize(width: 520, height: 370)
        let navigationHost = makeHost(
            SchedulePanelView(store: displayStore, size: navigationSize, isDrawerExpanded: true, onOpenSettings: {}),
            size: navigationSize
        )
        await settle(navigationHost)
        let initialRange = displayStore.range
        guard let scroll = horizontalScrollView(in: navigationHost), let document = scroll.documentView else {
            preconditionFailure("The schedule must provide a horizontal day scroller")
        }
        // Change only an invisible host's clip bounds, not the user's desktop input.
        scroll.contentView.scroll(to: CGPoint(
            x: document.bounds.width - scroll.contentView.bounds.width - 600, y: 0
        ))
        scroll.reflectScrolledClipView(scroll.contentView)
        await settle(navigationHost)
        precondition(displayStore.range.end > initialRange.end,
                     "Scrolling near the last day must load later dates, not stop at the initial month")
        try render(navigationHost, at: output.appendingPathComponent("schedule-scrolled-later.png"))
        print("PASS scrolling the actual offscreen day strip extends its query beyond the initial month")
        scroll.contentView.scroll(to: CGPoint(x: 600, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        await settle(navigationHost)
        precondition(displayStore.range.start < initialRange.start,
                     "Scrolling toward earlier dates must load the preceding month")
        precondition(scroll.contentView.bounds.minX > 600,
                     "Prepending earlier days must preserve the visible date rather than jump to the new document origin")
        try render(navigationHost, at: output.appendingPathComponent("schedule-scrolled-earlier.png"))
        print("PASS scrolling backward extends earlier dates and preserves the visible day after prepending")
        displayStore.setVisible(false)
        for (name, calendarAccess, reminderAccess) in [
            ("denied", ScheduleAuthorization.denied, ScheduleAuthorization.denied),
            ("empty", .fullAccess, .fullAccess),
            ("reminders-only", .denied, .fullAccess)
        ] {
            let fixture = FixtureService(calendarAccess: calendarAccess, reminderAccess: reminderAccess,
                                         sourceValues: sources, values: name == "empty" ? [] : displayEntries)
            let state = ScheduleStore(service: fixture, defaults: defaults)
            await state.refresh(in: DateInterval(start: offset(-30), end: offset(31)))
            let size = CGSize(width: 520, height: 370)
            let host = makeHost(SchedulePanelView(store: state, size: size, isDrawerExpanded: true, onOpenSettings: {}), size: size)
            await settle(host)
            try render(host, at: output.appendingPathComponent("schedule-\(name).png"))
            state.setVisible(false)
        }
        let settingsHost = makeHost(Form { ScheduleSourcesSettingsView(store: displayStore) }.formStyle(.grouped),
                                    size: CGSize(width: 520, height: 460))
        await settle(settingsHost)
        try render(settingsHost, at: output.appendingPathComponent("schedule-sources-settings.png"))
        print("PASS rendered actual schedule/source views offscreen at three widths and text sizes, denied/empty/partial access")
        let realService = AppleRemindersService()
        print("Real EventKit access: calendars=\(realService.authorization(for: .calendar)), reminders=\(realService.authorization(for: .reminders))")
        for kind in ScheduleSourceKind.allCases where realService.authorization(for: kind).canRead {
            let realSources = await realService.sources(for: kind)
            let snapshots = try await realService.entries(
                in: DateInterval(start: offset(-7), end: offset(8)), sources: realSources
            )
            print("PASS real EventKit read: \(kind.rawValue), \(realSources.count) readable sources, \(snapshots.count) dated items; no titles logged")
        }
        print("Previews: \(output.path)")
        print("No permission requests, EventKit saves, visible windows, mouse/keyboard control or desktop event dispatch")
    }

    @MainActor private static var windows: [NSWindow] = []

    @MainActor private static func makeHost<V: View>(_ view: V, size: CGSize) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(view.preferredColorScheme(.dark)))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        windows.append(window)
        return host
    }

    @MainActor private static func horizontalScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView,
           let document = scroll.documentView,
           document.bounds.width > scroll.contentView.bounds.width + 100 {
            return scroll
        }
        for child in view.subviews {
            if let scroll = horizontalScrollView(in: child) { return scroll }
        }
        return nil
    }

    @MainActor private static func settle(_ host: NSView) async {
        for _ in 0..<12 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(25))
        }
        host.layoutSubtreeIfNeeded()
    }

    @MainActor private static func render(_ host: NSView, at url: URL) throws {
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
}
