import SwiftUI

struct AssistantPanelView: View {
    @ObservedObject var scheduleStore: ScheduleStore
    let dailyPlanStore: DailyPlanStore
    let onBack: () -> Void
    let onOpenSettings: () -> Void
    @ObservedObject private var session = AssistantSession.shared
    @State private var showsScope = false
    @State private var focused = false
    @State private var composing = false
    @State private var configurations = AssistantProvider.configurations
    @State private var configuration = AssistantProvider.configuration

    private enum TranscriptAnchor { case request, reply, proposals, bottom }

    private var scope: AssistantSession.Scope { session.scope(in: scheduleStore) }
    private var busy: Bool { session.working || session.applying }
    private var hasInput: Bool { !session.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var canSend: Bool { configuration != nil && !busy && !composing && hasInput }
    private var endpoint: String { configuration?.endpoint.absoluteString ?? "尚未配置" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: onBack) { toolbarIcon("chevron.backward") }
                    .accessibilityLabel("返回工作区").help("返回工作区")
                    .keyboardShortcut(.cancelAction)
                Text("计划助手").font(.headline)
                Spacer(minLength: 4)
                profileMenu
                Button {
                    session.reset()
                    session.input = ""
                    session.firstDay = Calendar.current.startOfDay(for: Date())
                } label: { toolbarIcon("square.and.pencil") }
                    .disabled(session.applying)
                    .accessibilityLabel("新建对话").help("清空当前对话和草稿")
            }
            .buttonStyle(.plain)

