import SwiftUI

struct DailyPlanTimeEditor: View {
    @ObservedObject var store: DailyPlanStore
    @FocusState private var focusedField: DurationField?

    private struct DurationField: Hashable {
        let planID: UUID
        let isHours: Bool
    }

    private let background = Color(red: 0.06, green: 0.06, blue: 0.07)

    var body: some View {
        if let draft = store.timeDraft {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Edit Focus Time")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                        Text(draft.date.formatted(.dateTime.year().month(.abbreviated).day().weekday(.abbreviated)))
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.42))
                    }
                    Spacer(minLength: 8)
                    Button("Cancel") { store.cancelEditingTime() }
                        .buttonStyle(MarkdownToolbarButtonStyle())
                }
                .padding(.horizontal, 12)
                .frame(height: 52)

                Divider().overlay(.white.opacity(0.08))

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline) {
                            Label("Daily total", systemImage: "clock")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.55))
                            Spacer()
                            Text(durationText(draft.totalSeconds))
                                .font(.system(size: 21, weight: .medium, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.orange.opacity(0.95))
                        }
                        .padding(.bottom, 2)

                        ForEach(Array(draft.entries.enumerated()), id: \.element.id) { index, entry in
                            entryRow(entry, index: index)
                        }

                        Text("Adjust time by plan, or log extra time under Other focus. Pomodoro rounds stay unchanged; continuous timers follow the remaining daily target.")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.38))
                            .fixedSize(horizontal: false, vertical: true)

                        if draft.totalSeconds > 24 * 60 * 60 {
                            Text("Daily focus time cannot exceed 24 hours.")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                        }

                        if let error = store.lastError {
                            Text(error)
                                .font(.system(size: 10))
                                .foregroundStyle(.orange.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(12)
                }

                Divider().overlay(.white.opacity(0.08))
                HStack {
                    Text("Hours · Minutes")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.35))
                    Spacer()
                    Button("Save") { store.commitTimeDraft() }
                        .buttonStyle(FocusActionButtonStyle(isPrimary: true, color: .orange))
                        .disabled(!draft.canCommit)
                        .opacity(draft.canCommit ? 1 : 0.35)
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
            }
            .background(background)
            .onExitCommand { store.cancelEditingTime() }
        }
    }

    private func entryRow(_ entry: DailyPlanTimeEntry, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(entry.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
                    .help(entry.title)
                Spacer(minLength: 0)
                if entry.isChanged {
                    Text("Edited")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.orange.opacity(0.8))
                }
            }
            HStack(spacing: 10) {
                durationField("Hours", entry: entry, index: index, isHours: true)
                durationField("Minutes", entry: entry, index: index, isHours: false)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.035)))
    }

    private func durationField(
        _ label: String,
        entry: DailyPlanTimeEntry,
        index: Int,
        isHours: Bool
    ) -> some View {
        HStack(spacing: 6) {
            TextField("0", text: Binding(
                get: {
                    guard let minutes = store.timeDraft?.entries[index].minutes else { return "0" }
                    return String(isHours ? minutes / 60 : minutes % 60)
                },
                set: { text in
                    guard let minutes = store.timeDraft?.entries[index].minutes else { return }
                    let digits = text.filter { $0.isASCII && $0.isNumber }
                    let value = digits.isEmpty ? 0 : (Int(digits) ?? Int.max)
                    let updated = isHours
                        ? min(value, 24) * 60 + minutes % 60
                        : minutes / 60 * 60 + min(value, 59)
                    store.timeDraft?.entries[index].minutes = min(updated, 24 * 60)
                }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
            .foregroundStyle(.white.opacity(0.9))
            .frame(minWidth: 24, maxWidth: .infinity)
            .accessibilityLabel("\(entry.title) \(label.lowercased())")
            .focused($focusedField, equals: DurationField(planID: entry.id, isHours: isHours))
            .onSubmit { store.commitTimeDraft() }

            Text(isHours ? "h" : "min")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.055)))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(.orange.opacity(
                    focusedField == DurationField(planID: entry.id, isHours: isHours) ? 0.55 : 0
                ), lineWidth: 1)
        }
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let minutes = max(Int(seconds / 60), 0)
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}
