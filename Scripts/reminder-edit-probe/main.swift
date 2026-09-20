import AppKit
import EventKit
import Foundation
import SwiftUI

// YUANNotch · reminder editing probe
//
// The feature under test: a reminder that has been added can be edited in place.
// The store carries the edit — which row, and what the draft says — because the
// drawer throws the reminders surface away on every mode switch, and because the
// store has to protect the row across its own rebuilds.
//
// Checks:
//   1. the two pure rules the commit rests on: `rewrite` (unchanged or emptied
//      draft means nothing to write) and `applyingTitle` (one row's title, every
//      other field of every other row untouched).
//   2. the flow against the real ReminderStore with a stand-in service: begin →
//      draft → commit reaches the service as `update(id:title:due:)` with the
//      title only, the row shows the new title at once, and the edit is closed.
//   3. a draft that restates the title, or is blank, writes nothing.
//   4. a failed write reverts the optimistic title by re-reading.
//   5. a refresh that no longer knows the row ends the edit.
//   6. a pending local row (a create that has not landed) offers no edit.
//
// Hermetic: the service is a stand-in, the write queue lives in a scratch file,
// and the two UserDefaults keys the store touches are saved and restored. Nothing
// reaches EventKit or the user's real data.

private let defaultsKeysToRestore = [
    "yuanNotch.appleReminders.enabled",
    "yuanNotch.appleReminders.listID",
    "yuanNotch.appleReminders.listViews",
]

// MARK: - Stand-in service

private actor StubRemindersService: RemindersServing {
    let list = ReminderList(
        id: "list-1",
        title: "Probe List",
        isDefault: true,
        isLocalOnly: false,
        sourceTitle: "iCloud"
    )

    private var reminders: [ReminderSnapshot]
    private(set) var updates: [(id: String, title: String?, due: ReminderDue?)] = []
    private(set) var failNextUpdate = false

    init(reminders: [ReminderSnapshot]) {
        self.reminders = reminders
    }

    func setReminders(_ newReminders: [ReminderSnapshot]) {
        reminders = newReminders
    }

    func setFailNextUpdate(_ value: Bool) {
        failNextUpdate = value
    }

    nonisolated func authorizationStatus() -> RemindersAuthorization { .fullAccess }
    func requestAccess() async throws -> RemindersAuthorization { .fullAccess }

    func availableLists() async -> [ReminderList] { [list] }
    func defaultList() async -> ReminderList? { list }
    func snapshot(in listID: String) async throws -> [ReminderSnapshot] {
        reminders.filter { $0.listID == listID }
    }

    func create(title: String, due: ReminderDue?, in listID: String, marker: UUID) async throws -> ReminderSnapshot {
        let created = ReminderSnapshot(
            id: marker.uuidString,
            externalID: nil,
            title: title,
            dueDate: due?.date,
            isDueDateAllDay: due?.isAllDay ?? false,
            isCompleted: false,
            hasAlarm: false,
            listID: listID,
            createdDate: Date(),
            lastModified: nil
        )
        reminders.append(created)
        return created
    }

    func update(id: String, title: String?, due: ReminderDue?) async throws {
        if failNextUpdate {
            throw NSError(domain: "probe", code: 1, userInfo: [NSLocalizedDescriptionKey: "probe asked the write to fail"])
        }
        updates.append((id: id, title: title, due: due))
        if let index = reminders.firstIndex(where: { $0.id == id }) {
            let old = reminders[index]
            reminders[index] = ReminderSnapshot(
                id: old.id,
                externalID: old.externalID,
                title: title ?? old.title,
                dueDate: due?.date ?? old.dueDate,
                isDueDateAllDay: due?.isAllDay ?? old.isDueDateAllDay,
                isCompleted: old.isCompleted,
                hasAlarm: old.hasAlarm,
                listID: old.listID,
                createdDate: old.createdDate,
                lastModified: old.lastModified
            )
        }
    }

    func setCompleted(id: String, isCompleted: Bool) async throws {}
    func resolve(id: String, externalID: String?, in listID: String) async -> ReminderSnapshot? {
        reminders.first { $0.id == id }
    }
    func delete(id: String) async throws {
        reminders.removeAll { $0.id == id }
    }
    func changes() async -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }
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

@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool, timeout: TimeInterval = 3) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return true
}

// MARK: - Fixture

