import AppKit
import SwiftUI

// YUANNotch · reminder composer probe
//
// The bug this guards: the reminders panel's compose row was `@State`, and the
// drawer throws that whole surface away on every switch to the notes side — so a
// half-typed reminder, and the due date chosen beside it, left with the view.
//
// Checks:
//   1. the due-date rules the composer now owns: `parseClockTime`'s loose forms,
//      the date x time resolution table, and the relative shortcuts — all against
//      a fixed clock and calendar, not the wall clock.
//   2. the composer's own pipeline: what enables "Add", when the custom row
//      appears, the typed-time contract, the wheel-to-text sync, and the order a
//      commit empties the row in.
//   3. the ownership fix itself, measured: a branch swap in a hosted view
//      discards a view's own `@State` and keeps the composer, which lives above
//      the branch.
//   4. that the panel did not quietly re-declare this state: the defect this
//      change removed was a view-owned copy of it, so a new `@State` holding any
//      of it is the bug coming back.
//
// It compiles the shipping ReminderComposer.swift, and needs no permissions. It
// writes nothing.

/// Stand-in for the app's own value type, which lives in another file.
struct ReminderDue: Equatable {
    let date: Date
    let isAllDay: Bool
}

// MARK: - Result bookkeeping

@MainActor
private var failures = 0

@MainActor
private func check(_ passed: Bool, _ label: String, _ detail: String) {
    print("\(passed ? "PASS" : "FAIL")  \(label)")
    print("      \(detail)")
    if !passed { failures += 1 }
}

// MARK: - A fixed clock

private enum Clock {
    /// A Thursday, so "this weekend" has to move and "next week" is the coming
    /// Monday rather than today.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar
    }()

    static func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        )!
    }

    static let thursday = at(2026, 9, 17, 14, 0)
    static let saturday = at(2026, 9, 19, 10, 0)
    static let monday = at(2026, 9, 21, 8, 0)
    static let lateEvening = at(2026, 9, 17, 23, 50)
}

/// A resolved due date, written as the two things it can get wrong: which day it
/// lands on (as a whole-day offset from `now`) and what time of day it carries.
private func describe(_ due: ReminderDue?, now: Date) -> String {
    guard let due else { return "no due date" }
    let today = Clock.calendar.startOfDay(for: now)
    let day = Clock.calendar.startOfDay(for: due.date)
    let offset = Clock.calendar.dateComponents([.day], from: today, to: day).day ?? 0
    guard !due.isAllDay else { return "day+\(offset) all-day" }
    let parts = Clock.calendar.dateComponents([.hour, .minute], from: due.date)
    return String(format: "day+%d %02d:%02d", offset, parts.hour ?? 0, parts.minute ?? 0)
}

@MainActor
private func composer(
    date: DueDateOption = .none,
    time: DueTimeOption = .none,
    customDate: Date? = nil,
    customTime: Date? = nil
) -> ReminderComposer {
    let composer = ReminderComposer()
    // Options first, then the custom values: entering Custom deliberately starts
    // from today, so a date set before the option would be overwritten by it.
    composer.select(dateOption: date)
    composer.select(timeOption: time)
    if let customDate { composer.setCustomDate(customDate) }
    if let customTime { composer.setCustomTime(customTime) }
    return composer
}

// MARK: - 1 · The rules the composer owns

@MainActor
private func checkParsing() {
    print("— 1 · the loose forms a person types —")

    let accepted: [(String, String)] = [
        ("21:00", "21:00"), ("21.00", "21:00"), ("2130", "21:30"), ("930", "09:30"),
        ("21", "21:00"), ("9", "09:00"), ("9pm", "21:00"), ("9 pm", "21:00"),
        ("9:30pm", "21:30"), ("9.30 pm", "21:30"), ("9a.m.", "09:00"), ("12am", "00:00"),
        ("12pm", "12:00"), ("9：30", "09:30")
    ]
    var wrong: [String] = []
    for (raw, expected) in accepted {
        guard let parsed = ReminderComposer.parseClockTime(raw) else {
            wrong.append("\(raw) -> nil, wanted \(expected)")
            continue
        }
        let got = String(format: "%02d:%02d", parsed.hour, parsed.minute)
        if got != expected { wrong.append("\(raw) -> \(got), wanted \(expected)") }
    }
    check(
        wrong.isEmpty,
        "every accepted form parses",
        wrong.isEmpty ? "\(accepted.count) forms: 21:00 / 21.00 / 2130 / 930 / 9pm / 12am / 9：30 …" : wrong.joined(separator: "; ")
    )

    let rejected = ["", "   ", "abc", "24:00", "12:60", "9:xx", "12345", "0:70", "13pm", "0pm"]
    let acceptedByMistake = rejected.filter { ReminderComposer.parseClockTime($0) != nil }
    check(
        acceptedByMistake.isEmpty,
        "an out-of-range or unreadable time parses to nothing",
        acceptedByMistake.isEmpty
            ? "\(rejected.count) rejected: 24:00 / 12:60 / 13pm / 12345 …"
            : "accepted by mistake: \(acceptedByMistake.joined(separator: ", "))"
    )
}

