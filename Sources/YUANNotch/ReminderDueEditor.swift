import SwiftUI

struct ReminderDueEditor: View {
    @ObservedObject var store: ReminderStore

    var body: some View {
        if let draft = store.editingDueDraft {
            VStack(spacing: 0) {
                HStack {
                    Text("Edit Due Date")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    Spacer()
                    Button("Cancel") { store.cancelEditingDue() }
                        .buttonStyle(MarkdownToolbarButtonStyle())
                }
                .padding(.horizontal, 12)
                .frame(height: 40)

                Divider().overlay(.white.opacity(0.08))

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(draft.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                            .fixedSize(horizontal: false, vertical: true)

                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Due date")
                                    .font(.system(size: 12, weight: .medium))
                                Spacer()
                                Toggle("Due date", isOn: binding(\.hasDate, fallback: false))
                                    .labelsHidden()
                            }

                            if draft.hasDate {
                                HStack {
                                    Text("Date")
                                        .font(.system(size: 11))
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
                                        .font(.system(size: 12, weight: .medium))
                                    Spacer()
                                    Toggle("Include time", isOn: binding(\.hasTime, fallback: false))
                                        .labelsHidden()
                                }
                                if draft.hasTime {
                                    HStack {
                                        Text("Time")
                                            .font(.system(size: 11))
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
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.38))
                            .fixedSize(horizontal: false, vertical: true)

                        if let error = store.dueEditingError {
                            Text(error)
                                .font(.system(size: 10))
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
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    Spacer()
                    Button {
                        Task { await store.commitEditingDue() }
                    } label: {
                        Text("Save")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.black.opacity(0.76))
                            .padding(.horizontal, 14)
                            .frame(height: 29)
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
            .controlSize(.small)
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
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.orange.opacity(0.85))
                .padding(.horizontal, 10)
                .frame(height: 25)
                .background(Capsule().fill(.orange.opacity(0.10)))
        }
        .buttonStyle(.plain)
    }
}
