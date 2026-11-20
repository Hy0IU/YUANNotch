import Foundation
import Security

@MainActor
enum AssistantProvider {
    struct Configuration: Codable, Identifiable, Equatable {
        fileprivate static let legacyID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))

        let id: UUID
        let name: String
        let endpoint: URL
        let model: String
        let address: String
        let format: AssistantAPIFormat
        let exactURL: Bool
        let auth: AssistantAuthMode
        let header: String

        init(id: UUID = UUID(), name: String, address: String, model: String, format: AssistantAPIFormat,
             exactURL: Bool, auth: AssistantAuthMode, header: String) throws {
            self.id = id
            self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !self.name.isEmpty, self.name.rangeOfCharacter(from: .controlCharacters) == nil else {
                throw ProviderError.invalidName
            }
            self.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
            self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !self.model.isEmpty, self.model.rangeOfCharacter(from: .controlCharacters) == nil else {
                throw ProviderError.invalidModel
            }
            self.endpoint = try format.resolve(address: self.address, model: self.model, exactURL: exactURL)
            self.format = format
            self.exactURL = exactURL
            self.auth = auth
            self.header = auth == .customHeader ? header.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        }

        func matchesConnection(address: String, format: AssistantAPIFormat, exactURL: Bool,
                               auth: AssistantAuthMode, header: String) -> Bool {
            self.address == address.trimmingCharacters(in: .whitespacesAndNewlines)
                && self.format == format && self.exactURL == exactURL && self.auth == auth
                && (auth != .customHeader || self.header.caseInsensitiveCompare(header.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame)
        }

        init(from decoder: Decoder) throws {
            try self.init(from: decoder, legacy: false)
        }

        fileprivate init(from decoder: Decoder, legacy: Bool) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let id = if legacy { Self.legacyID } else { try values.decode(UUID.self, forKey: .id) }
            let model = try values.decode(String.self, forKey: .model)
            let name = if legacy {
                try values.decodeIfPresent(String.self, forKey: .name)
                    ?? values.decode(URL.self, forKey: .endpoint).host ?? "Custom provider"
            } else {
                try values.decode(String.self, forKey: .name)
            }
            if !legacy || values.contains(.address) {
                try self.init(id: id, name: name, address: values.decode(String.self, forKey: .address), model: model,
                              format: values.decode(AssistantAPIFormat.self, forKey: .format),
                              exactURL: values.decode(Bool.self, forKey: .exactURL),
                              auth: values.decode(AssistantAuthMode.self, forKey: .auth),
                              header: values.decode(String.self, forKey: .header))
            } else {
                // The first release stored the complete chat URL. Never append
                // another route or move its endpoint-bound credential.
                let old = try values.decode(URL.self, forKey: .endpoint)
                try self.init(id: id, name: name, address: old.absoluteString, model: model, format: .chat,
                              exactURL: true, auth: .automatic, header: "")
            }
        }
    }

    private struct Profiles: Codable {
        var configurations: [Configuration] = []
        var activeID: UUID?
    }

    private struct LegacyProfile: Decodable {
        let configuration: Configuration

        init(from decoder: Decoder) throws {
            configuration = try Configuration(from: decoder, legacy: true)
        }
    }

    private static let legacySettingsKey = "yuanNotch.assistantProvider"
    private static let profilesKey = "yuanNotch.assistantProfiles"
    static let changed = Notification.Name("YUANNotch.assistantProviderChanged")
    static let profilesChanged = Notification.Name("YUANNotch.assistantProfilesChanged")

    private static var profiles: Result<Profiles, Error> = Result { try loadProfiles() }

    static var configurations: [Configuration] { (try? profiles.get())?.configurations ?? [] }

    static var configuration: Configuration? {
        guard let saved = try? profiles.get(), let id = saved.activeID else { return nil }
        return saved.configurations.first { $0.id == id }
    }

    static var storageError: String? {
        guard case .failure(let error) = profiles else { return nil }
        return error.localizedDescription
    }

    private static func loadProfiles() throws -> Profiles {
        let defaults = UserDefaults.standard
        let decoder = JSONDecoder()
        if let saved = defaults.object(forKey: profilesKey) {
            // The collection is authoritative, including an empty collection.
            guard let data = saved as? Data, let profiles = try? decoder.decode(Profiles.self, from: data) else {
                throw ProviderError.invalidStorage
            }
            let ids = Set(profiles.configurations.map(\.id))
            guard ids.count == profiles.configurations.count,
                  profiles.activeID.map(ids.contains) ?? true else { throw ProviderError.invalidStorage }
            return profiles
        }
        guard let saved = defaults.object(forKey: legacySettingsKey) else { return Profiles() }
        guard let data = saved as? Data, let old = try? decoder.decode(LegacyProfile.self, from: data) else {
            throw ProviderError.invalidStorage
        }
        // Migrate metadata in memory until the next save. Only this reserved
        // profile owns the old item; no Keychain read, copy, or prompt at load.
        return Profiles(configurations: [old.configuration], activeID: old.configuration.id)
    }

    private static func publish(_ next: Profiles, encoded data: Data, activeChanged: Bool) {
        UserDefaults.standard.set(data, forKey: profilesKey)
        UserDefaults.standard.removeObject(forKey: legacySettingsKey)
        profiles = .success(next)
        if activeChanged { NotificationCenter.default.post(name: changed, object: nil) }
        NotificationCenter.default.post(name: profilesChanged, object: nil)
    }

    static func activate(_ id: UUID) {
        guard var next = try? profiles.get(), next.activeID != id,
              next.configurations.contains(where: { $0.id == id }) else { return }
        next.activeID = id
        guard let data = try? JSONEncoder().encode(next) else { return }
        publish(next, encoded: data, activeChanged: true)
    }

    static func remove(_ id: UUID) throws {
        var next = try profiles.get()
        guard let index = next.configurations.firstIndex(where: { $0.id == id }) else {
            throw ProviderError.profileUnavailable
        }
        next.configurations.remove(at: index)
        let activeChanged = next.activeID == id
        if activeChanged { next.activeID = nil }
        let data = try JSONEncoder().encode(next)
        try ProviderKeychain.remove(id)
        publish(next, encoded: data, activeChanged: activeChanged)
    }

    static var endpointLabel: String { configuration?.endpoint.absoluteString ?? "Not configured" }

    static func complete(system: String, user: String, onDelta: @MainActor (String) -> Void) async throws -> String {
        _ = try profiles.get()
        guard let configuration else { throw ProviderError.notConfigured }
        let key = configuration.auth == .none ? nil : try ProviderKeychain.key(for: configuration)
        let request = try configuration.format.request(endpoint: configuration.endpoint, model: configuration.model,
                                                       auth: configuration.auth, header: configuration.header, key: key,
                                                       system: system, user: user, stream: true)
        return try await AssistantStream.complete(session: session, request: request, format: configuration.format, onDelta: onDelta)
    }

    /// Test the actual model on the actual route. A connectivity check doesn't
    /// grant write capabilities; every proposed write is validated in the session.
    static func testAndSave(name: String, address: String, model: String, format: AssistantAPIFormat, exactURL: Bool,
                            auth: AssistantAuthMode, header: String, apiKey: String,
                            profileID: UUID? = nil, credentialSourceID: UUID? = nil) async throws {
        let saved = try profiles.get()
        let original = saved.configurations.first { $0.id == profileID }
        if profileID != nil, original == nil { throw ProviderError.profileUnavailable }
        let candidate = try Configuration(id: profileID ?? UUID(), name: name, address: address, model: model, format: format,
                                          exactURL: exactURL, auth: auth, header: header)
        let source = original ?? saved.configurations.first { $0.id == credentialSourceID }
        let reusable: Configuration? = source.flatMap { source in
            source.matchesConnection(address: address, format: format, exactURL: exactURL, auth: auth, header: header)
                && source.endpoint.absoluteString == candidate.endpoint.absoluteString ? source : nil
        }
        let replacement = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let keySource = replacement.isEmpty && auth != .none ? reusable : nil
        let key = try credential(auth: auth, replacement: replacement, source: keySource)
        try await testConnection(candidate, key: key)
        try Task.checkCancellation()

        var next = try profiles.get()
        if let keySource, !next.configurations.contains(keySource) { throw ProviderError.profileUnavailable }
        if let original {
            guard let index = next.configurations.firstIndex(of: original) else { throw ProviderError.profileUnavailable }
            next.configurations[index] = candidate
        } else {
            if next.configurations.isEmpty { next.activeID = candidate.id }
            next.configurations.append(candidate)
        }
        let data = try JSONEncoder().encode(next)
        // Update only this profile's key before publishing its metadata. Even an
        // interruption cannot send a new endpoint's key to the old endpoint.
        if let key {
            try ProviderKeychain.save(key, for: candidate)
        } else if original != nil {
            try ProviderKeychain.remove(candidate.id)
        }
        publish(next, encoded: data, activeChanged: next.activeID == candidate.id)
    }

    /// Fetching the catalog neither activates the draft provider nor sends a chat message.
    static func fetchModels(address: String, format: AssistantAPIFormat, exactURL: Bool,
                            auth: AssistantAuthMode, header: String, apiKey: String, profileID: UUID? = nil) async throws -> [String] {
        let routes = try format.catalogRoutes(address: address, exactURL: exactURL)
        let source = configurations.first {
            $0.id == profileID && $0.matchesConnection(address: address, format: format, exactURL: exactURL, auth: auth, header: header)
        }
        let key = try credential(auth: auth, replacement: apiKey.trimmingCharacters(in: .whitespacesAndNewlines), source: source)
        let header = header.trimmingCharacters(in: .whitespacesAndNewlines)
        var routeIndex = 0
        var cursor: String?
        var visited = Set<String>()
        var models = Set<String>()
        var remainingBytes = 16 * 1024 * 1024
        while true {
            try Task.checkCancellation()
            let route = routes[routeIndex]
            let request = try route.format.catalogRequest(url: route.url, auth: auth, header: header, key: key, cursor: cursor)
            let data: Data
            do {
                data = try await responseData(to: request, limit: min(4 * 1024 * 1024, remainingBytes))
            } catch ProviderError.http(let status) where cursor == nil && (status == 404 || status == 405)
                && routeIndex + 1 < routes.count {
                routeIndex += 1
                continue
            }
            remainingBytes -= data.count
            try Task.checkCancellation()
            let page = try route.format.catalogPage(from: data)
            models.formUnion(page.ids)
            cursor = page.next
            if let cursor, visited.count >= 100 || !visited.insert(cursor).inserted {
                throw ProviderError.invalidPagination
            }
            if cursor == nil { break }
        }
        guard !models.isEmpty else { throw ProviderError.emptyCatalog }
        return models.sorted()
    }

    private static func credential(auth: AssistantAuthMode, replacement: String, source: Configuration?) throws -> String? {
        guard auth != .none else { return nil }
        if !replacement.isEmpty { return replacement }
        if let source { return try ProviderKeychain.key(for: source) }
        return nil
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()

    private static func testConnection(_ configuration: Configuration, key: String?) async throws {
        let request = try configuration.format.request(endpoint: configuration.endpoint, model: configuration.model,
                                                       auth: configuration.auth, header: configuration.header, key: key,
                                                       system: "This is a connection test.", user: "Reply with a short greeting.", stream: false)
        let data = try await responseData(to: request, limit: 256 * 1024)
        _ = try configuration.format.text(from: data)
    }

    private nonisolated static func responseData(to request: URLRequest, limit: Int) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ProviderError.http(http.statusCode) }
        guard response.expectedContentLength <= limit else { throw ProviderError.oversizedResponse }
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
        for try await byte in bytes {
            guard data.count < limit else { throw ProviderError.oversizedResponse }
            data.append(byte)
        }
        return data
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Never forward the credential OR the conversation/agenda, even on same-origin redirects.
        completionHandler(nil)
    }
}

