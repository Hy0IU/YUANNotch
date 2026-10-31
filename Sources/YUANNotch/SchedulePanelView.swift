import AppKit
import SwiftUI

@MainActor
struct SchedulePanelView: View {
    @ObservedObject var store: ScheduleStore
    @Environment(\.appTypography) private var typography
    let size: CGSize
    let isDrawerExpanded: Bool
    let onOpenSettings: () -> Void

    @State private var focusedDay: Date?
    @State private var windowCenter: Date
    @State private var isMounted = false
    @State private var showsSources = false
    @State private var firstDayOffset = -30
    @State private var lastDayOffset = 30
    @State private var hasPositioned = false

    private static let background = Color(red: 0.06, green: 0.06, blue: 0.07)

    init(
        store: ScheduleStore,
        size: CGSize,
        isDrawerExpanded: Bool,
        onOpenSettings: @escaping () -> Void
    ) {
        self.store = store
        self.size = size
        self.isDrawerExpanded = isDrawerExpanded
        self.onOpenSettings = onOpenSettings
        let today = store.calendar.startOfDay(for: Date())
        _focusedDay = State(initialValue: today)
        _windowCenter = State(initialValue: today)
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                header(proxy: proxy)
                divider
                statusMessages
                dayStrip
            }
            .onAppear {
                isMounted = true
                store.setVisible(isDrawerExpanded)
                DispatchQueue.main.async {
                    proxy.scrollTo(focusedDay ?? today, anchor: .center)
                    DispatchQueue.main.async { hasPositioned = true }
                }
            }
            .onChange(of: focusedDay) { _, day in
                guard let day else { return }
                let offset = store.calendar.dateComponents([.day], from: windowCenter, to: day).day ?? 0
                if offset >= lastDayOffset - 8 { lastDayOffset += 30 }
                if offset <= firstDayOffset + 8 {
                    // Prepending changes document coordinates; preserve the
                    // visible date before accepting its new measured position.
                    hasPositioned = false
                    firstDayOffset -= 30
                    DispatchQueue.main.async {
                        proxy.scrollTo(day, anchor: .center)
                        DispatchQueue.main.async { hasPositioned = true }
                    }
                }
            }
        }
        .frame(width: max(0, size.width), height: max(0, size.height), alignment: .top)
        .background(Self.background)
        .onChange(of: isDrawerExpanded) { _, expanded in
            store.setVisible(isMounted && expanded)
        }
        .onDisappear {
            isMounted = false
            store.setVisible(false)
        }
        .task(id: requestedRange) {
            guard let range = requestedRange else { return }
            await store.refresh(in: range)
        }
    }

    private var today: Date { store.calendar.startOfDay(for: Date()) }
    private var focus: Date { focusedDay ?? today }
    private var columnWidth: CGFloat { max(180, min(266, size.width - 52)) }
    private var days: [Date] {
        (firstDayOffset...lastDayOffset).compactMap {
            store.calendar.date(byAdding: .day, value: $0, to: windowCenter)
        }
    }
    private var requestedRange: DateInterval? {
        guard isMounted, isDrawerExpanded,
              let start = store.calendar.date(byAdding: .day, value: firstDayOffset, to: windowCenter),
              let end = store.calendar.date(byAdding: .day, value: lastDayOffset + 1, to: windowCenter)
        else { return nil }
        return DateInterval(start: start, end: end)
    }
    private var divider: some View { Divider().overlay(.white.opacity(0.07)) }

    private func header(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 3) {
            Text(focus.formatted(.dateTime.month(.wide).year().scheduleCalendar(store.calendar)))
                .appText(.sectionTitle)
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(focus.formatted(.dateTime.month(.wide).year().scheduleCalendar(store.calendar)))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)

            Button {
                navigate(to: today, proxy: proxy)
            } label: {
                Text("Today")
                    .appText(.control)
                    .padding(.horizontal, 6)
                    .frame(height: typography.controlHeight())
            }
            .buttonStyle(MarkdownToolbarButtonStyle())
            .help("Center today")

            navigationButton("chevron.left", label: "Previous day") {
                if let day = store.calendar.date(byAdding: .day, value: -1, to: focus) {
                    navigate(to: day, proxy: proxy)
                }
            }
            navigationButton("chevron.right", label: "Next day") {
                if let day = store.calendar.date(byAdding: .day, value: 1, to: focus) {
                    navigate(to: day, proxy: proxy)
                }
            }
            navigationButton("line.3.horizontal.decrease", label: "Schedule sources") {
                showsSources.toggle()
            }
            .popover(isPresented: $showsSources, arrowEdge: .bottom) {
                sourcesPopover
            }
            Button { store.requestRefresh() } label: {
                if store.isLoading {
                    ProgressView().controlSize(.mini)
                        .frame(width: 24, height: typography.controlHeight())
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 24, height: typography.controlHeight())
                }
            }
            .buttonStyle(MarkdownToolbarButtonStyle())
            .disabled(store.isLoading)
            .help("Refresh Calendar and Reminders")
            .accessibilityLabel("Refresh schedule")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private func navigationButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 24, height: typography.controlHeight())
        }
        .buttonStyle(MarkdownToolbarButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }

    private func navigate(to day: Date, proxy: ScrollViewProxy) {
        let normalized = store.calendar.startOfDay(for: day)
        let offset = store.calendar.dateComponents([.day], from: windowCenter, to: normalized).day ?? 0
        firstDayOffset = min(firstDayOffset, offset - 8)
        lastDayOffset = max(lastDayOffset, offset + 8)
        withAnimation(.easeInOut(duration: 0.2)) {
            focusedDay = normalized
            proxy.scrollTo(normalized, anchor: .center)
        }
    }

    private var sourcesPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Schedule sources").appText(.sectionTitle)
                Spacer()
                Button("Settings") {
                    showsSources = false
                    onOpenSettings()
                }
                .appText(.control)
                .buttonStyle(.plain)
                .foregroundStyle(.orange.opacity(0.9))
            }
            Text("Read-only · selections apply only to Schedule")
                .appText(.secondary)
                .foregroundStyle(.white.opacity(0.45))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(ScheduleSourceKind.allCases, id: \.self) { kind in
                        ScheduleSourceGroup(store: store, kind: kind)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 340)
        }
        .padding(14)
        .frame(width: 300)
        .foregroundStyle(.white.opacity(0.85))
        .background(Self.background)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var statusMessages: some View {
        let unavailable = ScheduleSourceKind.allCases.filter { !authorization(for: $0).canRead }
        if !unavailable.isEmpty || !store.errors.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(unavailable, id: \.self) { kind in
                    HStack(spacing: 7) {
                        Image(systemName: kind.scheduleIcon)
                            .font(.system(size: 11))
                            .foregroundStyle(.orange.opacity(0.8))
                        Text("\(kind.scheduleTitle): \(authorization(for: kind).scheduleStatus)")
                            .appText(.secondary)
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                            .help(authorization(for: kind).scheduleExplanation(kind: kind))
                        Spacer(minLength: 0)
                        ScheduleAccessButton(store: store, kind: kind)
                    }
                }
                ForEach(Array(store.errors.enumerated()), id: \.offset) { _, message in
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 10))
                        Text(message)
                            .appText(.secondary)
                            .lineLimit(2)
                            .help(message)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .foregroundStyle(.orange.opacity(0.85))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.white.opacity(0.025))
            divider
        }
    }

    private var dayStrip: some View {
        GeometryReader { viewport in
            dayStrip(height: max(0, viewport.size.height - 20))
        }
    }

    private func dayStrip(height: CGFloat) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 10) {
                ForEach(days, id: \.self) { date in
                    ScheduleDayColumn(
                        day: ScheduleDay.make(date: date, entries: store.entries, calendar: store.calendar),
                        sources: store.sources,
                        calendar: store.calendar,
                        calendarAvailability: availability(for: .calendar),
                        reminderAvailability: availability(for: .reminders),
                        hasErrors: !store.errors.isEmpty,
                        isLoading: store.isLoading
                    )
                    .frame(width: columnWidth, height: height)
                    .id(date)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: ScheduleDayPositionPreference.self,
                                value: [date: geometry.frame(in: .named("scheduleViewport")).midX]
                            )
                        }
                    }
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, max(12, (size.width - columnWidth) / 2))
            .padding(.vertical, 10)
        }
        .coordinateSpace(name: "scheduleViewport")
        .onPreferenceChange(ScheduleDayPositionPreference.self) { positions in
            guard let nearest = positions.min(by: {
                abs($0.value - size.width / 2) < abs($1.value - size.width / 2)
            })?.key else { return }
            Task { @MainActor in
                guard hasPositioned, focusedDay != nearest else { return }
                focusedDay = nearest
            }
        }
        .scrollIndicators(.hidden)
        .mask {
            GeometryReader { geometry in
                let edge = min(10 / max(geometry.size.width, 1), 0.1)
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: edge),
                    .init(color: .black, location: 1 - edge),
                    .init(color: .clear, location: 1)
                ], startPoint: .leading, endPoint: .trailing)
            }
        }
    }

    private func authorization(for kind: ScheduleSourceKind) -> ScheduleAuthorization {
        kind == .calendar ? store.calendarAuthorization : store.reminderAuthorization
    }

    private func availability(for kind: ScheduleSourceKind) -> ScheduleDayAvailability {
        guard authorization(for: kind).canRead else { return .unavailable }
        let sources = store.sources.filter { $0.kind == kind }
        guard !sources.isEmpty else { return store.isLoading ? .loading : .noSources }
        return sources.contains(where: { store.isSelected($0) }) ? .readable : .unselected
    }
}

