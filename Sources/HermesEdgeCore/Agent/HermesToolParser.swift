import Foundation

/// Parsed chunk from streaming LLM output containing either assistant prose or an intercepted Hermes tool call.
public enum StreamedChunk: Equatable, Sendable {
    case token(String)
    case toolCall(PendingToolCall)
}

/// Real-time stream interceptor that extracts Hermes `<tool_call>{"name": ..., "arguments": ...}</tool_call>` blocks.
public final class HermesToolParser: @unchecked Sendable {
    private var buffer: String = ""
    private var isBufferingToolCall: Bool = false
    private let toolCallStartTag = "<tool_call>"
    private let toolCallEndTag = "</tool_call>"

    public init() {}

    public func reset() {
        buffer = ""
        isBufferingToolCall = false
    }

    /// Feeds an incoming token string and yields parsed events.
    public func feed(token: String) -> [StreamedChunk] {
        buffer.append(token)
        var chunks: [StreamedChunk] = []

        if !isBufferingToolCall {
            if let startRange = buffer.range(of: toolCallStartTag) {
                // Yield any text preceding <tool_call>
                let preText = String(buffer[..<startRange.lowerBound])
                if !preText.isEmpty {
                    chunks.append(.token(preText))
                }
                // Keep the <tool_call>... in buffer
                buffer = String(buffer[startRange.lowerBound...])
                isBufferingToolCall = true
            } else {
                // If the buffer might end with a partial tag like "<tool", wait before yielding
                let potentialTagPrefixes = ["<", "<t", "<to", "<too", "<tool", "<tool_", "<tool_c", "<tool_ca", "<tool_cal", "<tool_call"]
                let hasPartialMatch = potentialTagPrefixes.contains { buffer.hasSuffix($0) }
                
                if !hasPartialMatch {
                    chunks.append(.token(buffer))
                    buffer = ""
                }
            }
        }

        if isBufferingToolCall {
            if let endRange = buffer.range(of: toolCallEndTag) {
                // We have the complete <tool_call>...</tool_call> block
                let fullBlock = String(buffer[..<endRange.upperBound])
                buffer = String(buffer[endRange.upperBound...])
                isBufferingToolCall = false

                if let toolCall = parseToolCallBlock(fullBlock) {
                    chunks.append(.toolCall(toolCall))
                }

                // If remaining buffer has text, recursively process it
                if !buffer.isEmpty {
                    chunks.append(contentsOf: feed(token: ""))
                }
            }
        }

        return chunks
    }

    /// Finalizes stream at EOF, flushing any remaining buffered text.
    public func flush() -> [StreamedChunk] {
        defer { reset() }
        if !buffer.isEmpty && !isBufferingToolCall {
            let remaining = buffer
            buffer = ""
            return [.token(remaining)]
        }
        return []
    }

    /// Formats Hermes system prompt tool schemas into XML definition blocks.
    public static func formatToolPrompt(schemas: [[String: Any]]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: schemas, options: [.prettyPrinted]),
              let jsonStr = String(data: data, encoding: .utf8) else {
            return ""
        }

        return """
        You have access to the following functions. To call a function, respond with a <tool_call> XML block containing the function name and arguments in JSON format:
        <tools>
        \(jsonStr)
        </tools>
        """
    }

    /// Formats tool execution result back into Hermes prompt format.
    public static func formatToolResponse(toolName: String, output: String) -> String {
        return """
        <tool_response>
        {"name": "\(toolName)", "content": \(output)}
        </tool_response>
        """
    }

    private func parseToolCallBlock(_ block: String) -> PendingToolCall? {
        guard let start = block.range(of: toolCallStartTag)?.upperBound,
              let end = block.range(of: toolCallEndTag)?.lowerBound else {
            return nil
        }
        let jsonContent = block[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonContent.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = dict["name"] as? String else {
            return nil
        }

        var argsString = "{}"
        if let argsDict = dict["arguments"] as? [String: Any],
           let argsData = try? JSONSerialization.data(withJSONObject: argsDict),
           let str = String(data: argsData, encoding: .utf8) {
            argsString = str
        } else if let rawArgs = dict["arguments"] as? String {
            argsString = rawArgs
        }

        let callId = dict["id"] as? String ?? "call_\(UUID().uuidString.prefix(8))"
        return PendingToolCall(id: callId, name: name, argumentsJson: argsString)
    }
}