private enum ProviderKeychain {
    private struct Credential: Codable { let endpoint: String; let key: String }
    private static func item(_ id: UUID) -> [String: Any] { [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "YUANNotch.assistantProvider",
        kSecAttrAccount as String: id == AssistantProvider.Configuration.legacyID ? "activeCredential" : "profile:\(id.uuidString)"
    ] }

    static func key(for configuration: AssistantProvider.Configuration) throws -> String? {
        var query = item(configuration.id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ProviderError.keychain(status) }
        guard let data = result as? Data, let credential = try? JSONDecoder().decode(Credential.self, from: data) else {
            throw ProviderError.keychain(errSecDecode)
        }
        return credential.endpoint == configuration.endpoint.absoluteString ? credential.key : nil
    }

    static func save(_ key: String, for configuration: AssistantProvider.Configuration) throws {
        let item = item(configuration.id)
        let data = try JSONEncoder().encode(Credential(endpoint: configuration.endpoint.absoluteString, key: key))
        let attributes = [kSecValueData as String: data]
        var status = SecItemUpdate(item as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var newItem = item
            newItem[kSecValueData as String] = data
            newItem[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(newItem as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ProviderError.keychain(status) }
    }

    static func remove(_ id: UUID) throws {
        let status = SecItemDelete(item(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ProviderError.keychain(status) }
    }
}

private enum ProviderError: LocalizedError {
    case notConfigured, invalidModel, invalidResponse, oversizedResponse
    case invalidName, invalidPagination, emptyCatalog, invalidStorage, profileUnavailable
    case http(Int), keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Set up a model in Settings → AI Assistant before sending a message."
        case .invalidStorage: return "Saved assistant models could not be read. The saved settings and credentials were left unchanged."
        case .profileUnavailable: return "This saved model changed or was removed. Close the editor and open it again."
        case .invalidName: return "Enter a model profile name without control characters."
        case .invalidPagination: return "The provider’s model list did not finish. Enter a model ID manually."
        case .emptyCatalog: return "No supported models were listed. Check access or enter a model ID manually."
        case .invalidModel: return "Enter the provider’s model ID."
        case .invalidResponse: return "The endpoint did not return an HTTP response."
        case .oversizedResponse: return "The provider response exceeded the assistant’s size limit."
        case .http(let code) where (300..<400).contains(code): return "The endpoint redirected the request (HTTP \(code)). Enter its final URL instead."
        case .http(let code): return "The provider returned HTTP \(code). Check the endpoint, model, API key and account limits."
        case .keychain(let status): return "Could not access the assistant credential in Keychain (\(status))."
        }
    }
}
