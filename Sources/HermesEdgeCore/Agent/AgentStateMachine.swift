import Foundation

/// The cognitive loop orchestrator porting Hermes's `run_tool_round` state machine into Swift.
public actor AgentStateMachine {
    private let toolRegistry: ToolRegistry
    private let persistenceStore: PersistBeforeExecuteStore
    private let memoryManager: MemoryManager
    private let inferenceEngine: any InferenceEngine
    private let maxIterations: Int

    public init(
        toolRegistry: ToolRegistry,
        persistenceStore: PersistBeforeExecuteStore,
        memoryManager: MemoryManager,
        inferenceEngine: any InferenceEngine,
        maxIterations: Int = 5
    ) {
        self.toolRegistry = toolRegistry
        self.persistenceStore = persistenceStore
        self.memoryManager = memoryManager
        self.inferenceEngine = inferenceEngine
        self.maxIterations = maxIterations
    }

    /// Runs a multi-step conversation turn until the model completes or requests user input.
    public func processTurn(
        conversationId: String,
        userMessage: MessageEnvelope,
        onUpdate: @Sendable (AgentStreamEvent) -> Void
    ) async throws -> MessageEnvelope {
        // 1. Record incoming user message
        try await persistenceStore.recordPreExecution(conversationId: conversationId, assistantMessage: userMessage)
        onUpdate(.status("Thinking..."))

        var iteration = 0
        while iteration < maxIterations {
            iteration += 1

            // 2. Fetch history and apply Hermes micro-compaction
            var history = await persistenceStore.history(for: conversationId)
            history = await memoryManager.compactHistory(messages: history)

            let toolSchemas = await toolRegistry.allSchemas()

            // 3. Invoke Edge LLM with tool schemas
            let response: EngineResponse
            do {
                response = try await inferenceEngine.generate(messages: history, tools: toolSchemas)
            } catch let signal as ToolBoundarySignal {
                // Tool intercepted via OpenClaw ToolBoundary pattern
                response = EngineResponse(text: "", toolCalls: signal.toolCalls)
            }

            // 4. If the model generated direct text with no tool calls, finish the turn
            guard let calls = response.toolCalls, !calls.isEmpty else {
                let finalAssistantMsg = MessageEnvelope(
                    conversationId: conversationId,
                    role: .assistant,
                    content: response.text
                )
                try await persistenceStore.recordPreExecution(conversationId: conversationId, assistantMessage: finalAssistantMsg)
                onUpdate(.completed(finalAssistantMsg))
                return finalAssistantMsg
            }

            // 5. Model wants to call tools: Apply PERSIST-BEFORE-EXECUTE invariant
            let toolCallMessage = MessageEnvelope(
                conversationId: conversationId,
                role: .assistant,
                content: response.text,
                toolCalls: calls
            )
            try await persistenceStore.recordPreExecution(conversationId: conversationId, assistantMessage: toolCallMessage)

            // 6. Execute each tool in sequence
            for call in calls {
                onUpdate(.toolExecuting(name: call.name, args: call.argumentsJson))
                let result = try await toolRegistry.executeTool(call: call)
                await persistenceStore.recordToolResult(conversationId: conversationId, toolCallId: call.id, output: result)
                onUpdate(.toolResult(name: call.name, output: result))
            }

            // Loop continues: next iteration feeds tool outputs back to LLM for synthesis
        }

        let fallbackMsg = MessageEnvelope(
            conversationId: conversationId,
            role: .assistant,
            content: "Task exceeded max reasoning steps. Paused for review."
        )
        return fallbackMsg
    }
}

public enum AgentStreamEvent: Sendable {
    case status(String)
    case token(String)
    case toolExecuting(name: String, args: String)
    case toolResult(name: String, output: String)
    case completed(MessageEnvelope)
    case error(String)
}