@MainActor
private func checkResolutionTable() {
    print("")
    print("— 2 · the date x time table, at a fixed Thursday 14:00 —")

    var wrong: [String] = []
    func expect(_ label: String, _ actual: String, _ wanted: String) {
        if actual != wanted { wrong.append("\(label): got \(actual), want \(wanted)") }
    }

    let now = Clock.thursday
    expect(
        "no date, no time",
        describe(composer().resolution(now: now).due, now: now),
        "no due date"
    )
    expect(
        "today, no time",
        describe(composer(date: .today).resolution(now: now).due, now: now),
        "day+0 all-day"
    )
    expect(
        "tomorrow, no time",
        describe(composer(date: .tomorrow).resolution(now: now).due, now: now),
        "day+1 all-day"
    )
    expect(
        "this weekend (from a Thursday)",
        describe(composer(date: .thisWeekend).resolution(now: now).due, now: now),
        "day+2 all-day"
    )
    expect(
        "this weekend (from a Saturday)",
        describe(composer(date: .thisWeekend).resolution(now: Clock.saturday).due, now: Clock.saturday),
        "day+0 all-day"
    )
    expect(
        "next week (from a Thursday)",
        describe(composer(date: .nextWeek).resolution(now: now).due, now: now),
        "day+4 all-day"
    )
    expect(
        "next week (from a Monday is never today)",
        describe(composer(date: .nextWeek).resolution(now: Clock.monday).due, now: Clock.monday),
        "day+7 all-day"
    )
    expect(
        "a time whose moment has passed rolls to tomorrow",
        describe(composer(time: .morning9).resolution(now: now).due, now: now),
        "day+1 09:00"
    )
    expect(
        "a time still ahead stays today",
        describe(composer(time: .evening18).resolution(now: now).due, now: now),
        "day+0 18:00"
    )
    expect(
        "today with a time",
        describe(composer(date: .today, time: .evening18).resolution(now: now).due, now: now),
        "day+0 18:00"
    )
    expect(
        "a day-level date carries no alarm",
        "\(composer(date: .tomorrow).resolution(now: now).due?.isAllDay == true)",
        "true"
    )
    expect(
        "custom date with a preset time",
        describe(
            composer(
                date: .custom,
                time: .noon12,
                customDate: Clock.at(2026, 10, 3, 0, 0)
            ).resolution(now: now).due,
            now: now
        ),
        "day+16 12:00"
    )
    expect(
        "relative 15 minutes",
        describe(composer(time: .custom).applyRelativeProbe(minutes: 15, now: now).resolution(now: now).due, now: now),
        "day+0 14:15"
    )
    expect(
        "relative 1 hour",
        describe(composer(time: .custom).applyRelativeProbe(minutes: 60, now: now).resolution(now: now).due, now: now),
        "day+0 15:00"
    )
    expect(
        "relative past midnight lands on tomorrow",
        describe(
            composer(time: .custom).applyRelativeProbe(minutes: 15, now: Clock.lateEvening).resolution(now: Clock.lateEvening).due,
            now: Clock.lateEvening
        ),
        "day+1 00:05"
    )

    check(
        wrong.isEmpty,
        "the table resolves every combination",
        wrong.isEmpty
            ? "14 combinations: day-level vs timed, the roll past a time of day, an under-way weekend, next week from a Monday, and both relative shortcuts"
            : wrong.joined(separator: "; ")
    )
}

private extension ReminderComposer {
    /// `applyRelative` with the clock pinned, so the shortcut can be checked
    /// against a fixed Thursday instead of today.
    @discardableResult
    func applyRelativeProbe(minutes: Int, now: Date) -> ReminderComposer {
        applyRelative(minutes: minutes, now: now)
        return self
    }
}