            conversation
            composer
        }
        .environment(\.colorScheme, .dark)
        .onAppear {
            refreshProfiles()
            session.scopeChanged(scope)
        }
        .onReceive(NotificationCenter.default.publisher(for: AssistantProvider.profilesChanged)) { _ in
            configurations = AssistantProvider.configurations
        }
        .onReceive(NotificationCenter.default.publisher(for: AssistantProvider.changed)) { _ in
            configuration = AssistantProvider.configuration
        }
        .onChange(of: scope) { _, scope in session.scopeChanged(scope) }
    }

    @ViewBuilder private var conversation: some View {
        if session.lastRequest.isEmpty && session.error == nil && !busy {
            ViewThatFits(in: .vertical) {
                welcome.fixedSize(horizontal: false, vertical: true)
                ScrollView { welcome.frame(maxWidth: .infinity) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        if session.lastRequest.isEmpty {
                            welcome
                        } else {
                            Text(session.lastRequest)
                                .lineLimit(3).padding(.horizontal, 10).padding(.vertical, 6)
                                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .id(TranscriptAnchor.request)
                            if !session.answer.isEmpty {
                                Text(session.answer).textSelection(.enabled)
                                    .id(TranscriptAnchor.reply)
                            }
                            if !session.answer.isEmpty && session.candidates.isEmpty && session.receipt.isEmpty && session.error == nil && !busy {
                                Text("Discussion only · no changes applied").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if !session.candidates.isEmpty {
                            Text("Proposed changes · not applied").fontWeight(.semibold)
                                .id(TranscriptAnchor.proposals)
                            ForEach(session.candidates) { row in
                                VStack(alignment: .leading, spacing: 3) {
                                    Toggle(isOn: Binding(get: { row.selected }, set: { _ in session.toggle(row.id) })) {
                                        Text(row.change.headline).fixedSize(horizontal: false, vertical: true)
                                    }
                                    .toggleStyle(.checkbox).disabled(busy)
                                    DisclosureGroup("Details") {
                                        Text(row.change.summary).textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .font(.caption).padding(.leading, 18)
                                }
                            }
                            Button("Apply \(session.selectedCount) \(session.selectedCount == 1 ? "change" : "changes")") {
                                Task { await session.apply(schedule: scheduleStore) }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(busy || composing || hasInput || session.selectedCount == 0)
                        }
                        if !session.receipt.isEmpty { Text(session.receipt).foregroundStyle(.green).textSelection(.enabled) }
                        if let error = session.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                        if busy {
                            ProgressView(session.applying ? "Applying…" : (session.answer.isEmpty ? "Preparing reply…" : "Receiving reply…"))
                                .controlSize(.small)
                        }
                        Color.clear.frame(height: 1).id(TranscriptAnchor.bottom)
                    }
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: session.requestID, initial: true) { _, requestID in
                    if requestID != nil { proxy.scrollTo(TranscriptAnchor.request, anchor: .top) }
                }
                .onChange(of: session.answer, initial: true) { _, answer in
                    if !answer.isEmpty && session.candidates.isEmpty && session.error == nil && session.receipt.isEmpty {
                        proxy.scrollTo(TranscriptAnchor.reply, anchor: .bottom)
                    }
                }
                .onChange(of: session.candidates.isEmpty, initial: true) { _, empty in
                    if !empty { proxy.scrollTo(TranscriptAnchor.proposals, anchor: .top) }
                }
                .onChange(of: session.error, initial: true) { _, error in
                    if error != nil { proxy.scrollTo(TranscriptAnchor.bottom, anchor: .bottom) }
                }
                .onChange(of: session.receipt) { _, text in
                    if !text.isEmpty { proxy.scrollTo(TranscriptAnchor.bottom, anchor: .bottom) }
                }
            }
        }
    }

    private func refreshProfiles() {
        configurations = AssistantProvider.configurations
        configuration = AssistantProvider.configuration
    }

    private func profileTitle(_ profile: AssistantProvider.Configuration) -> String {
        profile.name == profile.model ? profile.name : "\(profile.name) · \(profile.model)"
    }

    private var profileMenu: some View {
        let title = configuration.map(profileTitle) ?? "未选择模型"
        return Menu {
            ForEach(configurations) { profile in
                Button {
                    guard !busy else { return }
                    showsScope = false
                    AssistantProvider.activate(profile.id)
                } label: {
                    if profile.id == configuration?.id {
                        Label(profileTitle(profile), systemImage: "checkmark")
                    } else {
                        Text(profileTitle(profile))
                    }
                }
            }
            if !configurations.isEmpty { Divider() }
            Button("模型设置…", action: onOpenSettings)
        } label: {
            HStack(spacing: 5) {
                Text(title).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(.caption)
            .frame(maxWidth: 140, minHeight: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .disabled(busy)
        .accessibilityLabel("当前模型")
        .accessibilityValue(title)
        .help(title)
    }

    private func toolbarIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .medium))
            .frame(width: 28, height: 28)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
    }

    private var welcome: some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(configuration != nil ? "今天有什么安排？" : "先配置一个模型")
            }
            .font(.system(size: 22, weight: .semibold, design: .rounded))
            Text(configuration != nil ? "可以粘贴通知，让我帮你整理提醒；也可以聊聊怎么调整安排。" : "添加并选用模型后，就可以开始对话。")
                .font(.system(size: 14)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if configuration == nil {
                Button("打开模型设置…", action: onOpenSettings)
                    .buttonStyle(.link)
                    .font(.system(size: 13))
            }
        }
        .padding(.horizontal, 8)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .topLeading) {
                AssistantComposerInput(text: $session.input, focused: $focused, composing: $composing,
                                       editable: !busy, onSend: send)
                if session.input.isEmpty && !composing {
                    Text("输入问题，或粘贴一段通知…")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(height: AssistantComposerInput.height)
            HStack(spacing: 8) {
                Button { showsScope = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "slider.horizontal.3")
                        Text(disclosure).lineLimit(1).truncationMode(.tail)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(minHeight: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("\(sharedContext) → \(endpoint)")
                .accessibilityLabel("共享范围：\(sharedContext)；请求地址：\(endpoint)")
                .disabled(busy)
                .popover(isPresented: $showsScope) { sharingOptions }
                Spacer(minLength: 0)
                Button(action: send) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up")
                        Text("发送")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(canSend ? Color.white : Color.secondary)
                    .frame(width: 80, height: 34)
                    .background(canSend ? Color.accentColor : Color.white.opacity(0.09), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain).fixedSize()
                .accessibilityLabel("发送").help("回车发送，Shift + 回车换行").disabled(!canSend)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(white: 0.10), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(focused ? Color.accentColor.opacity(0.65) : .white.opacity(0.15))
                .allowsHitTesting(false)
        }
    }

    private func send() {
        guard canSend, AssistantProvider.configuration != nil else { return }
        session.send(schedule: scheduleStore, plans: dailyPlanStore)
    }

    private var sharedContext: String {
        let selected = [(session.events, "日程"), (session.reminders, "提醒"), (session.goals, "目标")]
            .compactMap { $0.0 ? $0.1 : nil }.joined(separator: "、")
        return selected.isEmpty ? "仅共享对话" : selected
    }

    private var disclosure: String {
        guard let destination = configuration?.endpoint, let host = destination.host else { return sharedContext }
        let authority = destination.port.map { "\(host):\($0)" } ?? host
        return "\(authority) · \(sharedContext)"
    }

    private var sharingOptions: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Share with model").font(.headline)
            Text(endpoint).font(.caption).textSelection(.enabled)
            Text("Your message and recent discussion are sent on Send. Optionally include the following data from sources selected in Schedule. Changing context clears the previous discussion.")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            Toggle("Calendar events", isOn: $session.events)
            Toggle("Open reminders (including undated)", isOn: $session.reminders)
            Toggle("Today’s goals and progress", isOn: $session.goals)
            if session.events || session.reminders {
                DatePicker("From", selection: $session.firstDay, displayedComponents: .date)
                Picker("Range", selection: $session.days) {
                    ForEach([1, 7, 14], id: \.self) { Text("\($0) days").tag($0) }
                }
                Text("\(scope.sources.count) selected calendar / reminder sources").font(.caption)
            }
            HStack {
                Button("Settings…") { showsScope = false; onOpenSettings() }
                Spacer()
                Button("Done") { showsScope = false }
            }
        }
        .padding().frame(width: 300)
    }
}
