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
    @Environment(\.displayScale) private var displayScale

    private let calendar = Calendar.autoupdatingCurrent
    private let columnSpacing: CGFloat = 8
    private let maximumCellSide: CGFloat = 52
    private let minimumCellSide: CGFloat = 30

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

                GeometryReader { geometry in
                    let cellSide = cellSide(for: geometry.size.width)

                    ScrollView(.vertical) {
                        LazyVStack(alignment: .center, spacing: 16) {
                            ForEach(months, id: \.self) { month in
                                monthSection(month, cellSide: cellSide)
                                    .id(month)
                                    .onAppear { loadMoreIfNeeded(whenShowing: month) }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    }
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

    private func cellSide(for availableWidth: CGFloat) -> CGFloat {
        let availableGridWidth = max(availableWidth - 20, 0)
        let spacingWidth = columnSpacing * 6
        let fittingSide = max((availableGridWidth - spacingWidth) / 7, 0)
        let scale = max(displayScale, 1)
        let pixelAlignedSide = floor(fittingSide * scale) / scale
        return min(maximumCellSide, max(minimumCellSide, pixelAlignedSide))
    }

    private func monthSection(_ month: Date, cellSide: CGFloat) -> some View {
        let monthStart = calendar.dateInterval(of: .month, for: month)?.start ?? month
        let dayRange = calendar.range(of: .day, in: .month, for: monthStart) ?? 1 ..< 29
        let weekday = calendar.component(.weekday, from: monthStart)
        let leadingDays = (weekday - calendar.firstWeekday + 7) % 7
        let gridWidth = cellSide * 7 + columnSpacing * 6
        let columns = Array(repeating: GridItem(.fixed(cellSide), spacing: columnSpacing), count: 7)

        return VStack(alignment: .leading, spacing: 6) {
            Text(monthStart.formatted(.dateTime.month(.wide).year()))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))
                .padding(.leading, 2)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 5) {
                ForEach(Array(weekdayTitles.enumerated()), id: \.offset) { _, title in
                    Text(title)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.white.opacity(0.32))
                        .frame(width: cellSide, height: 11)
                }

                ForEach(0 ..< leadingDays, id: \.self) { _ in
                    Color.clear
                        .frame(width: cellSide, height: cellSide)
                }

                ForEach(dayRange, id: \.self) { day in
                    let date = calendar.date(byAdding: .day, value: day - 1, to: monthStart) ?? monthStart
                    dayCell(day, date: date, cellSide: cellSide)
                }
            }
        }
        .frame(width: gridWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func dayCell(_ day: Int, date: Date, cellSide: CGFloat) -> some View {
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
        .frame(width: cellSide, height: cellSide)
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