// MARK: - 3 · The composer's own pipeline

@MainActor
private func checkPipeline() {
    print("")
    print("— 3 · what a commit does —")

    let now = Clock.thursday
    let composer = ReminderComposer()

    check(
        !composer.canCommit && !composer.showsCustomRow,
        "an empty row offers nothing",
        "canCommit=\(composer.canCommit), showsCustomRow=\(composer.showsCustomRow)"
    )

    composer.draft = "   "
    let whitespaceOnly = composer.canCommit
    composer.draft = "买牛奶"
    check(
        !whitespaceOnly && composer.canCommit,
        "whitespace alone is not a reminder",
        "spaces -> \(whitespaceOnly), text -> \(composer.canCommit)"
    )

    composer.select(dateOption: .custom)
    composer.select(timeOption: .custom)
    let customRowShown = composer.showsCustomRow
    composer.select(dateOption: .none)
    composer.select(timeOption: .none)
    check(
        customRowShown && !composer.showsCustomRow,
        "the custom inputs appear only while a half is custom",
        "both custom -> \(customRowShown), both none -> \(composer.showsCustomRow)"
    )

    // The typed-time contract: text that does not parse is a warning, not a
    // rejection — the last value that parsed stays in force.
    composer.select(timeOption: .custom)
    composer.setCustomTimeText("19:30")
    composer.setCustomTimeText("half past seven")
    let keptValue = composer.customTimeText
    let flagged = composer.customTimeParseFailed
    let stillNineteenThirty = describe(composer.resolution(now: now).due, now: now) == "day+0 19:30"
    composer.setCustomTimeText("")
    let cleared = !composer.customTimeParseFailed
    check(
        flagged && stillNineteenThirty && cleared && keptValue == "half past seven",
        "unreadable text warns without discarding the last good time",
        "field kept \"\(keptValue)\", flagged=\(flagged), value still 19:30=\(stillNineteenThirty), empty field clears the warning=\(cleared)"
    )

    // The wheel and the field are two views onto one time.
    composer.setCustomTime(Clock.at(2026, 9, 17, 7, 5))
    let textAfterWheel = composer.customTimeText
    let parses = ReminderComposer.parseClockTime(textAfterWheel).map { String(format: "%02d:%02d", $0.hour, $0.minute) }
    check(
        parses == "07:05",
        "moving the wheel rewrites the field",
        "wheel at 07:05 -> field \"\(textAfterWheel)\""
    )

    // A commit empties the row and hands back what to write.
    composer.draft = "交周报"
    composer.select(dateOption: .tomorrow)
    composer.select(timeOption: .morning9)
    let pending = composer.consume(now: now)
    let expectedDue = describe(pending?.due, now: now)
    check(
        pending?.title == "交周报"
            && expectedDue == "day+1 09:00"
            && composer.draft.isEmpty
            && composer.dateOption == .none
            && composer.timeOption == .none
            && !composer.canCommit,
        "a commit returns the payload and empties the row",
        "title=\(pending?.title ?? "nil"), due=\(expectedDue), draft cleared=\(composer.draft.isEmpty), due row reset=\(composer.dateOption == .none && composer.timeOption == .none)"
    )

    composer.draft = "  "
    let emptyConsume = composer.consume(now: now)
    check(
        emptyConsume == nil,
        "a commit with nothing to write returns nothing",
        "whitespace-only draft -> \(emptyConsume == nil ? "nil" : "a payload")"
    )
}

// MARK: - 4 · The ownership fix, measured

/// The one thing the harness flips, standing in for `AppSettingsStore.drawerMode`.
@MainActor
private final class SwapFlag: ObservableObject {
    @Published var showsReminders = true
    @Published var keystrokes = 0
}

@MainActor
private enum Recorded {
    static var values: [String: String] = [:]
}

/// `NotebookView`'s shape: one surface or the other, never both.
private struct ProbeSurface: View {
    @ObservedObject var flag: SwapFlag
    let composer: ReminderComposer

    var body: some View {
        if flag.showsReminders {
            ProbeComposeRow(flag: flag, composer: composer)
        } else {
            Color.clear
        }
    }
}

private struct ProbeComposeRow: View {
    @ObservedObject var flag: SwapFlag
    @ObservedObject var composer: ReminderComposer

