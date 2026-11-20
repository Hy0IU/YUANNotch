import Foundation

@MainActor
enum AssistantStream {
    static func complete(session: URLSession, request: URLRequest, format: AssistantAPIFormat,
                         onDelta: @MainActor (String) -> Void) async throws -> String {
        try await receive(session: session, request: request, format: format, onDelta: onDelta)
    }

    private nonisolated static func receive(session: URLSession, request: URLRequest, format: AssistantAPIFormat,
                                            onDelta: @MainActor (String) -> Void) async throws -> String {
        try Task.checkCancellation()
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw StreamError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw StreamError.http(http.statusCode) }

        let isSSE = http.mimeType?.lowercased() == "text/event-stream"
        let limit = isSSE ? streamByteLimit : replyByteLimit
        guard response.expectedContentLength <= limit else { throw StreamError.oversized }
        if !isSSE {
            // A gateway may ignore the stream flag. Validate its JSON without reissuing the POST.
            var data = Data()
            if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
            for try await byte in bytes {
                guard data.count < limit else { throw StreamError.oversized }
                data.append(byte)
                if data.count.isMultiple(of: 4096) { try Task.checkCancellation() }
            }
            try Task.checkCancellation()
            return try format.text(from: data)
        }

        var remaining = limit
        var framing = SSEFraming()
        var reply = StreamReply(format: format)
        for try await byte in bytes {
            guard remaining > 0 else { throw StreamError.oversized }
            remaining -= 1
            if remaining.isMultiple(of: 4096) { try Task.checkCancellation() }
            guard let event = try framing.consume(byte) else { continue }
            let update = try reply.consume(event)
            try Task.checkCancellation()
            switch update {
            case .delta(let text): await onDelta(text)
            case .completed(let text): return text
            case nil: break
            }
        }
        try Task.checkCancellation()
        guard !framing.hasUnfinishedEvent else { throw WireError.incomplete }
        return try reply.endOfStream()
    }
}

private let replyByteLimit = 256 * 1024
private let streamByteLimit = 4 * 1024 * 1024

private struct SSEEvent {
    let name: String?
    let data: Data
}

private struct SSEFraming {
    private var line = Data()
    private var data = Data()
    private var name: String?
    private var firstLine = true
    private var skipLF = false
    private var hasData = false

    var hasUnfinishedEvent: Bool { !line.isEmpty || hasData || name != nil }

    mutating func consume(_ byte: UInt8) throws -> SSEEvent? {
        if skipLF {
            skipLF = false
            if byte == 0x0A { return nil }
        }
        guard byte == 0x0D || byte == 0x0A else {
            line.append(byte)
            return nil
        }
        skipLF = byte == 0x0D
        defer { line.removeAll(keepingCapacity: true) }
        if firstLine {
            firstLine = false
            if line.starts(with: [0xEF, 0xBB, 0xBF]) { line.removeFirst(3) }
        }
        guard let text = String(data: line, encoding: .utf8) else { throw StreamError.framing }
        if text.isEmpty {
            defer { name = nil }
            guard hasData else { return nil }
            let event = SSEEvent(name: name, data: data)
            data = Data()
            hasData = false
            return event
        }

        // Field separators and the optional leading space are single bytes, not graphemes.
        let raw = text.utf8
        let colon = raw.firstIndex(of: 0x3A) ?? raw.endIndex
        let field = raw[..<colon]
        var value = colon == raw.endIndex ? raw[colon...] : raw[raw.index(after: colon)...]
        if value.first == 0x20 { value = value.dropFirst() }
        if field.elementsEqual("data".utf8) {
            if hasData { data.append(0x0A) }
            data.append(contentsOf: value)
            hasData = true
        } else if field.elementsEqual("event".utf8) {
            name = value.isEmpty ? nil : String(decoding: value, as: UTF8.self)
        }
        return nil
    }
}

private struct StreamReply {
    enum Update {
        case delta(String), completed(String)
    }

    private typealias Object = [String: Any]
    private let format: AssistantAPIFormat
    private var text = ""
    private var textBytes = 0
    private var sawFinish = false
    private var responseMessages: [Int: String] = [:]
    private var anthropicTextBlocks: Set<Int> = []

    init(format: AssistantAPIFormat) { self.format = format }

    mutating func consume(_ event: SSEEvent) throws -> Update? {
        if event.name == "error" { throw WireError.provider }
        if event.data.elementsEqual("[DONE]".utf8) {
            // Compatible Chat servers may send only the sentinel, with no finish_reason.
            guard format == .chat || (format == .gemini && sawFinish) else { throw WireError.incomplete }
            return .completed(try finalText())
        }
        if event.data.isEmpty && event.name == "ping" { return nil }
        guard let object = (try? JSONSerialization.jsonObject(with: event.data)) as? Object else { throw StreamError.framing }
        let type = object["type"] as? String
        if type == "error" || (object["error"] != nil && !(object["error"] is NSNull)) { throw WireError.provider }
        switch format {
        case .chat: return try chat(object)
        case .responses: return try responses(object, type: Self.messageType(event.name, type))
        case .anthropic: return try anthropic(object, type: Self.messageType(event.name, type))
        case .gemini: return try gemini(object)
        }
    }

    func endOfStream() throws -> String {
        // Gemini uses a finishReason rather than an end sentinel. Some Chat gateways do too.
        guard sawFinish, format == .chat || format == .gemini else { throw WireError.incomplete }
        return try finalText()
    }

