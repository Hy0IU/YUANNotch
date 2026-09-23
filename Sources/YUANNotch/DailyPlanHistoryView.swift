import SwiftUI

struct DailyPlanHistoryView: View {
    @ObservedObject var store: DailyPlanStore

    @State private var displayedMonth = Date()
    @State private var selectedDate: Date?

    private let calendar = Calendar.autoupdatingCurrent
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 7)

    private var monthStart: Date {
        calendar.dateInterval(of: .month, for: displayedMonth)?.start ?? displayedMonth
    }

    private var dayRange: Range<Int> {
        calendar.range(of: .day, in: .month, for: monthStart) ?? 1 ..< 29
    }

    private var leadingDays: Int {
        let weekday = calendar.component(.weekday, from: monthStart)
        return (weekday - calendar.firstWeekday + 7) % 7
    }

    private var selectedDay: Date {
        selectedDate ?? calendar.startOfDay(for: store.now)
    }

    private var weekdayTitles: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return (0 ..< symbols.count).map { offset in
            symbols[(calendar.firstWeekday - 1 + offset) % symbols.count]
        }
    }

    private var canAdvanceMonth: Bool {
        !calendar.isDate(displayedMonth, equalTo: store.now, toGranularity: .month)
    }

    var body: some View {
        VStack(spacing: 0) {
            monthHeader

            ScrollView {
                VStack(spacing: 12) {
                    calendarGrid
                    intensityLegend
                    selectedDaySummary
                }
                .padding(10)
            }
        }
    }

    private var monthHeader: some View {
        HStack(spacing: 8) {
            Button {
                moveMonth(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(.white.opacity(0.055)))
            }
            .buttonStyle(.plain)
            .help("Previous month")

            Spacer(minLength: 4)

            VStack(spacing: 2) {
                Text(monthStart.formatted(.dateTime.month(.wide).year()))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
                Text("\(durationText(monthFocusedSeconds)) focused")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.4))
                    .monospacedDigit()
            }

            Spacer(minLength: 4)

            Button {
                moveMonth(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(canAdvanceMonth ? .white.opacity(0.7) : .white.opacity(0.2))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(.white.opacity(0.055)))
            }
            .buttonStyle(.plain)
            .disabled(!canAdvanceMonth)
            .help("Next month")
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
    }

    private var calendarGrid: some View {
        LazyVGrid(columns: columns, spacing: 5) {
            ForEach(Array(weekdayTitles.enumerated()), id: \.offset) { _, title in
                Text(title)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.38))
                    .frame(maxWidth: .infinity)
                    .frame(height: 17)
            }

            ForEach(0 ..< leadingDays, id: \.self) { _ in
                Color.clear
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
            }

            ForEach(dayRange, id: \.self) { day in
                dayCell(day)
            }
        }
    }

    private var intensityLegend: some View {
        HStack(spacing: 5) {
            Text("Less")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.38))

            ForEach(0 ..< 5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(heatColor(for: TimeInterval(level) * 60 * 60))
                    .frame(width: 12, height: 12)
            }

            Text("More")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.38))

            Spacer()
        }
        .padding(.horizontal, 2)
    }

    private var selectedDaySummary: some View {
        let seconds = store.focusedSeconds(on: selectedDay)

        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(heatColor(for: seconds))
                .frame(width: 4, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(selectedDay.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
                Text(seconds > 0 ? "Focused across your daily plans" : "No focus time recorded")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.38))
            }

            Spacer(minLength: 4)

            Text(durationText(seconds))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.78))
                .monospacedDigit()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(0.04))
        )
    }

    private var monthFocusedSeconds: TimeInterval {
        dayRange.reduce(0) { total, day in
            guard let date = date(forDay: day) else { return total }
            return total + store.focusedSeconds(on: date)
        }
    }

    private func dayCell(_ day: Int) -> some View {
        let date = date(forDay: day) ?? monthStart
        let seconds = store.focusedSeconds(on: date)
        let isFuture = calendar.startOfDay(for: date) > calendar.startOfDay(for: store.now)
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDay)
        let isToday = calendar.isDateInToday(date)

        return Button {
            selectedDate = date
        } label: {
            Text("\(day)")
                .font(.system(size: 10, weight: isSelected || isToday ? .semibold : .regular))
                .foregroundStyle(isFuture ? .white.opacity(0.22) : .white.opacity(seconds > 0 ? 0.92 : 0.55))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isFuture ? Color.white.opacity(0.025) : heatColor(for: seconds))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(
                            isSelected ? Color.white.opacity(0.72) : (isToday ? Color.orange.opacity(0.72) : .clear),
                            lineWidth: isSelected ? 1.2 : 1
                        )
                }
                .aspectRatio(1, contentMode: .fit)
        }
        .buttonStyle(.plain)
        .disabled(isFuture)
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
        .accessibilityValue(seconds > 0 ? "\(durationText(seconds)) focused" : "No focus time")
        .help("\(date.formatted(date: .complete, time: .omitted)) · \(durationText(seconds)) focused")
    }

    private func date(forDay day: Int) -> Date? {
        calendar.date(byAdding: .day, value: day - 1, to: monthStart)
    }

    private func moveMonth(by offset: Int) {
        guard let newMonth = calendar.date(byAdding: .month, value: offset, to: monthStart) else { return }
        displayedMonth = newMonth
        selectedDate = offset > 0 && calendar.isDate(newMonth, equalTo: store.now, toGranularity: .month)
            ? calendar.startOfDay(for: store.now)
            : calendar.startOfDay(for: newMonth)
    }

    private func heatColor(for seconds: TimeInterval) -> Color {
        guard seconds > 0 else { return .white.opacity(0.045) }
        let intensity = min(seconds / (4 * 60 * 60), 1)
        return .orange.opacity(0.16 + intensity * 0.72)
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(Int(seconds) / 60, 0)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0, minutes > 0 { return "\(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h" }
        return "\(minutes)m"
    }
}
