import CoreFoundation
import Darwin
import Foundation

enum AssistantAuthMode: String, Codable, CaseIterable {
    case automatic, bearer, customHeader, none

    var title: String {
        switch self {
        case .automatic: "Protocol default"
        case .bearer: "Bearer token"
        case .customHeader: "Custom header"
        case .none: "No authentication"
        }
    }
}

enum AssistantAPIFormat: String, Codable, CaseIterable {
    case chat, responses, anthropic, gemini

    var title: String {
        switch self {
        case .chat: "Chat Completions"
        case .responses: "Responses"
        case .anthropic: "Anthropic Messages"
        case .gemini: "Gemini generateContent"
        }
    }

    private var defaultBasePath: String { self == .gemini ? "/v1beta" : "/v1" }

    // Gemini has a model-specific RPC instead of a constant suffix.
    private var completionSuffix: String? {
        switch self {
        case .chat: "/chat/completions"
        case .responses: "/responses"
        case .anthropic: "/messages"
        case .gemini: nil
        }
    }

    func resolve(address: String, model: String, exactURL: Bool) throws -> URL {
        try Self.validate(model: model)
        var parts = try Self.components(address: address)
        var path = Self.trimmedPath(parts.percentEncodedPath)
        let fixedGeminiModel = try checkFixedGeminiModel(in: path, model: model)
        if !exactURL {
            if path.isEmpty { path = defaultBasePath }
            if let suffix = completionSuffix {
                if !path.hasSuffix(suffix) { path += suffix }
            } else if !fixedGeminiModel && !path.hasSuffix(":generateContent") {
                // The ID is one path parameter, never another path, query or RPC method.
                let id = Self.geminiID(model)
                guard !id.isEmpty, !id.split(whereSeparator: { $0 == "/" || $0 == "\\" }).contains(where: { $0 == "." || $0 == ".." }),
                      let segment = String(id).addingPercentEncoding(withAllowedCharacters: Self.pathSegmentCharacters) else {
                    throw WireError.modelPath
                }
                path += "/models/\(segment):generateContent"
            }
            parts.percentEncodedPath = path
        }
        guard let url = parts.url else { throw WireError.address }
        return url
    }

