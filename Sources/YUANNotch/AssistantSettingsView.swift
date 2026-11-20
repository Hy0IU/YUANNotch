import AppKit
import SwiftUI

@MainActor
struct AssistantSettingsView: View {
    private enum ModelChoice: Hashable {
        case unselected, listed(String), manual
    }

    private enum EditorMode {
        case add, edit(UUID), duplicate(UUID)

        var title: String {
            switch self {
            case .add: "Add model"
            case .edit: "Edit model"
            case .duplicate: "Duplicate model"
            }
        }

        var profileID: UUID? {
            if case .edit(let id) = self { return id }
            return nil
        }

        var credentialSourceID: UUID? {
            switch self {
            case .add: nil
            case .edit(let id), .duplicate(let id): id
            }
        }
    }

    @State private var editorMode: EditorMode?
    @State private var privacy = false
    @State private var confirmRemove = false
    @State private var removing: AssistantProvider.Configuration?
    @State private var confirmSave = false
    @State private var reviewDestination = ""
    @State private var name = ""
    @State private var address = ""
    @State private var manualID = ""
    @State private var choice: ModelChoice = .unselected
    @State private var models: [String] = []
    @State private var fetch: Task<Void, Never>?
    @State private var catalogError: String?
    @State private var format: AssistantAPIFormat = .chat
    @State private var exactURL = false
    @State private var auth: AssistantAuthMode = .automatic
    @State private var header = ""
    @State private var apiKey = ""
    @State private var saved: [AssistantProvider.Configuration] = []
    @State private var active: AssistantProvider.Configuration?
    @State private var test: Task<Void, Never>?
    @State private var message: String?
    @State private var isError = false

    private var model: String {
        switch choice {
        case .unselected: ""
        case .listed(let id): id
        case .manual: manualID.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let editorMode {
                titleBar(editorMode.title, caption: "AI Assistant")
                editor
                Divider()
                saveBar
            } else {
                titleBar("Saved models", caption: "AI Assistant")
                savedModels
            }
        }
        .confirmationDialog("Remove this saved model?", isPresented: $confirmRemove, presenting: removing) { profile in
            Button("Remove", role: .destructive) { remove(profile) }
        } message: { profile in
            Text(verbatim: "Removing \(profile.name) also deletes its saved API key."
                 + (profile.id == active?.id ? " Choose another active model before sending messages." : ""))
        }
        .alert("Test this model and save it?", isPresented: $confirmSave) {
            Button("Cancel", role: .cancel) {}
            Button("Test & Save", action: testAndSave)
        } message: {
            Text(verbatim: "Send a test greeting using \(model) to:\n\n\(reviewDestination)\n\n\(saveEffect)")
        }
        .onChange(of: model) { _, _ in if isError { message = nil } }
        .onChange(of: name) { _, _ in if isError { message = nil } }
        .onAppear { showCurrent() }
        .onReceive(NotificationCenter.default.publisher(for: AssistantProvider.profilesChanged)) { _ in refreshProfiles() }
        .onDisappear { endEditing() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if let window = notification.object as? NSWindow, window.windowController is SettingsWindowController {
                showCurrent()
            }
        }
    }

    private var credentialSource: AssistantProvider.Configuration? {
        guard let id = editorMode?.credentialSourceID else { return nil }
        return saved.first {
            $0.id == id && $0.matchesConnection(address: address, format: format, exactURL: exactURL, auth: auth, header: header)
        }
    }

    private var canReuseCredential: Bool {
        guard let credentialSource, let destination = try? resolveDestination() else { return false }
        return credentialSource.endpoint.absoluteString == destination
    }

