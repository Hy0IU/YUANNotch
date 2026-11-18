import Foundation

@main
struct TimezoneProbe {
    @MainActor
    static func main() throws {
        var failures = 0
        func check(_ label: String, _ passes: Bool) {
            print("\(passes ? "PASS" : "FAIL") \(label)")
            if !passes { failures += 1 }
        }
        func calendar(_ zone: String) -> Calendar {
            var value = Calendar(identifier: .gregorian)
            value.timeZone = TimeZone(identifier: zone)!
            return value
        }
        let pacific = calendar("America/Los_Angeles")
        let shanghai = calendar("Asia/Shanghai")
        func date(_ calendar: Calendar, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
        }

        for (month, day) in [(3, 8), (11, 1)] {
            let now = date(pacific, month, day)
            let nine = date(pacific, month, day, 9)
            let explicit = DueSelection(date: .today, time: .morning9).resolution(now: now, calendar: pacific)
            let timeOnly = DueSelection(time: .morning9).resolution(now: now, calendar: pacific)
            check("DST \(month)/\(day): explicit and time-only 09:00 stay at wall-clock 09:00",
                  explicit.instant == nine && timeOnly.instant == nine)
            let afternoon = date(pacific, month, day, 15)
            let tomorrow = pacific.date(byAdding: .day, value: 1, to: now)!
            let tomorrowNine = pacific.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)!
            check("DST \(month)/\(day): a passed time-only choice rolls to tomorrow at 09:00",
                  DueSelection(time: .morning9).resolution(now: afternoon, calendar: pacific).instant == tomorrowNine)
            let composer = ReminderComposer(nowProvider: { now }, calendar: pacific)
            composer.draft = "Meeting"
            composer.select(dateOption: .today)
            composer.select(timeOption: .morning9)
            check("DST \(month)/\(day): composed preview and submitted reminder agree",
                  composer.resolution(now: now).due?.date == nine && composer.consume()?.due?.date == nine)
        }

        let civil = DateComponents(calendar: shanghai, timeZone: TimeZone(identifier: "Asia/Tokyo"),
                                   year: 2026, month: 3, day: 8)
        for viewing in [pacific, shanghai] {
            let expected = date(viewing, 3, 8)
            check("date-only reminder stays on March 8 in \(viewing.timeZone.identifier)",
                  ReminderSnapshot.date(from: civil, calendar: viewing) == expected
                    && AppleRemindersService.dueDate(from: civil, calendar: viewing)?.date == expected)
        }
        let zoned = DateComponents(calendar: shanghai, timeZone: shanghai.timeZone,
                                   year: 2026, month: 3, day: 8, hour: 9)
        check("timed reminders honor explicit zones in both consumers",
              ReminderSnapshot.date(from: zoned, calendar: pacific) == date(shanghai, 3, 8, 9)
                && AppleRemindersService.dueDate(from: zoned, calendar: pacific)?.date == date(shanghai, 3, 8, 9))
        let floating = DateComponents(calendar: shanghai, year: 2026, month: 3, day: 8, hour: 9)
        check("floating timed components use the viewing zone, not an embedded calendar zone",
              ReminderSnapshot.date(from: floating, calendar: pacific) == date(pacific, 3, 8, 9))
        check("incomplete dates are not synthesized and second-level dates are timed",
              ReminderSnapshot.date(from: DateComponents(hour: 9), calendar: pacific) == nil
                && !ReminderSnapshot.isAllDay(DateComponents(year: 2026, month: 3, day: 8, second: 30)))

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("yuannotch-timezone-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = DailyPlanPersistence(fileURL: root.appendingPathComponent("plans.json"))
        let plan = DailyPlan(title: "Reading", targetMinutes: 60)
        let selected = date(shanghai, 9, 23)
        let selectedDay = PlanDayKey(date: selected, calendar: shanghai)
        let previousDay = PlanDayKey(date: date(shanghai, 9, 22), calendar: shanghai)
        try persistence.save(DailyPlanArchive(plans: [plan], dayRecords: [
            DailyPlanDayRecord(planID: plan.id, day: selectedDay, focusedSeconds: 600),
            DailyPlanDayRecord(planID: plan.id, day: previousDay, focusedSeconds: 37)
        ]))
        let now = date(shanghai, 9, 24, 12)
        let origin = DailyPlanStore(persistence: persistence, calendar: shanghai, nowProvider: { now }, startsTimer: false)
        origin.beginEditingTime(on: selected)
        origin.timeDraft!.entries[0].minutes = 20
        // Replay the already-built draft through the same consumer in the new
        // zone. No OS timezone preference is changed by this probe.
        let destination = DailyPlanStore(persistence: persistence, calendar: pacific, nowProvider: { now }, startsTimer: false)
        destination.timeDraft = origin.timeDraft
        check("built history drafts keep their civil-day identity across zone projections",
              PlanDayKey(date: selected, calendar: pacific) == previousDay
                && destination.timeDraft?.day == selectedDay)
        destination.commitTimeDraft()
        let saved = persistence.load()
        check("saving a pre-travel draft edits the selected day and preserves neighboring history",
              saved.dayRecords.first(where: { $0.day == selectedDay })?.focusedSeconds == 1_200
                && saved.dayRecords.first(where: { $0.day == previousDay })?.focusedSeconds == 37
                && destination.timeDraft == nil)
        let beforeFour = date(pacific, 3, 8, 3, 30)
        check("Goals retain local 04:00 while Schedule uses the natural day",
              PlanDayKey(date: DailyPlanEngine.dayStart(containing: beforeFour, calendar: pacific), calendar: pacific)
                == PlanDayKey(date: date(pacific, 3, 7), calendar: pacific)
                && pacific.startOfDay(for: beforeFour) == date(pacific, 3, 8))
        print(failures == 0 ? "every check passed" : "\(failures) checks failed")
        if failures > 0 { exit(1) }
    }
}
