import Foundation

enum AssistantActionKind: String, Codable {
    case createReminder, updateReminder, completeReminder, createEvent, updateEvent
}

struct AssistantAction: Codable, Hashable {
    let kind: AssistantActionKind
    let targetID: String?
    let sourceID: String?
    let title: String?
    let due: String?
    let start: String?
    let end: String?
}

struct AssistantReply: Codable {
    let answer: String
    let actions: [AssistantAction]

    /// Codable ignores unknown keys. Reject them here: silently ignoring fields like
    /// recurrence or attendees would preview a different operation than was requested.
    static func parse(_ text: String) throws -> Self {
        let invalid = AssistantIssue("The model returned an unsupported proposal. Nothing was applied.")
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, content.utf8.count <= 64_000 else { throw invalid }
        var payload = content[...]
        if let lineEnd = payload.firstIndex(of: "\n"),
           ["```json", "```"].contains(payload[..<lineEnd].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()),
           payload.hasSuffix("\n```") {
            payload = payload[payload.index(after: lineEnd)...].dropLast(3)
            payload = payload.drop(while: \.isWhitespace)
        }
        // Text-only models can discuss plans. Never scrape actions out of prose
        // or repair malformed JSON: only a complete, validated proposal can be applied.
        guard payload.first == "{" || payload.first == "[" else {
            return Self(answer: content, actions: [])
        }
        let data = Data(payload.utf8)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["answer", "actions"],
              let actions = object["actions"] as? [[String: Any]], actions.count <= 24,
              actions.allSatisfy({ Set($0.keys).isSubset(of: ["kind", "targetID", "sourceID", "title", "due", "start", "end"]) }) else {
            throw invalid
        }
        let reply = try JSONDecoder().decode(Self.self, from: data)
        let targets = reply.actions.compactMap(\.targetID)
        guard !reply.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Set(targets).count == targets.count, Set(reply.actions).count == reply.actions.count else {
            throw AssistantIssue("The reply is empty or proposes the same change twice. Nothing was applied.")
        }
        return reply
    }
}

struct AssistantIssue: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