private enum ScheduleDayPositionPreference: PreferenceKey {
    static let defaultValue: [Date: CGFloat] = [:]

    static func reduce(value: inout [Date: CGFloat], nextValue: () -> [Date: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private enum ScheduleDayAvailability {
    case readable, loading, unavailable, noSources, unselected

    var emptyMessage: String? {
        switch self {
        case .readable: return nil
        case .loading: return "Loading…"
        case .unavailable: return "Access unavailable"
        case .noSources: return "No sources available"
        case .unselected: return "No sources selected"
        }
    }
}

@MainActor
private struct ScheduleDayColumn: View {
    @Environment(\.appTypography) private var typography
    let day: ScheduleDay
    let sources: [ScheduleSource]
    let calendar: Calendar
    let calendarAvailability: ScheduleDayAvailability
    let reminderAvailability: ScheduleDayAvailability
    let hasErrors: Bool
    let isLoading: Bool

    private var isToday: Bool { calendar.isDateInToday(day.date) }

    var body: some View {
        VStack(spacing: 0) {
            dateHeader
            Divider().overlay(.white.opacity(0.06))
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    entrySection(.reminders, entries: day.reminders, availability: reminderAvailability)
                    entrySection(.calendar, entries: day.events, availability: calendarAvailability)
                }
                .padding(10)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .scrollIndicators(.hidden)
        }
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(isToday ? 0.045 : 0.025))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isToday ? Color.orange.opacity(0.22) : .white.opacity(0.055), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(day.date.formatted(.dateTime.weekday(.wide).month(.wide).day().scheduleCalendar(calendar)))
    }

    private var dateHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(day.date.formatted(.dateTime.day().scheduleCalendar(calendar)))
                .appText(.windowTitle, weight: .semibold)
                .monospacedDigit()
                .foregroundStyle(isToday ? Color.orange : .white.opacity(0.88))
            VStack(alignment: .leading, spacing: 2) {
                Text(day.date.formatted(.dateTime.weekday(.wide).scheduleCalendar(calendar)))
                    .appText(.control, weight: .semibold)
                    .foregroundStyle(.white.opacity(0.82))
                Text(day.date.formatted(.dateTime.month(.abbreviated).year().scheduleCalendar(calendar)))
                    .appText(.compact)
                    .foregroundStyle(.white.opacity(0.38))
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            if isToday {
                Text("Today")
                    .appText(.compact)
                    .foregroundStyle(.orange.opacity(0.95))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.orange.opacity(0.12), in: Capsule())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityAddTraits(.isHeader)
    }

    private func entrySection(
        _ kind: ScheduleSourceKind,
        entries: [ScheduleEntry],
        availability: ScheduleDayAvailability
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: kind.scheduleIcon).font(.system(size: 10))
                Text(kind.scheduleTitle).appText(.compact)
                Spacer(minLength: 0)
                if !entries.isEmpty {
                    Text("\(entries.count)").appText(.compact).monospacedDigit()
                }
            }
            .foregroundStyle(.white.opacity(0.38))
            .padding(.top, 3)
            .accessibilityAddTraits(.isHeader)