@MainActor
private func makeStore(service: StubRemindersService, queueURL: URL) -> (ReminderStore, AppSettingsStore) {
    let settings = AppSettingsStore()
    settings.isAppleRemindersSyncEnabled = true
    let store = ReminderStore(
        settingsStore: settings,
        service: service,
        queueStore: ReminderQueueStore(queueURL: queueURL)
    )
    return (store, settings)
}

@MainActor
private func reminder(id: String, title: String) -> ReminderSnapshot {
    ReminderSnapshot(
        id: id,
        externalID: nil,
        title: title,
        dueDate: nil,
        isDueDateAllDay: false,
        isCompleted: false,
        hasAlarm: false,
        listID: "list-1",
        createdDate: nil,
        lastModified: nil
    )
}

// MARK: - 1 · The pure rules

@MainActor
private func checkRules() {
    print("— 1 · what a commit is willing to write —")

    var wrong: [String] = []
    func expect(_ original: String, _ draft: String, _ wanted: String?) {
        let got = ReminderStore.rewrite(original: original, draft: draft)
        if got != wanted { wrong.append("original \"\(original)\", draft \"\(draft)\" -> \(got.map { "\"\($0)\"" } ?? "nil")") }
    }
    expect("买牛奶", "买牛奶两瓶", "买牛奶两瓶")   // an edit
    expect("  买牛奶  ", "  买牛奶  ", nil)        // restating the title trims to a no-op
    expect("买牛奶", "   ", nil)                  // a cleared draft is no reminder
    expect("买牛奶", "", nil)
    expect("  买牛奶", "买牛奶  ", nil)            // trimming alone is not an edit
    check(
        wrong.isEmpty,
        "rewrite",
        wrong.isEmpty
            ? "an edit writes its trimmed text; restating, clearing or only re-trimming writes nothing"
            : wrong.joined(separator: "; ")
    )

    let original = [
        reminder(id: "r1", title: "before"),
        reminder(id: "r2", title: "other"),
    ]
    let applied = ReminderStore.applyingTitle("after", to: "r1", in: original)
    let fieldsKept = applied.count == 2
        && applied[0].id == "r1" && applied[0].title == "after"
        && applied[0].externalID == nil && applied[0].dueDate == nil && applied[0].isDueDateAllDay == false
        && applied[0].isCompleted == false && applied[0].hasAlarm == false
        && applied[0].listID == "list-1" && applied[0].lastModified == nil
        && applied[1] == original[1]
    check(
        fieldsKept,
        "applyingTitle rewrites one row's title and nothing else",
        fieldsKept ? "r1 titled \"after\" with every other field kept; r2 untouched" : "applied: \(applied)"
    )

    let replacement = ReminderStore.replacingListViewIdentifier(
        availableListIDs: ["a", "b", "c", "d"],
        viewListIDs: ["a", "c"],
        index: 0,
        listID: "b"
    )
    let duplicate = ReminderStore.replacingListViewIdentifier(
        availableListIDs: ["a", "b", "c", "d"],
        viewListIDs: ["a", "c"],
        index: 0,
        listID: "c"
    )
    check(
        replacement == ["b", "c"] && duplicate == nil,
        "a capsule can choose an unused list but cannot duplicate another view",
        "replacement=\(replacement ?? []), duplicate accepted=\(duplicate != nil)"
    )
}

// MARK: - 2..5 · The flow through the real store

