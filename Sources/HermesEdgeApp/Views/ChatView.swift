import SwiftUI

public struct ChatView: View {
    @StateObject private var modelManager = ModelManager.shared
    @StateObject private var speechManager = SpeechManager.shared
    @State private var messages: [MessageEnvelope] = []
    @State private var inputText: String = ""
    @State private var currentStatus: String = "Ready"
    @State private var isProcessing: Bool = false
    @State private var streamingText: String = ""
    @FocusState private var isInputFocused: Bool

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

                // Status Banner
                HStack(spacing: 6) {
                    Circle()
                        .fill(isProcessing ? Color.orange : Color.green)
                        .frame(width: 8, height: 8)
                    Text(currentStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: "cpu")
                            .font(.caption2)
                        Text(modelManager.isModelReady ? "Gemma 4 E4B • Ready" : "A17 Pro • Offline")
                            .font(.caption2.bold())
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(modelManager.isModelReady ? Color.green.opacity(0.15) : Color.blue.opacity(0.12))
                    .foregroundStyle(modelManager.isModelReady ? Color.green : Color.blue)
                    .cornerRadius(6)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground))

                // Chat Message Stream
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if messages.isEmpty && streamingText.isEmpty {
                                EmptyStateView(onPromptSelected: { prompt in
                                    inputText = prompt
                                    sendMessage()
                                })
                                .padding(.top, 30)
                            }

                            ForEach(messages) { msg in
                                MessageBubble(message: msg)
                            }
                            if !streamingText.isEmpty {
                                StreamingAssistantBubble(text: streamingText)
                            }
                        }
                        .padding()
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onTapGesture {
                        isInputFocused = false
                    }
                    .onChange(of: messages.count) {
                        if let last = messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }

                Divider()

                // Polished Input Bar
                HStack(alignment: .bottom, spacing: 8) {
                    // Voice Dictation Button
                    Button(action: toggleVoiceInput) {
                        ZStack {
                            if speechManager.isRecording {
                                Circle()
                                    .fill(Color.red.opacity(0.2))
                                    .frame(width: 40, height: 40)
                                    .scaleEffect(1.2)
                                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: speechManager.isRecording)
                            }
                            Image(systemName: speechManager.isRecording ? "waveform.circle.fill" : "mic.circle.fill")
                                .font(.system(size: 32))
                                .foregroundStyle(speechManager.isRecording ? .red : .purple)
                        }
                    }

                    // Multiline Text Field
                    TextField("Ask Hermes or give a command...", text: $inputText, axis: .vertical)
                        .lineLimit(1...5)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(.tertiarySystemBackground))
                        .cornerRadius(18)
                        .focused($isInputFocused)
                        .disabled(isProcessing)

                    // Send Button
                    Button(action: sendMessage) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(inputText.trimmingCharacters(in: .whitespaces).isEmpty || isProcessing ? .gray : .blue)
                    }
                    .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty || isProcessing)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.systemBackground))
            }
            .navigationTitle("Hermes Edge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive, action: clearMessages) {
                            Label("Clear Chat", systemImage: "trash")
                        }
                        Button(action: {
                            modelManager.checkModelStatus()
                        }) {
                            Label("Check Model Weights", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.subheadline)
                    }
                }

                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        isInputFocused = false
                    }
                    .font(.body.bold())
                }
            }
        }
    }

    private func toggleVoiceInput() {
        if speechManager.isRecording {
            speechManager.stopRecording()
        } else {
            speechManager.requestPermissions { authorized in
                if authorized {
                    speechManager.startRecording { transcription in
                        self.inputText = transcription
                    }
                }
            }
        }
    }

    private func clearMessages() {
        speechManager.stopSpeaking()
        messages.removeAll()
        streamingText = ""
        currentStatus = "Ready"
    }

    private func sendMessage() {
        if speechManager.isRecording {
            speechManager.stopRecording()
        }
        speechManager.stopSpeaking()

        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        inputText = ""
        isInputFocused = false
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
                            self.currentStatus = "Executing \(name)..."
                        case .toolResult(let name, _):
                            self.currentStatus = "Completed \(name)"
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

// MARK: - Supporting Views

struct EmptyStateView: View {
    let onPromptSelected: (String) -> Void

    let suggestions = [
        "Plan my day for high focus",
        "Remind me to check Hermes tomorrow at 9 AM",
        "Open WhatsApp with my latest update",
        "What are my active reminders?"
    ]

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 44))
                .foregroundStyle(.blue)

            Text("Hermes Edge")
                .font(.title2.bold())

            Text("100% offline on-device personal assistant powered by Gemma 4 E4B & Apple A17 Pro Metal acceleration.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button(action: { onPromptSelected(suggestion) }) {
                        HStack {
                            Text(suggestion)
                                .font(.caption.bold())
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(10)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
        }
    }
}

struct MessageBubble: View {
    let message: MessageEnvelope

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .assistant {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Color.blue)
                    .clipShape(Circle())
            } else {
                Spacer()
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                if let calls = message.toolCalls, !calls.isEmpty {
                    ForEach(calls) { call in
                        ToolExecutionCard(call: call)
                    }
                }

                if !message.content.isEmpty {
                    Text(message.content)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(message.role == .user ? Color.blue : Color(.secondarySystemBackground))
                        .foregroundStyle(message.role == .user ? Color.white : Color.primary)
                        .cornerRadius(16)
                }

                // Assistant Voice Playback Button
                if message.role == .assistant && !message.content.isEmpty {
                    Button(action: {
                        SpeechManager.shared.speak(text: message.content)
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "speaker.wave.2")
                            Text("Read Aloud")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 4)
                }
            }

            if message.role == .user {
                Image(systemName: "person.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Color.gray)
                    .clipShape(Circle())
            }
        }
    }
}

struct StreamingAssistantBubble: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.caption)
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Color.blue)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(16)
            }
            Spacer()
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

                HStack(spacing: 8) {
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

                    Button(action: {
                        modelManager.checkModelStatus()
                    }) {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text("Check Files")
                        }
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(.secondarySystemBackground))
                        .foregroundStyle(.primary)
                        .cornerRadius(8)
                    }
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
        .onAppear {
            modelManager.checkModelStatus()
        }
    }
}