            if entries.isEmpty {
                Text(availability.emptyMessage ?? (isLoading ? "Loading…" : hasErrors ? "Could not confirm items" : kind == .reminders ? "No dated reminders" : "No events"))
                    .appText(.secondary)
                    .foregroundStyle(.white.opacity(0.3))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 8)
            } else {
                ForEach(entries) { entry in
                    ScheduleEntryBar(
                        entry: entry,
                        source: sources.first { $0.id == entry.sourceID && $0.kind == entry.kind },
                        day: day.date,
                        calendar: calendar
                    )
                }
            }
        }
        .padding(.bottom, 7)
    }
}

private struct ScheduleEntryBar: View {
    let entry: ScheduleEntry
    let source: ScheduleSource?
    let day: Date
    let calendar: Calendar

    private var tint: Color { source?.color.scheduleColor ?? .gray }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(tint.opacity(0.9)).frame(width: 3)
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.title.isEmpty ? "Untitled" : entry.title)
                    .appText(.body, weight: .medium)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(timeLabel)
                    .appText(.compact)
                    .foregroundStyle(entry.kind == .reminders ? .white.opacity(0.58) : tint.opacity(0.95))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let location = entry.location, !location.isEmpty, entry.kind == .calendar {
                    Text(location)
                        .appText(.compact)
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }
                HStack(spacing: 4) {
                    Circle().fill(tint).frame(width: 4, height: 4)
                    Text(source?.title ?? (entry.kind == .calendar ? "Calendar" : "Reminders"))
                        .appText(.compact)
                        .foregroundStyle(.white.opacity(0.42))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(tint.opacity(0.085))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(tint.opacity(0.12), lineWidth: 1)
        }
        .help(fullDescription)
        .accessibilityElement(children: .combine)
    }

    private func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().scheduleCalendar(calendar))
    }

    private func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().scheduleCalendar(calendar))
    }

    private var timeLabel: String {
        if entry.kind == .reminders {
            return entry.isAllDay ? "No time specified" : "Due \(time(entry.start))"
        }
        guard let end = entry.end, end > entry.start else {
            return entry.isAllDay ? "All day" : time(entry.start)
        }
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return "" }
        // EventKit all-day ends are exclusive; midnight belongs to the prior day.
        let lastDay = calendar.startOfDay(for: end.addingTimeInterval(-1))
        let firstDay = calendar.startOfDay(for: entry.start)
        if entry.isAllDay {
            if firstDay == lastDay { return "All day" }
            let count = (calendar.dateComponents([.day], from: firstDay, to: lastDay).day ?? 0) + 1
            let index = (calendar.dateComponents([.day], from: firstDay, to: day).day ?? 0) + 1
            return "All day · \(index) of \(count) days"
        }
        let startsEarlier = entry.start < interval.start
        let endsLater = end > interval.end
        if startsEarlier || end >= interval.end {
            let startLabel = startsEarlier ? "← \(shortDate(entry.start)), \(time(entry.start))" : time(entry.start)
            let endLabel = end >= interval.end
                ? "\(shortDate(end)), \(time(end))\(endsLater ? " →" : "")"
                : time(end)
            return "\(startLabel) – \(endLabel)"
        }
        return "\(time(entry.start)) – \(time(end))"
    }

    private var fullDescription: String {
        var lines = [entry.title.isEmpty ? "Untitled" : entry.title, timeLabel]
        if entry.kind == .calendar {
            let start = entry.start.formatted(.dateTime.month(.wide).day().hour().minute().scheduleCalendar(calendar))
            if entry.isAllDay, let end = entry.end {
                let last = end.addingTimeInterval(-1)
                lines.append("\(shortDate(entry.start)) – \(shortDate(last)) (all day)")
            } else if let end = entry.end {
                lines.append("\(start) – \(end.formatted(.dateTime.month(.wide).day().hour().minute().scheduleCalendar(calendar)))")
            } else {
                lines.append(start)
            }
        }
        if let location = entry.location, !location.isEmpty { lines.append(location) }
        if let source {
            lines.append(source.account.isEmpty ? source.title : "\(source.title) · \(source.account)")
        }
        return lines.joined(separator: "\n")
    }
}