    private mutating func chat(_ object: Object) throws -> Update? {
        guard let choice = Self.primaryChoice(object["choices"]) else { return nil }
        let wasFinished = sawFinish
        try recordFinish(choice["finish_reason"], "stop")
        guard let delta = choice["delta"] as? Object else { return nil }
        if let role = delta["role"], !(role is NSNull), role as? String != "assistant" { throw StreamError.framing }
        return try publish(AssistantAPIFormat.chatText(from: delta), afterFinish: wasFinished)
    }

    private mutating func responses(_ object: Object, type: String?) throws -> Update? {
        switch type {
        case "response.output_item.added":
            if let index = object["output_index"] as? Int, let item = object["item"] as? Object {
                responseMessages[index] = AssistantAPIFormat.isFinalResponseMessage(item) ? item["id"] as? String ?? "" : nil
            }
        case "response.output_item.done":
            if let index = object["output_index"] as? Int { responseMessages[index] = nil }
        case "response.output_text.delta":
            if let index = object["output_index"] as? Int, let id = responseMessages[index],
               id.isEmpty || id == object["item_id"] as? String, let delta = object["delta"] as? String {
                return try publish(delta)
            }
        case "response.completed":
            guard let response = object["response"] as? Object else { throw StreamError.framing }
            // The final envelope is canonical: deltas can include provisional messages or miss whole output items.
            let answer = try format.text(from: response)
            guard answer.utf8.count <= replyByteLimit else { throw StreamError.oversized }
            return .completed(answer)
        case "response.failed", "response.incomplete", "response.cancelled": throw WireError.incomplete
        default: break
        }
        return nil
    }

    private mutating func anthropic(_ object: Object, type: String?) throws -> Update? {
        switch type {
        case "content_block_start":
            if let index = object["index"] as? Int, let block = object["content_block"] as? Object {
                if block["type"] as? String == "text" {
                    anthropicTextBlocks.insert(index)
                    return try publish(block["text"] as? String ?? "", afterFinish: sawFinish)
                }
                anthropicTextBlocks.remove(index)
            }
        case "content_block_delta":
            if let index = object["index"] as? Int, anthropicTextBlocks.contains(index), let delta = object["delta"] as? Object,
               delta["type"] as? String == "text_delta", let content = delta["text"] as? String {
                return try publish(content, afterFinish: sawFinish)
            }
        case "content_block_stop":
            if let index = object["index"] as? Int { anthropicTextBlocks.remove(index) }
        case "message_delta":
            try recordFinish((object["delta"] as? Object)?["stop_reason"], "end_turn", "stop_sequence")
        case "message_stop":
            guard sawFinish else { throw WireError.incomplete }
            return .completed(try finalText())
        default: break
        }
        return nil
    }

    private mutating func gemini(_ object: Object) throws -> Update? {
        try AssistantAPIFormat.checkGeminiBlock(object)
        guard let candidate = Self.primaryChoice(object["candidates"]) else { return nil }
        let wasFinished = sawFinish
        if candidate["finishReason"] as? String != "FINISH_REASON_UNSPECIFIED" {
            try recordFinish(candidate["finishReason"], "STOP")
        }
        guard let content = candidate["content"] as? Object else { return nil }
        if let role = content["role"], !(role is NSNull), role as? String != "model" { throw StreamError.framing }
        guard let parts = content["parts"] as? [Object] else { return nil }
        return try publish(AssistantAPIFormat.geminiText(from: parts), afterFinish: wasFinished)
    }

    private static func primaryChoice(_ value: Any?) -> Object? {
        guard let choices = value as? [Object], let first = choices.first else { return nil }
        if first["index"] == nil || first["index"] is NSNull { return first }
        return choices.first { $0["index"] as? Int == 0 }
    }

    private static func messageType(_ name: String?, _ type: String?) throws -> String? {
        guard let name, name != "message" else { return type }
        guard type == nil || type == name else { throw StreamError.framing }
        return name
    }

    private mutating func recordFinish(_ value: Any?, _ success: String, _ alternative: String? = nil) throws {
        guard let value, !(value is NSNull) else { return }
        guard let reason = value as? String, reason == success || reason == alternative else { throw WireError.incomplete }
        sawFinish = true
    }

    private mutating func publish(_ delta: String, afterFinish: Bool = false) throws -> Update? {
        guard !delta.isEmpty else { return nil }
        guard !afterFinish else { throw StreamError.framing }
        textBytes += delta.utf8.count
        guard textBytes <= replyByteLimit else { throw StreamError.oversized }
        if format != .responses { text.append(contentsOf: delta) }
        return .delta(delta)
    }

    private func finalText() throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WireError.empty(format.title) }
        return text
    }
}

private enum StreamError: LocalizedError {
    case invalidResponse, http(Int), oversized, framing

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The endpoint did not return an HTTP response."
        case .http(let code) where (300..<400).contains(code): "The endpoint redirected the request (HTTP \(code)). Enter its final URL instead."
        case .http(let code): "The provider returned HTTP \(code). Check the endpoint, model, API key and account limits."
        case .oversized: "The provider response exceeded the assistant’s size limit."
        case .framing: "The provider returned a malformed event stream. Check the API format and URL."
        }
    }
}
