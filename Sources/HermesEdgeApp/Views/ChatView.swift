import SwiftUI

public struct ChatView: View {
    @StateObject private var modelManager = ModelManager.shared
    @State private var messages: [MessageEnvelope] = []
    @State private var inputText: String = ""
    @State private var currentStatus: String = "Ready"
    @State private var isProcessing: Bool = false
    @State private var streamingText: String = ""

    private let agent: AgentStateMachine
    private let conversationId = "default-session"

    public init() {
        let tools = ToolRegistry()
        Task {
            await tools.register(tool: EventKitTool())
            await tools.register(tool: ShortcutsTool())
            await tools.register(tool: URLSchemeTool())
        }

        let store = PersistBeforeExecuteStore()
        let memory = MemoryManager()
        let engine = GemmaMetalEngine()

        BackgroundManager.shared.configure(engine: engine)

        self.agent = AgentStateMachine(
            toolRegistry: tools,
            persistenceStore: store,
            memoryManager: memory,
            inferenceEngine: engine
        )
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Model Status & Download Banner
                if !modelManager.isModelReady {
                    ModelDownloadCard(modelManager: modelManager)
                        .padding(.horizontal)
                        .padding(.top, 8)
                }

                // Status banner
                HStack {
                    Circle()
                        .fill(isProcessing ? Color.orange : Color.green)
                        .frame(width: 8, height: 8)
                    Text(currentStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Gemma 4 E4B (Metal INT4)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.12))
                        .foregroundStyle(Color.blue)
                        .cornerRadius(4)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground))

                // Chat Message Stream
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(messages) { msg in
                                MessageBubble(message: msg)
                            }
                            if !streamingText.isEmpty {
                                StreamingAssistantBubble(text: streamingText)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: messages.count) { _ in
                        if let last = messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }

                Divider()

                // Input Bar
                HStack(spacing: 8) {
                    TextField("Ask Hermes or give a command...", text: $inputText)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isProcessing)

                    Button(action: sendMessage) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(inputText.trimmingCharacters(in: .whitespaces).isEmpty || isProcessing ? .gray : .blue)
                    }
                    .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty || isProcessing)
                }
                .padding()
                .background(Color(.systemBackground))
            }
            .navigationTitle("Hermes Edge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: {
                        BackgroundManager.shared.enableVoiceConversationMode()
                    }) {
                        Image(systemName: "waveform.circle.fill")
                            .foregroundStyle(.purple)
                    }
                }
            }
        }
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }

        inputText = ""
        isProcessing = true
        currentStatus = "Thinking..."
        streamingText = ""

        let userMsg = MessageEnvelope(
            conversationId: conversationId,
            role: .user,
            content: text
        )
        messages.append(userMsg)

        Task {
            do {
                let reply = try await agent.processTurn(
                    conversationId: conversationId,
                    userMessage: userMsg
                ) { event in
                    Task { @MainActor in
                        switch event {
                        case .status(let s):
                            self.currentStatus = s
                        case .token(let t):
                            self.streamingText += t
                        case .toolExecuting(let name, _):
                            self.currentStatus = "Executing tool: \(name)..."
                        case .toolResult(let name, _):
                            self.currentStatus = "Completed: \(name)"
                        case .completed:
                            self.currentStatus = "Ready"
                        default:
                            break
                        }
                    }
                }

                await MainActor.run {
                    self.streamingText = ""
                    self.messages.append(reply)
                    self.isProcessing = false
                    self.currentStatus = "Ready"
                }
            } catch {
                await MainActor.run {
                    self.streamingText = ""
                    self.currentStatus = "Error: \(error.localizedDescription)"
                    self.isProcessing = false
                }
            }
        }
    }
}

struct ModelDownloadCard: View {
    @ObservedObject var modelManager: ModelManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
                Text("Gemma 4 E4B Offline Model (~2.4 GB)")
                    .font(.subheadline.bold())
                Spacer()
            }

            if modelManager.isDownloading {
                ProgressView(value: modelManager.downloadProgress)
                    .progressViewStyle(.linear)
                HStack {
                    Text(modelManager.downloadSpeedDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") {
                        modelManager.cancelDownload()
                    }
                    .font(.caption2.bold())
                    .foregroundStyle(.red)
                }
            } else {
                Text("Download the quantized edge model once to run 100% offline with Apple Silicon Metal acceleration.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(action: {
                    modelManager.startDownload()
                }) {
                    HStack {
                        Image(systemName: "icloud.and.arrow.down")
                        Text("Download Model")
                    }
                    .font(.caption.bold())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.blue)
                    .foregroundStyle(.white)
                    .cornerRadius(8)
                }
            }

            if let err = modelManager.errorMessage {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .background(Color(.tertiarySystemBackground))
        .cornerRadius(12)
    }
}

struct StreamingAssistantBubble: View {
    let text: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .padding(12)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(16)
            }
            Spacer()
        }
    }
}

struct MessageBubble: View {
    let message: MessageEnvelope

    var body: some View {
        HStack {
            if message.role == .user { Spacer() }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                if let calls = message.toolCalls, !calls.isEmpty {
                    ForEach(calls) { call in
                        ToolExecutionCard(call: call)
                    }
                }

                if !message.content.isEmpty {
                    Text(message.content)
                        .padding(12)
                        .background(message.role == .user ? Color.blue : Color(.secondarySystemBackground))
                        .foregroundStyle(message.role == .user ? Color.white : Color.primary)
                        .cornerRadius(16)
                }
            }

            if message.role != .user { Spacer() }
        }
    }
}

struct ToolExecutionCard: View {
    let call: PendingToolCall
    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: iconForTool(call.name))
                    .foregroundStyle(.orange)
                Text(call.name)
                    .font(.caption.bold())
                Spacer()
                Button(action: { isExpanded.toggle() }) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if isExpanded {
                Text(call.argumentsJson)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .background(Color(.systemBackground))
                    .cornerRadius(6)
            }
        }
        .padding(8)
        .background(Color.orange.opacity(0.12))
        .cornerRadius(8)
    }

    private func iconForTool(_ name: String) -> String {
        switch name {
        case "system_calendar_reminders":
            return "calendar.badge.clock"
        case "siri_shortcuts_bridge":
            return "command.square.fill"
        case "interapp_deep_link":
            return "link.circle.fill"
        default:
            return "wrench.and.screwdriver.fill"
        }
    }
}