@MainActor
struct ScheduleSourcesSettingsView: View {
    @ObservedObject var store: ScheduleStore

    var body: some View {
        Group {
            ForEach(ScheduleSourceKind.allCases, id: \.self) { kind in
                Section {
                    ScheduleSourceGroup(store: store, kind: kind, showsHeading: false)
                } header: {
                    Text("Schedule · \(kind.scheduleTitle)").appText(.sectionTitle)
                } footer: {
                    Text(kind == .calendar
                         ? "Read-only Apple Calendar events. Your calendars and events are never changed."
                         : "Only incomplete reminders with a due date appear. These selections do not change the Reminders tab's list.")
                        .appText(.secondary)
                }
            }
            if !store.errors.isEmpty {
                Section {
                    ForEach(Array(store.errors.enumerated()), id: \.offset) { _, message in
                        Text(message).appText(.secondary).foregroundStyle(.orange)
                    }
                    Button("Refresh Schedule") { store.requestRefresh() }
                        .appText(.control)
                } header: {
                    Text("Schedule status").appText(.sectionTitle)
                }
            }
        }
        // Discovery is allowed here, but permission is requested only by a button.
        .task { store.requestRefresh() }
    }
}

@MainActor
private struct ScheduleSourceGroup: View {
    @ObservedObject var store: ScheduleStore
    let kind: ScheduleSourceKind
    var showsHeading = true

