import Foundation

/// Projects only human-readable text from an unfinished reply. The completed
/// wire payload is still the only input to AssistantReply.parse and EventKit review.
struct AssistantReplyPreview {
    private enum Mode { case prefix, plain, answer, finished }
    private var mode = Mode.prefix
    private var prefix = ""
    private var escape: [UInt8] = []

    mutating func append(_ delta: String) -> String {
        switch mode {
        case .finished: return ""
        case .plain: return delta
        case .answer: return readAnswer(delta.utf8)
        case .prefix: break
        }

        prefix += delta
        var text = prefix.drop(while: \.isWhitespace)
        if text.first == "`" {
            if let lineEnd = text.firstIndex(of: "\n") {
                let marker = text[..<lineEnd].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard marker == "```json" || marker == "```" else { return startPlain() }
                text = text[text.index(after: lineEnd)...].drop(while: \.isWhitespace)
            } else if "```json".hasPrefix(text.lowercased()) || text.lowercased().hasPrefix("```json") {
                return waitForPrefix()
            } else {
                return startPlain()
            }
        }
        guard let first = text.first else { return waitForPrefix() }
        switch first {
        case "[": mode = .finished
        case "{":
            text = text.dropFirst().drop(while: \.isWhitespace)
            let key = #""answer""#
            if text.count < key.count, key.hasPrefix(text) { return waitForPrefix() }
            guard text.hasPrefix(key) else { mode = .finished; return "" }
            text = text.dropFirst(key.count).drop(while: \.isWhitespace)
            guard let colon = text.first else { return waitForPrefix() }
            guard colon == ":" else { mode = .finished; return "" }
            text = text.dropFirst().drop(while: \.isWhitespace)
            guard let quote = text.first else { return waitForPrefix() }
            guard quote == "\"" else { mode = .finished; return "" }
            mode = .answer
            let answer = readAnswer(text.dropFirst().utf8)
            prefix = ""
            return answer
        default:
            return startPlain()
        }
        prefix = ""
        return ""
    }

    private mutating func startPlain() -> String {
        mode = .plain
        let text = prefix
        prefix = ""
        return text
    }

    private mutating func waitForPrefix() -> String {
        // Whitespace or an unfinished code fence must not buffer the whole reply.
        if prefix.utf8.count > 256 { prefix = ""; mode = .finished }
        return ""
    }

    private mutating func readAnswer(_ bytes: some Sequence<UInt8>) -> String {
        var output: [UInt8] = []
        for byte in bytes {
            if escape.isEmpty {
                if byte == 0x22 { mode = .finished; break } // closing quote
                if byte == 0x5c { escape.append(byte) }
                else if byte >= 0x20 { output.append(byte) }
                else { mode = .finished; break }
                continue
            }
            escape.append(byte)
            // A Unicode escape can be followed by a second one for a surrogate pair.
            if escape[1] == 0x75 {
                guard escape.count >= 6 else { continue }
                if escape.count < 12, Self.isHighSurrogate(escape[2..<6]) { continue }
            }
            var quoted: [UInt8] = [0x22]
            quoted += escape
            quoted.append(0x22)
            guard let decoded = try? JSONDecoder().decode(String.self, from: Data(quoted)) else {
                mode = .finished
                break
            }
            output += decoded.utf8
            escape.removeAll(keepingCapacity: true)
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func isHighSurrogate(_ digits: ArraySlice<UInt8>) -> Bool {
        let first = digits[digits.startIndex] | 0x20
        let second = digits[digits.startIndex + 1] | 0x20
        return first == 0x64 && ((0x38...0x39).contains(second) || (0x61...0x62).contains(second))
    }
}