    private var saveEffect: String {
        if saved.isEmpty { return "The model becomes active only if the test succeeds." }
        if let id = editorMode?.profileID, id == active?.id {
            return "The active model is updated only if the test succeeds."
        }
        return "The model is saved only if the test succeeds. It won't become active."
    }

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                field("Profile name") { TextField("My model", text: $name) }
                field("API format") {
                    Picker("API format", selection: connectionField($format)) {
                        ForEach(AssistantAPIFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                }
                field("URL type") {
                    Picker("URL type", selection: connectionField($exactURL)) {
                        Text("Base URL").tag(false)
                        Text("Full request URL").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                field("API URL") {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("https://", text: connectionField($address))
                        Text(exactURL ? "Use this address as-is for chat requests." : "Add the chat path based on the API format.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                field("Authentication") {
                    Picker("Authentication", selection: connectionField($auth)) {
                        ForEach(AssistantAuthMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                }
                if auth == .customHeader {
                    field("Header name") { TextField("X-API-Key", text: connectionField($header)) }
                }
                if auth != .none {
                    field("API key") {
                        VStack(alignment: .leading, spacing: 4) {
                            SecureField(canReuseCredential ? "Leave blank to reuse the saved key" : "Paste your API key",
                                        text: connectionField($apiKey, isKey: true))
                                .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .help("Enter the address first. Changing connection settings clears a pasted key.")
                            if credentialSource != nil && !canReuseCredential {
                                Text("Model lookup can use the saved key. For a different chat endpoint, enter a key if needed.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                modelControls
            }
            .textFieldStyle(.roundedBorder)
            .disabled(test != nil)
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }

    @ViewBuilder private var modelControls: some View {
        HStack(spacing: 8) {
            Button(action: fetchModels) {
                Label(fetch == nil ? "Fetch models" : "Fetching models…", systemImage: "list.bullet")
            }
            .buttonStyle(.borderedProminent)
            .disabled(fetch != nil || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if fetch != nil {
                ProgressView().controlSize(.small)
                Button("Cancel fetch", action: cancelFetch)
            } else if !models.isEmpty {
                Text("\(models.count) available").font(.caption).foregroundStyle(.secondary)
            } else if choice == .unselected {
                Button("Enter ID manually") { choice = .manual }
                    .buttonStyle(.link)
            }
        }
        if let catalogError {
            Text(catalogError).font(.caption).foregroundStyle(.red).textSelection(.enabled)
        }
        if !models.isEmpty {
            field("Model") {
                Picker("Model", selection: $choice) {
                    Text("Choose a model…").tag(ModelChoice.unselected)
                    ForEach(models, id: \.self) { id in Text(verbatim: id).tag(ModelChoice.listed(id)) }
                    Divider()
                    Text("Enter an ID manually…").tag(ModelChoice.manual)
                }
                .labelsHidden().pickerStyle(.menu).lineLimit(1).truncationMode(.middle)
            }
        }
        if choice == .manual {
            field("Model ID") { TextField("Enter a model ID manually", text: $manualID) }
        }
    }

    private var saveBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.isEmpty, let destination = try? resolveDestination() {
                field("Chat endpoint") {
                    Text(verbatim: destination).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle).help(destination).textSelection(.enabled)
                }
            }
            statusMessage
            if let active, message == nil {
                Text(verbatim: "Active model: \(active.name)").font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            HStack {
                if test == nil {
                    Button("Cancel", action: showCurrent)
                } else {
                    Button("Cancel test", action: cancelTest)
                }
                Spacer()
                if test != nil { ProgressView().controlSize(.small) }
                Button(test == nil ? "Test & Save…" : "Testing…", action: reviewSave)
                    .disabled(test != nil || fetch != nil || model.isEmpty ||
                              name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var savedModels: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let error = AssistantProvider.storageError {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                } else if saved.isEmpty {
                    Text("No saved models. Add and test a model to start using the assistant.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    if active == nil {
                        Text("No active model. Choose Use on a saved model to switch to it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(saved) { profile in profileCard(profile) }
                }
                statusMessage
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    private func profileCard(_ profile: AssistantProvider.Configuration) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: profile.name).font(.headline).textSelection(.enabled)
                Spacer()
                if profile.id == active?.id {
                    Label("Active", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(.green)
                } else {
                    Button("Use") { AssistantProvider.activate(profile.id) }
                        .accessibilityLabel(Text(verbatim: "Use \(profile.name)"))
                }
            }
            field("Model ID") { Text(verbatim: profile.model).textSelection(.enabled) }
            field("Destination") {
                Text(verbatim: profile.endpoint.absoluteString).font(.caption.monospaced())
                    .lineLimit(2).truncationMode(.middle).help(profile.endpoint.absoluteString).textSelection(.enabled)
            }
            Divider()
            HStack {
                Button("Edit") { beginDraft(.edit(profile.id), source: profile) }
                Button("Duplicate") { beginDraft(.duplicate(profile.id), source: profile) }
                Spacer()
                Button("Remove…", role: .destructive) {
                    removing = profile
                    confirmRemove = true
                }
            }
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var statusMessage: some View {
        if let message {
            Text(message).font(.caption).foregroundStyle(isError ? Color.red : .secondary)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func titleBar(_ title: String, caption: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(caption).font(.caption).foregroundStyle(.secondary)
                Text(title).font(.title3.weight(.semibold))
            }
            Spacer()
            if editorMode == nil && AssistantProvider.storageError == nil {
                Button {
                    beginDraft(.add)
                } label: {
                    Label("Add Model", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            Button { privacy.toggle() } label: { Image(systemName: "info.circle") }
                .buttonStyle(.plain).accessibilityLabel("Connection privacy")
                .popover(isPresented: $privacy) {
                    Text("Fetch models requests the model list from your provider. Testing sends a greeting, not your agenda. When you use the assistant, your message and selected context go to this provider. Saved API keys stay in Keychain.")
                        .font(.callout).frame(width: 250).padding()
                }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func field<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            control().accessibilityLabel(label).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
    }

    // Invalidate synchronously, not in onChange: a subsequent request must never
    // see an old address's pasted key or publish the old connection's model list.
    private func connectionField<Value: Equatable>(_ value: Binding<Value>, isKey: Bool = false) -> Binding<Value> {
        Binding(get: { value.wrappedValue }, set: { newValue in
            guard value.wrappedValue != newValue else { return }
            cancelFetch()
            models = []
            if case .listed(let id) = choice {
                manualID = isKey ? id : ""
                choice = isKey ? .manual : .unselected
            }
            catalogError = nil
            message = nil
            if !isKey { apiKey = "" }
            value.wrappedValue = newValue
        })
    }

    private func beginDraft(_ mode: EditorMode, source: AssistantProvider.Configuration? = nil) {
        endEditing()
        editorMode = mode
        if case .duplicate = mode, let source {
            name = "\(source.name) copy"
        } else {
            name = source?.name ?? ""
        }
        address = source?.address ?? ""
        manualID = source?.model ?? ""
        choice = source == nil ? .unselected : .manual
        format = source?.format ?? .chat
        exactURL = source?.exactURL ?? false
        auth = source?.auth ?? .automatic
        header = source?.header ?? ""
        message = nil
    }

    private func refreshProfiles() {
        saved = AssistantProvider.configurations
        active = AssistantProvider.configuration
    }

    private func showCurrent() {
        endEditing()
        editorMode = nil
        refreshProfiles()
        message = nil
    }

    private func fetchModels() {
        cancelFetch()
        catalogError = nil
        message = nil
        let profileID = editorMode?.credentialSourceID
        fetch = Task { @MainActor [address, format, exactURL, auth, header, apiKey] in
            do {
                try Task.checkCancellation()
                let ids = try await AssistantProvider.fetchModels(
                    address: address, format: format, exactURL: exactURL, auth: auth, header: header, apiKey: apiKey,
                    profileID: profileID
                )
                try Task.checkCancellation()
                let current = model
                models = ids
                if ids.contains(current) {
                    choice = .listed(current)
                } else if current.isEmpty {
                    choice = .unselected
                } else {
                    manualID = current
                    choice = .manual
                }
            } catch {
                guard !Task.isCancelled else { return }
                manualID = model
                models = []
                choice = .manual
                catalogError = error.localizedDescription
            }
            fetch = nil
        }
    }

    private func resolveDestination() throws -> String {
        try format.resolve(address: address, model: model, exactURL: exactURL).absoluteString
    }

    private func reviewSave() {
        do {
            reviewDestination = try resolveDestination()
            message = nil
            confirmSave = true
        } catch {
            isError = true
            message = error.localizedDescription
        }
    }

    private func testAndSave() {
        guard let editorMode else { return }
        message = nil
        test = Task { @MainActor [name, address, model, format, exactURL, auth, header, apiKey] in
            do {
                try Task.checkCancellation()
                try await AssistantProvider.testAndSave(
                    name: name, address: address, model: model, format: format, exactURL: exactURL,
                    auth: auth, header: header, apiKey: apiKey, profileID: editorMode.profileID,
                    credentialSourceID: editorMode.credentialSourceID
                )
                guard !Task.isCancelled else { return }
                test = nil
                showCurrent()
                isError = false
                message = "Connection tested and saved."
            } catch {
                guard !Task.isCancelled else { return }
                isError = true
                message = error.localizedDescription
            }
            test = nil
        }
    }

    private func remove(_ profile: AssistantProvider.Configuration) {
        do {
            try AssistantProvider.remove(profile.id)
            isError = false
            message = "Model and its saved credential removed."
        } catch {
            isError = true
            message = error.localizedDescription
        }
    }

    private func cancelFetch() {
        fetch?.cancel()
        fetch = nil
    }

    private func cancelTest() {
        test?.cancel()
        test = nil
    }

    private func endEditing() {
        cancelFetch()
        cancelTest()
        confirmSave = false
        confirmRemove = false
        removing = nil
        privacy = false
        apiKey = ""
        models = []
        catalogError = nil
    }
}
