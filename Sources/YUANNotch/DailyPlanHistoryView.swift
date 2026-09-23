import SwiftUI

struct DailyPlanHistoryView: View {
    let store: DailyPlanStore

    @State private var snapshot: DailyPlanHistorySnapshot

    @MainActor init(store: DailyPlanStore) {
        self.store = store
        _snapshot = State(initialValue: DailyPlanHistorySnapshot(store: store))
    }

    var body: some View {
        DailyPlanHistoryContent(snapshot: snapshot)
        .onAppear {
            snapshot = DailyPlanHistorySnapshot(store: store)
        }
    }
}

private struct DailyPlanHistorySnapshot {
    let now: Date
    let focusedSecondsByDay: [PlanDayKey: TimeInterval]

    @MainActor init(store: DailyPlanStore) {
        let calendar = Calendar.autoupdatingCurrent
        now = store.now
        var totals: [PlanDayKey: TimeInterval] = [:]
        for record in store.dayRecords {
            totals[record.day, default: 0] += record.focusedSeconds
        }

        if let session = store.activeSession {
            if session.phase == .focus, let startedAt = session.runningSince {
                let available = max(session.phaseDuration - session.phaseElapsed, 0)
                let end = min(now, startedAt.addingTimeInterval(available))
                for (day, seconds) in DailyPlanEngine.splitFocusInterval(
                    from: startedAt,
                    to: end,
                    calendar: calendar
                ) {
                    totals[day, default: 0] += seconds
                }
            }
        }

        focusedSecondsByDay = totals
    }

    func focusedSeconds(on date: Date, calendar: Calendar) -> TimeInterval {
        focusedSecondsByDay[PlanDayKey(date: date, calendar: calendar)] ?? 0
    }
}

private struct DailyPlanHistoryContent: View {
    let snapshot: DailyPlanHistorySnapshot

    @State private var monthCount = 18

    private let calendar = Calendar.autoupdatingCurrent
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 7)

    private var latestMonth: Date {
        calendar.dateInterval(of: .month, for: snapshot.now)?.start ?? snapshot.now
    }

    private var latestDay: Date {
        calendar.startOfDay(for: snapshot.now)
    }

    private var months: [Date] {
        (0 ..< monthCount).compactMap {
            calendar.date(byAdding: .month, value: -$0, to: latestMonth)
        }
    }

    private var weekdayTitles: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return (0 ..< symbols.count).map { offset in
            symbols[(calendar.firstWeekday - 1 + offset) % symbols.count]
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                historyToolbar {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(latestDay, anchor: .center)
                    }
                }

                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(months, id: \.self) { month in
                            monthSection(month)
                                .id(month)
                                .onAppear { loadMoreIfNeeded(whenShowing: month) }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private func historyToolbar(scrollToLatest: @escaping () -> Void) -> some View {
        HStack {
            Text("Daily focus time")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.58))

            Spacer()

            Button(action: scrollToLatest) {
                Label("Today", systemImage: "arrow.up.to.line")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.78))
                    .padding(.horizontal, 9)
                    .frame(height: 25)
                    .background(Capsule().fill(.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .help("Scroll to today")
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
    }

    private func monthSection(_ month: Date) -> some View {
        let monthStart = calendar.dateInterval(of: .month, for: month)?.start ?? month
        let dayRange = calendar.range(of: .day, in: .month, for: monthStart) ?? 1 ..< 29
        let weekday = calendar.component(.weekday, from: monthStart)
        let leadingDays = (weekday - calendar.firstWeekday + 7) % 7

        return VStack(alignment: .leading, spacing: 6) {
            Text(monthStart.formatted(.dateTime.month(.wide).year()))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))
                .padding(.leading, 2)

            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(Array(weekdayTitles.enumerated()), id: \.offset) { _, title in
                    Text(title)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.white.opacity(0.32))
                        .frame(maxWidth: .infinity)
                        .frame(height: 11)
                }

                ForEach(0 ..< leadingDays, id: \.self) { _ in
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                }

                ForEach(dayRange, id: \.self) { day in
                    let date = calendar.date(byAdding: .day, value: day - 1, to: monthStart) ?? monthStart
                    dayCell(day, date: date)
                }
            }
        }
    }

    private func dayCell(_ day: Int, date: Date) -> some View {
        let focusedSeconds = snapshot.focusedSeconds(on: date, calendar: calendar)
        let focusedMinutes = max(Int(focusedSeconds / 60), 0)
        let isFuture = calendar.startOfDay(for: date) > latestDay
        let isToday = calendar.isDate(date, inSameDayAs: latestDay)
        let duration = isFuture ? "" : compactDuration(focusedMinutes)

        return VStack(spacing: 1) {
            Text("\(day)")
                .font(.system(size: 11, weight: isToday ? .semibold : .regular))
                .foregroundStyle(isFuture ? .white.opacity(0.22) : .white.opacity(0.68))

            Text(duration.isEmpty ? " " : duration)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isFuture ? .clear : .white.opacity(0.78))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(width: 48, height: 48)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isFuture ? Color.white.opacity(0.025) : heatColor(for: focusedMinutes))
        )
        .overlay {
            if isToday {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.orange.opacity(0.76), lineWidth: 1)
            }
        }
        .frame(maxWidth: .infinity)
        .id(date)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(date.formatted(date: .complete, time: .omitted)), \(isFuture ? "future date" : "\(compactDuration(focusedMinutes)) focused")"
        )
    }

    private func loadMoreIfNeeded(whenShowing month: Date) {
        guard let oldestMonth = months.last,
              calendar.isDate(month, equalTo: oldestMonth, toGranularity: .month) else { return }
        monthCount += 12
    }

    private func heatColor(for focusedMinutes: Int) -> Color {
        guard focusedMinutes > 0 else { return .white.opacity(0.045) }
        let intensity = min(Double(focusedMinutes) / 240, 1)
        return .orange.opacity(0.14 + intensity * 0.74)
    }

    private func compactDuration(_ minutes: Int) -> String {
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours > 0, remainder > 0 { return "\(hours)h\(remainder)" }
        if hours > 0 { return "\(hours)h" }
        return "\(remainder)m"
    }
}
