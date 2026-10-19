import SwiftUI

public struct ChatView: View {
    @StateObject private var modelManager = ModelManager.shared
    @StateObject private var sessionManager = SessionManager.shared
    @StateObject private var speechManager = SpeechManager.shared

    @State private var messages: [MessageEnvelope] = []
    @State private var inputText: String = ""
    @State private var currentStatus: String = "Ready"
    @State private var isProcessing: Bool = false
    @State private var streamingText: String = ""
    @State private var showTopicDrawer: Bool = false
    @State private var showMemoryInspector: Bool = false
    @State private var soulMarkdownText: String = ""
    @State private var userMarkdownText: String = ""
    @State private var agentsMarkdownText: String = ""

    @FocusState private var isInputFocused: Bool

    private let agent: AgentStateMachine
    private let memory: MemoryManager

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

        self.memory = memory
        self.agent = AgentStateMachine(
            toolRegistry: tools,
            persistenceStore: store,
            memoryManager: memory,
            inferenceEngine: engine
        )
    }

    public var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        // Download Card if model not yet ready
                        if !modelManager.isModelReady {
                            ModelDownloadCard(modelManager: modelManager)
                                .padding(.top, 4)
                        }

                        if messages.isEmpty && streamingText.isEmpty {
                            EmptyStateView(onPromptSelected: { prompt in
                                inputText = prompt
                                sendMessage()
                            })
                            .padding(.top, 24)
                        }

                        ForEach(messages) { msg in
                            MessageBubble(message: msg)
                        }

                        if !streamingText.isEmpty {
                            StreamingAssistantBubble(text: streamingText)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .scrollDismissesKeyboard(.interactively)
                .onTapGesture {
                    dismissKeyboard()
                }
                .onChange(of: messages.count) {
                    if let last = messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                TopHeaderBar(
                    status: currentStatus,
                    isProcessing: isProcessing,
                    sessionTitle: sessionManager.currentSession?.title ?? "Hermes Edge",
                    isModelReady: modelManager.isModelReady,
                    onOpenTopics: { showTopicDrawer = true },
                    onOpenMemory: {
                        Task {
                            soulMarkdownText = await memory.readSoulMarkdown()
                            userMarkdownText = await memory.readUserMarkdown()
                            agentsMarkdownText = await memory.readAgentsMarkdown()
                            showMemoryInspector = true
                        }
                    }
                )
                .background(Color(.systemBackground))
            }
            .safeAreaInset(edge: .bottom) {
                BottomInputBar(
                    inputText: $inputText,
                    isProcessing: isProcessing,
                    isRecording: speechManager.isRecording,
                    isFocused: $isInputFocused,
                    onToggleMic: toggleVoiceInput,
                    onSend: sendMessage
                )
                .background(Color(.systemBackground))
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $showTopicDrawer) {
                TopicDrawerSheet(
                    sessionManager: sessionManager,
                    onSelect: { sessionId in
                        loadSession(sessionId)
                    },
                    onNewChat: {
                        let newSession = sessionManager.createSession()
                        loadSession(newSession.id)
                    }
                )
            }
            .sheet(isPresented: $showMemoryInspector) {
                MemoryInspectorSheet(
                    soulContent: soulMarkdownText,
                    userContent: userMarkdownText,
                    agentsContent: agentsMarkdownText
                )
            }
            .onAppear {
                loadSession(sessionManager.currentSessionId)
            }
        }
    }

    private func dismissKeyboard() {
        isInputFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func loadSession(_ sessionId: String) {
        sessionManager.selectSession(id: sessionId)
        messages = sessionManager.messages(for: sessionId)
        streamingText = ""
        currentStatus = "Ready"
    }

    private func toggleVoiceInput() {
        speechManager.toggleRecording { transcription in
            self.inputText = transcription
        }
    }

    private func sendMessage() {
        dismissKeyboard()
        speechManager.stopSpeaking()
        if speechManager.isRecording {
            speechManager.stopRecording()
        }

        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        inputText = ""
        isProcessing = true
        currentStatus = "Thinking..."
        streamingText = ""

        let activeSessionId = sessionManager.currentSessionId
        let userMsg = MessageEnvelope(
            conversationId: activeSessionId,
            role: .user,
            content: text
        )
        messages.append(userMsg)
        sessionManager.saveMessages(messages, for: activeSessionId)

        Task {
            do {
                let reply = try await agent.processTurn(
                    conversationId: activeSessionId,
                    userMessage: userMsg
                ) { event in
                    Task { @MainActor in
                        switch event {
                        case .status(let s):
                            self.currentStatus = s
                        case .token(let t):
                            self.streamingText += t
                        case .toolExecuting(let name, _):
                            self.currentStatus = "Running \(name)..."
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
                    self.sessionManager.saveMessages(self.messages, for: activeSessionId)
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

// MARK: - Header Bar (Aligned for iPhone 15 Pro Dynamic Island)

struct TopHeaderBar: View {
    let status: String
    let isProcessing: Bool
    let sessionTitle: String
    let isModelReady: Bool
    let onOpenTopics: () -> Void
    let onOpenMemory: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                // Topic Selector Button
                Button(action: onOpenTopics) {
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal")
                            .font(.headline)
                        Text(sessionTitle)
                            .font(.subheadline.bold())
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.primary)
                }

                Spacer()

                // Memory / SOUL Inspector Button
                Button(action: onOpenMemory) {
                    HStack(spacing: 4) {
                        Image(systemName: "brain.head.profile")
                            .font(.caption)
                        Text("Memory")
                            .font(.caption.bold())
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(8)
                    .foregroundStyle(.primary)
                }

                // Model Status Chip
                HStack(spacing: 4) {
                    Circle()
                        .fill(isProcessing ? Color.orange : (isModelReady ? Color.green : Color.blue))
                        .frame(width: 7, height: 7)
                    Text(isModelReady ? "Gemma 4B" : "Setup")
                        .font(.caption2.bold())
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(8)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 6)

            Divider()
        }
        .background(Color(.systemBackground))
    }
}

// MARK: - Docked Input Bar

struct BottomInputBar: View {
    @Binding var inputText: String
    let isProcessing: Bool
    let isRecording: Bool
    var isFocused: FocusState<Bool>.Binding
    let onToggleMic: () -> Void
    let onSend: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(alignment: .bottom, spacing: 8) {
                // Voice Dictation Button
                Button(action: onToggleMic) {
                    ZStack {
                        if isRecording {
                            Circle()
                                .fill(Color.red.opacity(0.2))
                                .frame(width: 36, height: 36)
                                .scaleEffect(1.2)
                                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: isRecording)
                        }
                        Image(systemName: isRecording ? "waveform.circle.fill" : "mic.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(isRecording ? .red : .purple)
                    }
                }
                .padding(.bottom, 2)

                // Multiline Auto-Growing Text Field
                TextField("Ask Hermes or give a command...", text: $inputText, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(18)
                    .focused(isFocused)
                    .disabled(isProcessing)

                // Send Button
                Button(action: onSend) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(inputText.trimmingCharacters(in: .whitespaces).isEmpty || isProcessing ? Color(.systemGray4) : Color.blue)
                }
                .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty || isProcessing)
                .padding(.bottom, 2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.systemBackground))
        }
    }
}

// MARK: - Topic Drawer Sheet

struct TopicDrawerSheet: View {
    @ObservedObject var sessionManager: SessionManager
    @Environment(\.dismiss) private var dismiss
    let onSelect: (String) -> Void
    let onNewChat: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(action: {
                        dismiss()
                        onNewChat()
                    }) {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(.blue)
                            Text("New Conversation")
                                .font(.body.bold())
                        }
                    }
                }

                Section("Conversations") {
                    ForEach(sessionManager.sessions) { session in
                        Button(action: {
                            dismiss()
                            onSelect(session.id)
                        }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.title)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                    Text(session.updatedAt, style: .date)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if session.id == sessionManager.currentSessionId {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                sessionManager.deleteSession(id: session.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Topics & Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Memory Inspector Sheet (SOUL.md / USER.md / AGENTS.md)

struct MemoryInspectorSheet: View {
    let soulContent: String
    let userContent: String
    let agentsContent: String
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: Int = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Picker("Memory Scope", selection: $selectedTab) {
                    Text("USER.md").tag(0)
                    Text("SOUL.md").tag(1)
                    Text("AGENTS.md").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)

                ScrollView {
                    Text(currentContent)
                        .font(.system(.caption, design: .monospaced))
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                        .padding(.horizontal)
                }

                // Files App Note
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                    Text("Files -> On My iPhone -> HermesEdge")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)
            }
            .navigationTitle("Durable Memory & Persona")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var currentContent: String {
        switch selectedTab {
        case 0: return userContent
        case 1: return soulContent
        case 2: return agentsContent
        default: return userContent
        }
    }
}

// MARK: - Message Bubble & Tools

struct MessageBubble: View {
    let message: MessageEnvelope

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .assistant {
                Image(systemName: "sparkles")
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
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
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
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
                .font(.caption2)
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
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
                .font(.system(size: 40))
                .foregroundStyle(.blue)

            Text("Hermes Edge")
                .font(.title3.bold())

            Text("100% offline personal assistant powered by Gemma 4 E4B & Apple A17 Pro Metal acceleration.")
                .font(.caption)
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
                        .padding(.vertical, 9)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(10)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
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
                Text("Model weights detected on device. Apple Silicon Metal INT4 active.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button(action: {
                        modelManager.checkModelStatus()
                    }) {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text("Refresh Status")
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
        }
        .padding(12)
        .background(Color(.tertiarySystemBackground))
        .cornerRadius(12)
        .onAppear {
            modelManager.checkModelStatus()
        }
    }
}
