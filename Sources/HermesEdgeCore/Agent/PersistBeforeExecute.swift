import Foundation

/// Durable write-ahead state store guaranteeing Hermes's "Persist-Before-Execute" invariant.
/// On iOS, if Jetsam abruptly terminates the app during tool execution, state remains consistent.
public actor PersistBeforeExecuteStore {
    private var persistedMessages: [String: [MessageEnvelope]] = [:]
    private var ongoingToolExecutions: [String: PendingToolCall] = [:]

    public init() {}

    /// Persists the model's tool-call intention BEFORE any side-effect or framework call occurs.
    public func recordPreExecution(conversationId: String, assistantMessage: MessageEnvelope) throws {
        var thread = persistedMessages[conversationId] ?? []
        thread.append(assistantMessage)
        persistedMessages[conversationId] = thread

        if let calls = assistantMessage.toolCalls {
            for call in calls {
                ongoingToolExecutions[call.id] = call
            }
        }
    }

    /// Records the tool execution output back to the conversation thread.
    public func recordToolResult(conversationId: String, toolCallId: String, output: String) {
        ongoingToolExecutions.removeValue(forKey: toolCallId)
        
        let toolMessage = MessageEnvelope(
            conversationId: conversationId,
            role: .tool,
            content: output,
            toolResultId: toolCallId
        )
        var thread = persistedMessages[conversationId] ?? []
        thread.append(toolMessage)
        persistedMessages[conversationId] = thread
    }

    /// Fetches all active messages for an ongoing conversation.
    public func history(for conversationId: String) -> [MessageEnvelope] {
        return persistedMessages[conversationId] ?? []
    }

    /// Checks if a previous tool call was left incomplete due to a background Jetsam crash.
    public func unacknowledgedToolCalls() -> [PendingToolCall] {
        return Array(ongoingToolExecutions.values)
    }
}
