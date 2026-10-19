import Foundation
import AppIntents

/// AppIntent enabling completely offline, hands-free voice interaction via Siri and the iPhone 15 Pro Action Button.
/// On iOS 17/18 with A17 Pro, Siri speech-to-text and intent resolution run entirely on-device without internet.
@available(iOS 16.0, macOS 13.0, *)
public struct AskHermesIntent: AppIntent {
    public static let title: LocalizedStringResource = "Ask Hermes"
    public static let description = IntentDescription("Speak to your offline on-device AI assistant to answer questions or automate tasks.")

    // Configured to run in the background without launching the full app UI
    public static let openAppWhenRun: Bool = false

    @Parameter(title: "Prompt", description: "What would you like Hermes to do?")
    public var prompt: String

    public init() {}

    public init(prompt: String) {
        self.prompt = prompt
    }

    public func perform() async throws -> some ProvidesDialog {
        let conversationId = "siri-session"
        let userMessage = MessageEnvelope(
            conversationId: conversationId,
            channel: .siriVoice,
            role: .user,
            content: prompt
        )

        // Initialize local agent and tool registry
        let tools = ToolRegistry()
        await tools.register(tool: EventKitTool())
        await tools.register(tool: ShortcutsTool())
        await tools.register(tool: URLSchemeTool())

        let store = PersistBeforeExecuteStore()
        let memory = MemoryManager()
        let engine = GemmaMetalEngine()

        let agent = AgentStateMachine(
            toolRegistry: tools,
            persistenceStore: store,
            memoryManager: memory,
            inferenceEngine: engine
        )

        // Execute on-device turn completely offline
        let result = try await agent.processTurn(
            conversationId: conversationId,
            userMessage: userMessage
        ) { _ in }

        return .result(
            dialog: IntentDialog(stringLiteral: result.content)
        )
    }
}

/// Provides preset spoken trigger phrases for Siri so users can say:
/// "Hey Siri, ask Hermes to create a reminder" or "Hey Siri, run with Hermes"
@available(iOS 16.0, macOS 13.0, *)
public struct HermesShortcutsProvider: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskHermesIntent(),
            phrases: [
                "Ask \(.applicationName) \(\.$prompt)",
                "Tell \(.applicationName) to \(\.$prompt)",
                "Run \(\.$prompt) with \(.applicationName)"
            ],
            shortTitle: "Ask Hermes",
            systemImageName: "sparkles"
        )
    }
}