    private static func components(address: String) throws -> URLComponents {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: address, encodingInvalidCharacters: false) else { throw WireError.address }
        try validate(parts)
        return parts
    }

    private static func trimmedPath(_ path: String) -> String {
        var path = path
        while path.last == "/" { path.removeLast() }
        return path
    }

    private static func geminiID(_ model: String) -> Substring {
        model.hasPrefix("models/") ? model.dropFirst("models/".count) : model[...]
    }

    private static func geminiRoute(in path: String) -> (base: Substring, model: Substring)? {
        guard let slash = path.lastIndex(of: "/") else { return nil }
        let collection = path[..<slash]
        guard let baseEnd = collection.lastIndex(of: "/"),
              String(collection.suffix(from: collection.index(after: baseEnd))).removingPercentEncoding == "models",
              let rpc = String(path.suffix(from: path.index(after: slash))).removingPercentEncoding,
              rpc.hasSuffix(":generateContent") else { return nil }
        return (collection[..<baseEnd], rpc.dropLast(":generateContent".count))
    }

    // An exact native URL selects its model in the path, not in the JSON body.
    // Unknown exact gateway routes remain usable as manually configured.
    @discardableResult
    private func checkFixedGeminiModel(in path: String, model: String) throws -> Bool {
        guard self == .gemini, let route = Self.geminiRoute(in: path) else { return false }
        guard !route.model.isEmpty, route.model == Self.geminiID(model) else { throw WireError.fixedModel }
        return true
    }

    private static let pathSegmentCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func validate(model: String) throws {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              model.rangeOfCharacter(from: .controlCharacters) == nil else { throw WireError.model }
    }

    private static func validate(_ parts: URLComponents) throws {
        guard let scheme = parts.scheme?.lowercased(), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true,
              scheme == "https" || (scheme == "http" && isLoopback(host)) else { throw WireError.address }
        if parts.percentEncodedQuery != nil {
            guard let items = parts.queryItems, items.count == 1, items[0].name == "api-version",
                  let value = items[0].value, !value.isEmpty,
                  value.unicodeScalars.allSatisfy(pathSegmentCharacters.contains) else { throw WireError.query }
        }
    }

    private static func isLoopback(_ host: String) -> Bool {
        if host.lowercased() == "localhost" { return true }
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 { return UInt32(bigEndian: ipv4.s_addr) >> 24 == 127 }
        let address = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, address, &ipv6) == 1 else { return false }
        return withUnsafeBytes(of: ipv6) { $0.prefix(15).allSatisfy { $0 == 0 } && $0[15] == 1 }
    }

    func request(endpoint: URL, model: String, auth: AssistantAuthMode, header: String, key: String?, system: String,
                 user: String, stream: Bool = false) throws -> URLRequest {
        guard var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { throw WireError.address }
        try Self.validate(parts)
        try Self.validate(model: model)
        var target = endpoint
        var streaming = stream
        if self == .gemini {
            let path = parts.percentEncodedPath
            try checkFixedGeminiModel(in: Self.trimmedPath(path), model: model)
            // An arbitrary exact gateway route retains its configured URL and JSON body.
            if stream, let route = Self.geminiRoute(in: path), path[route.base.endIndex...].hasPrefix("/models/"),
               path.hasSuffix(":generateContent"), (try? Self.validateCatalogPath(path)) != nil {
                parts.percentEncodedPath = String(path.dropLast(":generateContent".count)) + ":streamGenerateContent"
                parts.percentEncodedQueryItems = (parts.percentEncodedQueryItems ?? []) + [URLQueryItem(name: "alt", value: "sse")]
                guard let url = parts.url else { throw WireError.address }
                target = url
            } else {
                streaming = false
            }
        }
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if streaming { request.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
        try setProtocolHeaders(on: &request, auth: auth, header: header, key: key)

        var body: [String: Any]
        switch self {
        case .chat:
            body = ["model": model, "messages": [["role": "system", "content": system], ["role": "user", "content": user]]]
        case .responses:
            body = ["model": model, "instructions": system, "input": user]
        case .anthropic:
            body = ["model": model, "max_tokens": 4096, "system": system, "messages": [["role": "user", "content": user]]]
        case .gemini:
            body = ["systemInstruction": ["parts": [["text": system]]], "contents": [["role": "user", "parts": [["text": user]]]]]
        }
        if streaming && self != .gemini { body["stream"] = true }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func setProtocolHeaders(on request: inout URLRequest, auth: AssistantAuthMode, header: String, key: String?) throws {
        if self == .anthropic { request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
        let field: String
        switch auth {
        case .automatic:
            switch self {
            case .chat, .responses: field = "Authorization"
            case .anthropic: field = "x-api-key"
            case .gemini: field = "x-goog-api-key"
            }
        case .bearer: field = "Authorization"
        case .customHeader:
            guard Self.validAuthHeader(header) else { throw WireError.header }
            field = header
        case .none: field = ""
        }
        if auth != .none {
            if let key, !key.isEmpty {
                guard key.utf8.allSatisfy({ (0x20...0x7E).contains($0) }), key.utf8.contains(where: { $0 != 0x20 }) else { throw WireError.key }
                let bearer = auth == .bearer || (auth == .automatic && field == "Authorization")
                request.setValue(bearer ? "Bearer \(key)" : key, forHTTPHeaderField: field)
            } else if auth != .automatic { throw WireError.missingKey }
        }
    }

    private static let headerCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$%&'*+-.^_`|~")
    private static let reservedHeaders: Set<String> = [
        "host", "connection", "keep-alive", "transfer-encoding", "te", "trailer", "upgrade", "expect", "via", "forwarded",
        "accept", "cookie", "cookie2", "origin", "referer", "user-agent", "date", "max-forwards", "anthropic-version",
        "x-http-method", "x-http-method-override", "x-method-override", "x-original-url", "x-rewrite-url"
    ]

    private static func validAuthHeader(_ header: String) -> Bool {
        guard !header.isEmpty, header.unicodeScalars.allSatisfy(headerCharacters.contains) else { return false }
        let name = header.lowercased()
        return !reservedHeaders.contains(name) && !name.hasPrefix("content-") && !name.hasPrefix("proxy-")
            && !name.hasPrefix("accept-") && !name.hasPrefix("sec-") && !name.hasPrefix("x-forwarded-")
    }

    private typealias Object = [String: Any]

    func text(from data: Data) throws -> String {
        guard let reply = (try? JSONSerialization.jsonObject(with: data)) as? Object else { throw WireError.envelope(title) }
        return try text(from: reply)
    }

    func text(from reply: [String: Any]) throws -> String {
        guard reply["error"] == nil || reply["error"] is NSNull else { throw WireError.provider }
        let result: String
        switch self {
        case .chat:
            guard let choice = (reply["choices"] as? [Object])?.first, let message = choice["message"] as? Object,
                  Self.absentOr(message["role"], "assistant") else { throw WireError.envelope(title) }
            guard Self.absentOr(choice["finish_reason"], "stop") else { throw WireError.incomplete }
            result = try Self.chatText(from: message)
        case .responses:
            guard Self.absentOr(reply["status"], "completed"), reply["incomplete_details"] == nil || reply["incomplete_details"] is NSNull else {
                throw WireError.incomplete
            }
            if let output = reply["output"] as? [Object] {
                var messages: [String] = []
                // Commentary is an intermediate update, not the model's final answer.
                for item in output where Self.isFinalResponseMessage(item) {
                    guard Self.absentOr(item["status"], "completed") else { throw WireError.incomplete }
                    if (item["content"] as? [Object])?.contains(where: { $0["type"] as? String == "refusal" }) == true {
                        throw WireError.incomplete
                    }
                    let text = Self.textBlocks(item["content"], type: "output_text")
                    if !text.isEmpty { messages.append(text) }
                }
                result = messages.joined(separator: "\n")
            } else if reply["output"] == nil, let text = reply["output_text"] as? String {
                result = text
            } else { throw WireError.envelope(title) }
        case .anthropic:
            guard Self.absentOr(reply["type"], "message"), Self.absentOr(reply["role"], "assistant") else { throw WireError.envelope(title) }
            guard Self.absentOr(reply["stop_reason"], "end_turn", "stop_sequence") else { throw WireError.incomplete }
            result = Self.textBlocks(reply["content"], type: "text")
        case .gemini:
            try Self.checkGeminiBlock(reply)
            guard let candidate = (reply["candidates"] as? [Object])?.first else { throw WireError.envelope(title) }
            guard Self.absentOr(candidate["finishReason"], "STOP") else { throw WireError.incomplete }
            guard let content = candidate["content"] as? Object, Self.absentOr(content["role"], "model"),
                  let parts = content["parts"] as? [Object] else { throw WireError.envelope(title) }
            result = Self.geminiText(from: parts)
        }
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WireError.empty(title) }
        return result
    }

    static func isFinalResponseMessage(_ item: [String: Any]) -> Bool {
        item["type"] as? String == "message" && absentOr(item["role"], "assistant")
            && (item["phase"] is NSNull || absentOr(item["phase"], "final_answer"))
    }

    static func chatText(from message: [String: Any]) throws -> String {
        let refusal = message["refusal"]
        guard refusal == nil || refusal is NSNull || refusal as? String == "",
              (message["content"] as? [Object])?.contains(where: { $0["type"] as? String == "refusal" }) != true else {
            throw WireError.incomplete
        }
        if let calls = message["tool_calls"], !(calls is NSNull), (calls as? [Any])?.isEmpty != true {
            throw WireError.incomplete
        }
        if let call = message["function_call"], !(call is NSNull) { throw WireError.incomplete }
        return message["content"] as? String ?? textBlocks(message["content"], type: "text")
    }

    static func checkGeminiBlock(_ reply: [String: Any]) throws {
        if (reply["promptFeedback"] as? Object)?["blockReason"] != nil { throw WireError.incomplete }
    }

    static func geminiText(from parts: [[String: Any]]) -> String {
        parts.compactMap { part -> String? in
            guard part["thought"] == nil || part["thought"] as? Bool == false else { return nil }
            return part["text"] as? String
        }.joined()
    }

    // Compatible servers sometimes omit optional metadata. When present, it must describe a finished answer.
    private static func absentOr(_ value: Any?, _ expected: String, _ alternative: String? = nil) -> Bool {
        guard let value else { return true }
        guard let string = value as? String else { return false }
        return string == expected || string == alternative
    }

    private static func textBlocks(_ value: Any?, type: String) -> String {
        guard let blocks = value as? [Object] else { return "" }
        return blocks.compactMap { $0["type"] as? String == type ? $0["text"] as? String : nil }.joined()
    }
}

extension AssistantAPIFormat {
    func catalogRoutes(address: String, exactURL: Bool) throws -> [(url: URL, format: Self)] {
        var parts = try Self.components(address: address)
        var path = Self.trimmedPath(parts.percentEncodedPath)
        try Self.validateCatalogPath(path)
        if let suffix = completionSuffix, path.hasSuffix(suffix) {
            path.removeLast(suffix.count)
        } else if self == .gemini, let route = Self.geminiRoute(in: path) {
            guard !route.model.isEmpty else { throw WireError.catalogRoute }
            path = String(route.base)
        } else {
            // Only a *base* authorizes appending a new route. Never walk up an
            // arbitrary exact URL (which may be a credential-scoped gateway).
            guard !exactURL, !(self == .gemini && path.hasSuffix(":generateContent")) else { throw WireError.catalogRoute }
            if path.isEmpty { path = defaultBasePath }
        }
        parts.percentEncodedPath = path + "/models"
        guard let primary = parts.url else { throw WireError.address }
        var routes: [(url: URL, format: Self)] = [(primary, self)]
        // Anthropic-compatible mounts can share their provider's OpenAI catalog.
        // Strip only the known mount suffix, keeping any gateway prefix and origin.
        if self == .anthropic,
           let mount = ["/anthropic/v1", "/anthropic"].first(where: { path.hasSuffix($0) }) {
            let base = path.dropLast(mount.count)
            for suffix in ["/v1/models", "/models"] {
                parts.percentEncodedPath = base + suffix
                guard let url = parts.url else { throw WireError.address }
                routes.append((url, .chat))
            }
        }
        return routes
    }

    // A path that depends on a server normalizing separators or traversal has
    // no unambiguous sibling. It can still be configured manually as an exact URL.
    private static func validateCatalogPath(_ path: String) throws {
        guard !path.contains("//") else { throw WireError.catalogRoute }
        for component in path.split(separator: "/") {
            guard let decoded = String(component).removingPercentEncoding,
                  decoded != ".", decoded != "..", !decoded.contains("/"), !decoded.contains("\\"),
                  !decoded.contains("%"), decoded.rangeOfCharacter(from: .controlCharacters) == nil else { throw WireError.catalogRoute }
        }
    }

    func catalogRequest(url: URL, auth: AssistantAuthMode, header: String, key: String?, cursor: String?) throws -> URLRequest {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw WireError.address }
        try Self.validate(parts)
        let path = parts.percentEncodedPath
        try Self.validateCatalogPath(path)
        guard path.hasSuffix("/models") else { throw WireError.catalogRoute }
        if let cursor {
            let name: String
            switch self {
            case .anthropic: name = "after_id"
            case .gemini: name = "pageToken"
            case .chat, .responses: throw WireError.catalogPage(title)
            }
            // The server controls the cursor, never the destination. Encode even
            // '+' so form-style query parsers deliver the original opaque token.
            guard Self.validCursor(cursor),
                  let value = cursor.addingPercentEncoding(withAllowedCharacters: Self.pathSegmentCharacters) else {
                throw WireError.catalogPage(title)
            }
            var items = parts.percentEncodedQueryItems ?? []
            items.append(URLQueryItem(name: name, value: value))
            parts.percentEncodedQueryItems = items
        }
        guard let target = parts.url else { throw WireError.address }
        var request = URLRequest(url: target)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try setProtocolHeaders(on: &request, auth: auth, header: header, key: key)
        return request
    }

    private static func validCursor(_ cursor: String) -> Bool {
        !cursor.isEmpty && cursor.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private static func catalogID(_ value: Any?) -> String? {
        guard let id = value as? String, !id.isEmpty, id == id.trimmingCharacters(in: .whitespacesAndNewlines),
              id.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return id
    }

    func catalogPage(from data: Data) throws -> (ids: [String], next: String?) {
        guard let page = (try? JSONSerialization.jsonObject(with: data)) as? Object else { throw WireError.catalogPage(title) }
        guard page["error"] == nil || page["error"] is NSNull else { throw WireError.provider }
        guard let rows = page[self == .gemini ? "models" : "data"] as? [Object] else { throw WireError.catalogPage(title) }
        var next: String?
        switch self {
        case .chat, .responses:
            break
        case .anthropic:
            // Some compatible gateways return a single data array without pagination metadata.
            if let flag = page["has_more"] {
                guard let more = flag as? NSNumber, CFGetTypeID(more) == CFBooleanGetTypeID() else { throw WireError.catalogPage(title) }
                if more.boolValue {
                    guard let cursor = page["last_id"] as? String, Self.validCursor(cursor) else { throw WireError.catalogPage(title) }
                    next = cursor
                }
            }
        case .gemini:
            if let value = page["nextPageToken"] {
                guard let cursor = value as? String, cursor.isEmpty || Self.validCursor(cursor) else { throw WireError.catalogPage(title) }
                if !cursor.isEmpty { next = cursor }
            }
            let ids = rows.compactMap { row -> String? in
                guard let methods = row["supportedGenerationMethods"] as? [String], methods.contains("generateContent"),
                      let name = row["name"] as? String,
                      let id = Self.catalogID(String(Self.geminiID(name))),
                      !id.contains("/"), !id.contains("\\"), id != ".", id != ".." else { return nil }
                return id
            }
            return (ids, next)
        }
        return (rows.compactMap { Self.catalogID($0["id"]) }, next)
    }
}

enum WireError: LocalizedError {
    case address, query, model, modelPath, fixedModel, catalogRoute, header, key, missingKey, provider, incomplete
    case envelope(String), empty(String), catalogPage(String)

    var errorDescription: String? {
        switch self {
        case .address: "Enter an HTTPS URL without embedded credentials or a fragment. HTTP is allowed only for loopback addresses."
        case .query: "Only an api-version query is supported. Put API credentials in the authentication field, not in the URL."
        case .model: "Enter a nonempty model ID without control characters."
        case .modelPath: "Enter a Gemini model ID without relative path components."
        case .fixedModel: "This Gemini URL selects a specific model. Use its matching model ID, or enter the base URL to select a different one."
        case .catalogRoute: "Cannot determine a safe model-list URL from this route. Use the protocol base URL or enter the model ID manually."
        case .catalogPage(let title): "The server did not return a valid \(title) model list. Check the protocol or enter the model ID manually."
        case .header: "Enter a valid authentication header name, not a reserved HTTP or protocol header."
        case .key: "The API credential must contain only printable ASCII characters."
        case .missingKey: "Enter an API credential or select No authentication."
        case .provider: "The API returned an error. Check the model ID, credentials and account limits."
        case .incomplete: "The model did not finish a usable answer. It may have reached a token limit, requested a tool or blocked the output."
        case .envelope(let title): "The server did not return a \(title) reply. Check the API format and URL."
        case .empty(let title): "The \(title) reply contained no final text from the model."
        }
    }
}
