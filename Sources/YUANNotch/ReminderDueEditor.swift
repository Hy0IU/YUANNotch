import SwiftUI

struct ReminderDueEditor: View {
    @ObservedObject var store: ReminderStore
    @Environment(\.appTypography) private var typography

    var body: some View {
        if let draft = store.editingDueDraft {
            VStack(spacing: 0) {
                HStack {
                    Text("Edit Due Date")
                        .appText(.sectionTitle)
                        .foregroundStyle(.white.opacity(0.9))
                    Spacer()
                    Button { store.cancelEditingDue() } label: {
                        Text("Cancel").appText(.control)
                    }
                        .buttonStyle(MarkdownToolbarButtonStyle())
                }
                .padding(.horizontal, 12)
                .frame(height: 40)

                Divider().overlay(.white.opacity(0.08))

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(draft.title)
                            .appText(.body, weight: .medium)
                            .foregroundStyle(.white.opacity(0.75))
                            .fixedSize(horizontal: false, vertical: true)

                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Due date")
                                    .appText(.control)
                                Spacer()
                                Toggle("Due date", isOn: binding(\.hasDate, fallback: false))
                                    .labelsHidden()
                            }

                            if draft.hasDate {
                                HStack {
                                    Text("Date")
                                        .appText(.secondary)
                                        .foregroundStyle(.white.opacity(0.5))
                                    Spacer(minLength: 8)
                                    DatePicker("Due date", selection: binding(\.date, fallback: Date()), displayedComponents: [.date])
                                        .labelsHidden()
                                        .datePickerStyle(.compact)
                                        .fixedSize()
                                }
                                HStack(spacing: 6) {
                                    dateShortcut("Today", offset: 0)
                                    dateShortcut("Tomorrow", offset: 1)
                                }
                            }
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.035)))

                        if draft.hasDate {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text("Include time")
                                        .appText(.control)
                                    Spacer()
                                    Toggle("Include time", isOn: binding(\.hasTime, fallback: false))
                                        .labelsHidden()
                                }
                                if draft.hasTime {
                                    HStack {
                                        Text("Time")
                                            .appText(.secondary)
                                            .foregroundStyle(.white.opacity(0.5))
                                        Spacer(minLength: 8)
                                        DatePicker("Due time", selection: binding(\.time, fallback: Date()), displayedComponents: [.hourAndMinute])
                                            .labelsHidden()
                                            .datePickerStyle(.compact)
                                            .fixedSize()
                                    }
                                }
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.035)))
                        }

                        Text(draft.hasDate
                             ? "Dates without a time are all-day reminders."
                             : "Saving removes the due date and its alerts.")
                            .appText(.secondary)
                            .foregroundStyle(.white.opacity(0.38))
                            .fixedSize(horizontal: false, vertical: true)

                        if let error = store.dueEditingError {
                            Text(error)
                                .appText(.secondary)
                                .foregroundStyle(.orange.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }

                Divider().overlay(.white.opacity(0.08))
                HStack {
                    if store.isSavingDue {
                        ProgressView().controlSize(.small)
                        Text("Saving…")
                            .appText(.secondary)
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    Spacer()
                    Button {
                        Task { await store.commitEditingDue() }
                    } label: {
                        Text("Save")
                            .appText(.control)
                            .foregroundStyle(.black.opacity(0.76))
                            .padding(.horizontal, 14)
                            .frame(minHeight: typography.controlHeight(base: 29))
                            .background(RoundedRectangle(cornerRadius: 7).fill(.orange.opacity(0.92)))
                    }
                    .buttonStyle(.plain)
                    .disabled(!draft.hasChanges())
                    .opacity(draft.hasChanges() ? 1 : 0.35)
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
            }
            .toggleStyle(.switch)
            .controlSize(typography.interfaceSize == .large ? .regular : .small)
            .background(Color(red: 0.06, green: 0.06, blue: 0.07))
            .environment(\.colorScheme, .dark)
            .disabled(store.isSavingDue)
            .onExitCommand { store.cancelEditingDue() }
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<ReminderDueDraft, Value>, fallback: Value) -> Binding<Value> {
        Binding(
            get: { store.editingDueDraft?[keyPath: keyPath] ?? fallback },
            set: { store.editingDueDraft?[keyPath: keyPath] = $0 }
        )
    }

    private func dateShortcut(_ title: String, offset: Int) -> some View {
        Button {
            let calendar = Calendar.current
            store.editingDueDraft?.date = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: Date())) ?? Date()
        } label: {
            Text(title)
                .appText(.control)
                .foregroundStyle(.orange.opacity(0.85))
                .padding(.horizontal, 10)
                .frame(minHeight: typography.controlHeight(base: 25))
                .background(Capsule().fill(.orange.opacity(0.10)))
        }
        .buttonStyle(.plain)
    }
}