    /// The design the bug came from: the same text owned by the view.
    @State private var viewOwnedDraft = ""

    var body: some View {
        let _ = { Recorded.values["composer"] = composer.draft }()
        let _ = { Recorded.values["view"] = viewOwnedDraft }()

        VStack(spacing: 4) {
            TextField("New reminder", text: $composer.draft)
            Text(viewOwnedDraft)
        }
        .onChange(of: flag.keystrokes) { _, _ in
            // Stands in for typing: the composer is written the way the field
            // writes it, and the view's own copy the way the old field did.
            composer.draft = "买牛奶"
            viewOwnedDraft = "买牛奶"
        }
    }
}

@MainActor
private func makeHost(flag: SwapFlag, composer: ReminderComposer) -> NSHostingView<AnyView> {
    let host = NSHostingView(rootView: AnyView(
        ProbeSurface(flag: flag, composer: composer)
            .frame(width: 320, height: 80)
    ))
    host.frame = NSRect(x: 0, y: 0, width: 320, height: 80)
    let window = NSWindow(
        contentRect: host.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = host
    settle(host)
    return host
}

@MainActor
private func settle(_ host: NSHostingView<AnyView>) {
    for _ in 0 ..< 4 {
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
    }
}

@MainActor
private func checkOwnership() {
    print("")
    print("— 4 · the drawer swaps the surface, the draft stays —")

    let flag = SwapFlag()
    let composer = ReminderComposer()
    let host = makeHost(flag: flag, composer: composer)

    withExtendedLifetime(host) {
        // "Type" into the row.
        flag.keystrokes += 1
        settle(host)
        let typed = Recorded.values["composer"] ?? ""
        let typedViewCopy = Recorded.values["view"] ?? ""
        check(
            typed == "买牛奶" && typedViewCopy == "买牛奶",
            "typing reaches both the composer and the view's own copy",
            "composer=\"\(typed)\", view=\"\(typedViewCopy)\""
        )

        // The drawer switches to the notes surface and back.
        flag.showsReminders = false
        settle(host)
        let gone = Recorded.values["view"] ?? ""
        flag.showsReminders = true
        settle(host)

        let survived = Recorded.values["composer"] ?? ""
        let viewCopyAfter = Recorded.values["view"] ?? ""
        check(
            survived == "买牛奶",
            "the composer's draft survives the round trip",
            "draft after leaving and returning = \"\(survived)\""
        )
        check(
            viewCopyAfter.isEmpty,
            "and the view's own copy does not — which was the bug",
            "view-owned @State: \"\(typedViewCopy)\" before the swap, \"\(viewCopyAfter)\" after"
        )
        _ = gone
    }
}

// MARK: - 5 · The panel holds no copy of this state

@MainActor
private func checkPanelHoldsNoCopy(path: String) {
    print("")
    print("— 5 · the panel keeps no view-owned copy —")

    guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
        check(false, "the panel's source could be read", "could not read \(path)")
        return
    }

    let forbidden = [
        "@State private var draft",
        "@State private var dueDateOption",
        "@State private var dueTimeOption",
        "@State private var customTime",
        "@State private var customDate",
        "@State private var customTimeText",
        "@State private var isTimeWheelShown",
        "private var showsCustomRow",
        "private func parseClockTime",
    ]
    let present = forbidden.filter { source.contains($0) }

    check(
        present.isEmpty,
        "none of the composer's state is declared by the view",
        present.isEmpty
            ? "checked \(forbidden.count) declarations: a view-owned copy of any of them is how this bug returns"
            : "still declared in the panel: \(present.joined(separator: ", "))"
    )
}

// MARK: - Entry point

// A main.swift's top-level code is only main-actor isolated in Swift 6 language
// mode; the probe compiles under Swift 5, so it says so here.
MainActor.assumeIsolated {
    _ = NSApplication.shared

    print("=== YUANNotch · reminder composer probe ===")
    print("")
    if CommandLine.arguments.count > 1 {
        checkPanelHoldsNoCopy(path: CommandLine.arguments[1])
    } else {
        print("note: no panel source path given, skipping the view-owned-copy check")
        print("")
    }
    checkParsing()
    checkResolutionTable()
    checkPipeline()
    checkOwnership()

    print("")
    print(failures == 0 ? "every check passed" : "\(failures) check(s) failed")
    exit(failures == 0 ? 0 : 1)
}