    private var authorization: ScheduleAuthorization {
        kind == .calendar ? store.calendarAuthorization : store.reminderAuthorization
    }
    private var sources: [ScheduleSource] { store.sources.filter { $0.kind == kind } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if showsHeading {
                    Label(kind.scheduleTitle, systemImage: kind.scheduleIcon)
                        .appText(.control, weight: .semibold)
                } else {
                    Text(authorization.scheduleStatus).appText(.secondary).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if !authorization.canRead {
                    ScheduleAccessButton(store: store, kind: kind)
                } else if showsHeading {
                    Text("\(sources.filter { store.isSelected($0) }.count)/\(sources.count)")
                        .appText(.compact)
                        .foregroundStyle(.secondary)
                }
            }
            if authorization.canRead {
                if sources.isEmpty {
                    Text(store.isLoading ? "Discovering sources…" : "No readable sources found.")
                        .appText(.secondary)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sources, id: \.key) { source in
                        Toggle(isOn: Binding(
                            get: { store.isSelected(source) },
                            set: { store.setSelected(source, isSelected: $0) }
                        )) {
                            HStack(alignment: .top, spacing: 7) {
                                Circle().fill(source.color.scheduleColor)
                                    .frame(width: 7, height: 7)
                                    .padding(.top, 4)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(source.title).appText(.control)
                                    if !source.account.isEmpty {
                                        Text(source.account).appText(.compact).foregroundStyle(.secondary)
                                    }
                                }
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .help(source.account.isEmpty ? source.title : "\(source.title) · \(source.account)")
                    }
                }
            } else {
                Text(authorization.scheduleExplanation(kind: kind))
                    .appText(.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
private struct ScheduleAccessButton: View {
    @ObservedObject var store: ScheduleStore
    let kind: ScheduleSourceKind

    private var authorization: ScheduleAuthorization {
        kind == .calendar ? store.calendarAuthorization : store.reminderAuthorization
    }

    var body: some View {
        Button(store.requestingAccess == kind ? "Connecting…" : authorization == .notDetermined || authorization == .writeOnly ? "Allow access" : "Settings") {
            if authorization == .notDetermined || authorization == .writeOnly {
                Task { @MainActor in
                    let previousPolicy = NSApp.activationPolicy()
                    if previousPolicy == .accessory { NSApp.setActivationPolicy(.regular) }
                    if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
                    defer {
                        if previousPolicy == .accessory { NSApp.setActivationPolicy(.accessory) }
                    }
                    await store.requestAccess(for: kind)
                }
            } else {
                store.openPrivacySettings(for: kind)
            }
        }
        .appText(.secondary, weight: .medium)
        .buttonStyle(.plain)
        .disabled(store.requestingAccess != nil)
        .foregroundStyle(.orange.opacity(0.9))
        .help(authorization == .notDetermined || authorization == .writeOnly
              ? "Allow read access to Apple \(kind.scheduleTitle)"
              : "Open \(kind.scheduleTitle) privacy settings")
    }
}

private extension ScheduleColor {
    var scheduleColor: Color { Color(red: red, green: green, blue: blue) }
}

private extension ScheduleSourceKind {
    var scheduleTitle: String { self == .calendar ? "Calendar" : "Reminders" }
    var scheduleIcon: String { self == .calendar ? "calendar" : "checklist" }
}

private extension ScheduleAuthorization {
    var scheduleStatus: String {
        switch self {
        case .notDetermined: return "Not connected"
        case .denied: return "Access denied"
        case .restricted: return "Access restricted"
        case .writeOnly: return "Read access needed"
        case .fullAccess: return "Connected"
        }
    }

    func scheduleExplanation(kind: ScheduleSourceKind) -> String {
        switch self {
        case .notDetermined:
            return "Connect Apple \(kind.scheduleTitle) to read dated items. Access is requested only when you choose Allow access."
        case .denied:
            return "Allow full \(kind.scheduleTitle) access in System Settings to show these items. Other connected sources remain available."
        case .restricted:
            return "\(kind.scheduleTitle) access is restricted on this Mac. Other connected sources remain available."
        case .writeOnly:
            return "Schedule needs full read access to Calendar; permission to add events alone cannot show existing events."
        case .fullAccess:
            return "Connected to Apple \(kind.scheduleTitle)."
        }
    }
}

private extension Date.FormatStyle {
    func scheduleCalendar(_ calendar: Calendar) -> Self {
        var style = self
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return style
    }
}
