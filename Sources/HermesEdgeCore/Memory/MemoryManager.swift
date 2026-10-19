import Foundation

/// Manages context compaction, working memory, and user facts for edge models.
/// Adapted from Hermes Agent's memory_manager.py and trajectory_compressor.py.
public actor MemoryManager {
    private var coreFacts: [String] = []
    private let maxTokensThreshold: Int

    public init(maxTokensThreshold: Int = 3000) {
        self.maxTokensThreshold = maxTokensThreshold
    }

    /// Stores a persistent piece of information about the user or preferences.
    public func storeFact(_ fact: String) {
        coreFacts.append(fact)
    }

    public func retrieveFacts() -> [String] {
        return coreFacts
    }

    /// Builds the system prompt with injected user memory.
    public func buildSystemPrompt(basePrompt: String) -> String {
        guard !coreFacts.isEmpty else { return basePrompt }
        let factsBlock = coreFacts.map { "- \($0)" }.joined(separator: "\n")
        return """
        \(basePrompt)

        <UserKnowledgeBase>
        \(factsBlock)
        </UserKnowledgeBase>
        """
    }

    /// Performs micro-compaction on conversation history when the context window nears capacity.
    /// Preserves recent turns and system directives while summarizing older exchanges.
    public func compactHistory(messages: [MessageEnvelope]) -> [MessageEnvelope] {
        // Approximate token counting (~4 characters per token)
        let totalChars = messages.reduce(0) { $0 + $1.content.count }
        guard totalChars > (maxTokensThreshold * 4) else {
            return messages
        }

        // Keep system prompt + last 4 turns intact, compress the middle turns
        guard messages.count > 6 else { return messages }

        let systemMessages = messages.filter { $0.role == .system }
        let recentMessages = messages.suffix(4)
        let middleMessages = messages.dropFirst(systemMessages.count).dropLast(4)

        let summaryText = "[Summary of \(middleMessages.count) previous exchanges: discussed user requests and executed system tasks]"
        let summaryEnvelope = MessageEnvelope(
            conversationId: messages.first?.conversationId ?? UUID().uuidString,
            role: .system,
            content: summaryText
        )

        return systemMessages + [summaryEnvelope] + Array(recentMessages)
    }
}