@MainActor
private func runFlowChecks() async {
    print("")
    print("— 2 · the flow through the real store —")

    let queueURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("probe-reminder-queue-\(UUID().uuidString).json")
    let defaults = UserDefaults.standard
    let saved = defaultsKeysToRestore.map { ($0, defaults.object(forKey: $0)) }
    defer {
        for (key, value) in saved {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
    }

    let fixture = [reminder(id: "r1", title: "买牛奶")]
    let service = StubRemindersService(reminders: fixture)
    let (store, _) = makeStore(service: service, queueURL: queueURL)

    store.requestRefresh(reloadLists: true)
    let didRead = await waitUntil { !store.items.isEmpty }
    check(
        didRead && store.items.first?.title == "买牛奶",
        "the fixture lands as a row",
        didRead ? "row titled \"\(store.items.first?.title ?? "nil")\"" : "the read never produced rows"
    )

    // The flow: pencil → the store holds the row and its draft → commit.
    guard let item = store.items.first else { return }
    store.beginEditing(item)
    check(
        store.editingID == "r1" && store.editingDraft == "买牛奶",
        "beginning an edit opens the row with its own title",
        "editingID=\(store.editingID.map { $0.prefix(6) } ?? "nil"), draft=\"\(store.editingDraft)\""
    )

    store.updateEditingDraft("买牛奶两瓶")
    await store.commitEditing()
    let update = await service.updates.first
    check(
        await service.updates.count == 1
            && update?.id == "r1"
            && update?.title == "买牛奶两瓶"
            && update?.due == nil
            && store.items.first?.title == "买牛奶两瓶"
            && store.editingID == nil,
        "a commit writes the title only and closes the edit",
        "service saw update(r1, \"买牛奶两瓶\", nil); row now \"\(store.items.first?.title ?? "nil")\"; editing=\(store.editingID != nil)"
    )

    // A draft that restates the title writes nothing.
    store.beginEditing(item)
    store.updateEditingDraft("买牛奶两瓶")
    await store.commitEditing()
    check(
        await service.updates.count == 1 && store.editingID == nil,
        "restating the title writes nothing",
        "updates still \(await service.updates.count), editing=\(store.editingID != nil)"
    )

    // A cleared draft writes nothing either.
    store.beginEditing(item)
    store.updateEditingDraft("   ")
    await store.commitEditing()
    check(
        await service.updates.count == 1 && store.editingID == nil,
        "a cleared draft writes nothing",
        "updates still \(await service.updates.count), editing=\(store.editingID != nil)"
    )

    // A failed write reverts: the optimistic title is replaced by a re-read.
    await service.setFailNextUpdate(true)
    store.beginEditing(item)
    store.updateEditingDraft("第三版")
    await store.commitEditing()
    let reverted = await waitUntil { store.items.first?.title == "买牛奶两瓶" }
    check(
        reverted && store.lastError != nil && store.editingID == nil,
        "a failed write reverts the optimistic title",
        "row \"\(store.items.first?.title ?? "nil")\" (reverted=\(reverted)), error recorded=\(store.lastError != nil)"
    )
    await service.setFailNextUpdate(false)

    // A refresh that no longer knows the row ends the edit.
    store.beginEditing(item)
    let editingBefore = store.editingID != nil
    await service.setReminders([])
    store.requestRefresh()
    _ = await waitUntil { store.items.isEmpty }
    check(
        editingBefore && store.items.isEmpty && store.editingID == nil,
        "a refresh that loses the row ends the edit",
        "was editing=\(editingBefore), rows now \(store.items.count), editing=\(store.editingID != nil)"
    )

    // A pending local row has nothing on the system to update.
    let pending = ReminderPanelItem(
        id: UUID().uuidString,
        origin: .pendingLocal(id: UUID()),
        title: "not written yet",
        dueDate: nil,
        isDueDateAllDay: false,
        createdDate: nil,
        syncState: .failed("probe")
    )
    store.beginEditing(pending)
    check(
        store.editingID == nil && !pending.isEditable,
        "a pending local row offers no edit",
        "beginEditing on a placeholder -> editingID=\(store.editingID.map { $0.prefix(6) } ?? "nil")"
    )
}

// MARK: - 6 · ending the editing session saves

/// The panel's edit row, reduced to the part this check is about.
private struct ProbeEditRow: View {
    @ObservedObject var store: ReminderStore
    @ObservedObject var box: EditFocusBox

    var body: some View {
        TextField("Edit reminder", text: editBinding)
            .textFieldStyle(.plain)
            .frame(width: 200, height: 24)
            .fieldCaretFocus(
                request: box.request,
                placeholder: "Edit reminder",
                onEndEditing: { Task { await store.commitEditing() } }
            )
    }

    private var editBinding: Binding<String> {
        Binding(get: { store.editingDraft }, set: { store.updateEditingDraft($0) })
    }
}

@MainActor
private final class EditFocusBox: ObservableObject {
    @Published var request = 0
}

@MainActor
private func makeEditHost(_ view: some View, width: CGFloat, height: CGFloat) -> (NSHostingView<AnyView>, NSWindow) {
    let host = NSHostingView(rootView: AnyView(view.frame(width: width, height: height)))
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    // The app's own panel class: a borderless `NSWindow` answers `false` to
    // `canBecomeKey`, and a field editor will not attach without a key window —
    // so a probe built on one would test a state the app is never in.
    let window = NotchPanel(
        contentRect: host.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.allowsKeyboardFocus = true
    window.contentView = host
    NSApp.setActivationPolicy(.accessory)
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    // A window becomes key on the next turn, not inside `makeKeyAndOrderFront`.
    for _ in 0 ..< 6 {
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
    }
    return (host, window)
}

@MainActor
private func pump(_ host: NSView, _ window: NSWindow, turns: Int = 6) {
    for _ in 0 ..< turns {
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
    }
    _ = window
}

@MainActor
private func field(in view: NSView, placeholder: String) -> NSTextField? {
    if let field = view as? NSTextField, field.placeholderString == placeholder { return field }
    for subview in view.subviews {
        if let found = field(in: subview, placeholder: placeholder) { return found }
    }
    return nil
}

@MainActor
private func waitForUpdates(_ service: StubRemindersService, atLeast count: Int, timeout: TimeInterval = 3) async -> Int {
    let deadline = Date().addingTimeInterval(timeout)
    var recorded = await service.updates.count
    while recorded < count, Date() < deadline {
        try? await Task.sleep(for: .milliseconds(20))
        recorded = await service.updates.count
    }
    return recorded
}

@MainActor
private func checkEndOfEditingSaves() async {
    print("")
    print("— 6 · the editing session ending is a save —")

    let defaults = UserDefaults.standard
    let saved = defaultsKeysToRestore.map { ($0, defaults.object(forKey: $0)) }
    defer {
        for (key, value) in saved {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
    }

    let queueURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("probe-reminder-queue-\(UUID().uuidString).json")
    let service = StubRemindersService(reminders: [reminder(id: "r1", title: "买牛奶")])
    let (store, _) = makeStore(service: service, queueURL: queueURL)
    store.requestRefresh(reloadLists: true)
    guard await waitUntil({ !store.items.isEmpty }), let item = store.items.first else {
        check(false, "a row to edit", "the read never produced rows")
        return
    }

    let box = EditFocusBox()
    let (host, window) = makeEditHost(ProbeEditRow(store: store, box: box), width: 240, height: 40)

    // Open the edit and let the caret bridge focus the field, as the pencil does.
    store.beginEditing(item)
    box.request += 1
    pump(host, window)

    guard let textField = field(in: host, placeholder: "Edit reminder") else {
        check(false, "the edit field exists", "no NSTextField with the edit placeholder")
        return
    }
    let isEditing = window.firstResponder === textField.currentEditor()
    (textField.currentEditor())?.insertText("两瓶")
    pump(host, window, turns: 3)
    let typed = store.editingDraft

    // Now end the session the way clicking anything else does.
    _ = window.makeFirstResponder(nil as NSResponder?)
    pump(host, window)
    let recorded = await waitForUpdates(service, atLeast: 1)
    let update = await service.updates.first

    check(
        isEditing && typed == "买牛奶两瓶"
            && recorded == 1
            && update?.title == "买牛奶两瓶"
            && store.items.first?.title == "买牛奶两瓶"
            && store.editingID == nil,
        "letting the field go writes what was typed",
        "focused=\(isEditing), typed \"\(typed)\", service saw \(recorded) update(s)\(update.map { " (\"\($0.title ?? "nil")\")" } ?? ""), row now \"\(store.items.first?.title ?? "nil")\""
    )

    // Esc cancels first, so the end of the session that follows writes nothing.
    guard let current = store.items.first else { return }
    store.beginEditing(current)
    box.request += 1
    pump(host, window)
    (textField.currentEditor())?.insertText("!!")
    pump(host, window, turns: 3)
    store.cancelEditing()
    _ = window.makeFirstResponder(nil as NSResponder?)
    pump(host, window)
    try? await Task.sleep(for: .milliseconds(150))
    let afterCancel = await service.updates.count
    check(
        afterCancel == recorded && store.editingID == nil,
        "a cancelled edit writes nothing when the field lets go",
        "updates still \(afterCancel), editing=\(store.editingID != nil)"
    )
}

// MARK: - Entry point

// A main.swift's top-level code is only main-actor isolated in Swift 6 language
// mode; the probe compiles under Swift 5, so it says so here.
MainActor.assumeIsolated {
    _ = NSApplication.shared

    print("=== YUANNotch · reminder editing probe ===")
    print("")
    checkRules()

    var done = false
    Task { @MainActor in
        await runFlowChecks()
        await checkEndOfEditingSaves()
        done = true
    }
    // The flow's awaits need the main actor to run; pumping the run loop is what
    // lets it, the way the app's own main loop would.
    while !done {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

    print("")
    print(failures == 0 ? "every check passed" : "\(failures) check(s) failed")
    exit(failures == 0 ? 0 : 1)
}
