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
    @State private var showLogsSheet: Bool = false
    @State private var soulMarkdownText: String = ""
    @State private var userMarkdownText: String = ""
    @State private var agentsMarkdownText: String = ""
    @State private var isEngineLoaded: Bool = false

    @FocusState private var isInputFocused: Bool

    private let agent: AgentStateMachine
    private let memory: MemoryManager
    private let engine: LlamaMetalEngine

    public init() {
        let tools = ToolRegistry()
        Task {
            await tools.register(tool: EventKitTool())
            await tools.register(tool: ShortcutsTool())
            await tools.register(tool: URLSchemeTool())
        }

        let store = PersistBeforeExecuteStore()
        let memory = MemoryManager()
        let engine = LlamaMetalEngine()

        BackgroundManager.shared.configure(engine: engine)

        self.memory = memory
        self.engine = engine
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
                    isEngineLoaded: isEngineLoaded,
                    isModelReady: modelManager.isModelReady,
                    onOpenTopics: { showTopicDrawer = true },
                    onOpenMemory: {
                        Task {
                            soulMarkdownText = await memory.readSoulMarkdown()
                            userMarkdownText = await memory.readUserMarkdown()
                            agentsMarkdownText = await memory.readAgentsMarkdown()
                            showMemoryInspector = true
                        }
                    },
                    onOpenLogs: { showLogsSheet = true }
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
                    agentsContent: agentsMarkdownText,
                    memoryManager: memory,
                    sessionMessages: messages
                )
            }
            .sheet(isPresented: $showLogsSheet) {
                LogsSheet(onReloadModel: {
                    Task {
                        AppLogger.shared.log("Manual reload triggered from LogsSheet", tag: "LLAMA")
                        await engine.purgeModelFromRAM()
                        modelManager.checkModelStatus()
                        try? await engine.loadModel()
                        await MainActor.run {
                            self.isEngineLoaded = engine.isModelLoaded
                        }
                    }
                })
            }
            .onAppear {
                loadSession(sessionManager.currentSessionId)
                modelManager.checkModelStatus()
                Task {
                    AppLogger.shared.log("ChatView appeared. Checking model and initializing LlamaMetalEngine...", tag: "BOOT")
                    try? await engine.loadModel()
                    await MainActor.run {
                        self.isEngineLoaded = engine.isModelLoaded
                    }
                }
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
                    self.isEngineLoaded = engine.isModelLoaded
                    self.isProcessing = false
                    self.currentStatus = "Ready"
                }
            } catch {
                await MainActor.run {
                    self.streamingText = ""
                    self.isEngineLoaded = engine.isModelLoaded
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
    let isEngineLoaded: Bool
    let isModelReady: Bool
    let onOpenTopics: () -> Void
    let onOpenMemory: () -> Void
    let onOpenLogs: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                // Topic Selector Button
                Button(action: onOpenTopics) {
                    HStack(spacing: 4) {
                        Image(systemName: "line.3.horizontal")
                            .font(.subheadline)
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

                // Live Logs & Diagnostics Button
                Button(action: onOpenLogs) {
                    HStack(spacing: 3) {
                        Image(systemName: "terminal.fill")
                            .font(.caption2)
                        Text("Logs")
                            .font(.caption2.bold())
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(8)
                    .foregroundStyle(.purple)
                }

                // Memory / SOUL Inspector Button
                Button(action: onOpenMemory) {
                    HStack(spacing: 3) {
                        Image(systemName: "brain.head.profile")
                            .font(.caption2)
                        Text("Memory")
                            .font(.caption2.bold())
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(8)
                    .foregroundStyle(.primary)
                }

                // Model Status Chip
                HStack(spacing: 4) {
                    Circle()
                        .fill(isProcessing ? Color.orange : (isEngineLoaded ? Color.green : (isModelReady ? Color.yellow : Color.gray)))
                        .frame(width: 7, height: 7)
                    Text(isEngineLoaded ? "Gemma 4B Metal" : (isModelReady ? "Model Found" : "No Model"))
                        .font(.caption2.bold())
                }
                .padding(.horizontal, 7)
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

// MARK: - Memory Inspector Sheet (SOUL.md / USER.md / AGENTS.md / Dreaming / Intents)

struct MemoryInspectorSheet: View {
    @State var soulContent: String
    @State var userContent: String
    @State var agentsContent: String
    let memoryManager: MemoryManager
    let sessionMessages: [MessageEnvelope]
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: Int = 0
    @State private var isConsolidating: Bool = false
    @State private var consolidationStatus: String? = nil
    @State private var standingIntents: [StandingIntent] = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let status = consolidationStatus {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption2)
                        Text(status)
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }

                Picker("Memory Scope", selection: $selectedTab) {
                    Text("USER.md").tag(0)
                    Text("SOUL.md").tag(1)
                    Text("AGENTS.md").tag(2)
                    Text("Intents").tag(3)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 4)

                if selectedTab == 3 {
                    // Standing Intents Tab
                    List {
                        Section("Autonomous Standing Intents (OpenClaw Harness)") {
                            ForEach(standingIntents) { intent in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(intent.title)
                                            .font(.subheadline.bold())
                                        Spacer()
                                        Circle()
                                            .fill(intent.isEnabled ? Color.green : Color.gray)
                                            .frame(width: 8, height: 8)
                                    }
                                    Text(intent.prompt)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    HStack {
                                        Text(conditionDescription(intent.condition))
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color(.secondarySystemBackground))
                                            .cornerRadius(4)
                                        Spacer()
                                        if let last = intent.lastTriggeredAt {
                                            Text("Last: \(last, style: .time)")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                } else {
                    ScrollView {
                        Text(currentContent)
                            .font(.system(.caption, design: .monospaced))
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(12)
                            .padding(.horizontal)
                    }
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
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: {
                        isConsolidating = true
                        consolidationStatus = "Consolidating memories..."
                        Task {
                            let res = await DreamingEngine.shared.runDreamingCycle(
                                memoryManager: memoryManager,
                                sessionMessages: sessionMessages
                            )
                            let updatedUser = await memoryManager.readUserMarkdown()
                            let updatedSoul = await memoryManager.readSoulMarkdown()
                            let updatedAgents = await memoryManager.readAgentsMarkdown()
                            await MainActor.run {
                                self.userContent = updatedUser
                                self.soulContent = updatedSoul
                                self.agentsContent = updatedAgents
                                self.consolidationStatus = "Promoted: \(res.promotedCount), Pruned: \(res.prunedCount)"
                                self.isConsolidating = false
                            }
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "moon.stars.fill")
                                .foregroundStyle(.purple)
                            Text(isConsolidating ? "Dreaming..." : "Dream")
                                .font(.caption.bold())
                        }
                    }
                    .disabled(isConsolidating)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                Task {
                    let intents = await StandingIntentsDaemon.shared.activeIntents()
                    await MainActor.run {
                        self.standingIntents = intents
                    }
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

    private func conditionDescription(_ condition: IntentCondition) -> String {
        switch condition {
        case .dailyAt(let h, let m):
            return String(format: "Daily at %02d:%02d", h, m)
        case .recurringInterval(let sec):
            return "Every \(Int(sec / 60)) min"
        case .eventKitReminderDue:
            return "Reminder Trigger"
        }
    }
}

// MARK: - In-App Live Diagnostics & Logs Sheet

struct LogsSheet: View {
    @ObservedObject var logger = AppLogger.shared
    @Environment(\.dismiss) private var dismiss
    var onReloadModel: (() -> Void)? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                // Previous Crash Banner (if any)
                if let crash = logger.readCrashFile() {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text("LAST UNCAUGHT CRASH")
                                .font(.caption.bold())
                                .foregroundStyle(.red)
                            Spacer()
                            Button("Dismiss Crash") {
                                logger.clearCrashFile()
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        ScrollView {
                            Text(crash)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 120)
                    }
                    .padding(8)
                    .background(Color.red.opacity(0.12))
                    .cornerRadius(8)
                    .padding(.horizontal)
                }

                // Live Console Logs
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(logger.recentLogs.enumerated()), id: \.offset) { idx, log in
                                Text(log)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(logColor(for: log))
                                    .id(idx)
                            }
                        }
                        .padding(8)
                    }
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(10)
                    .padding(.horizontal)
                    .onChange(of: logger.recentLogs.count) {
                        if !logger.recentLogs.isEmpty {
                            withAnimation {
                                proxy.scrollTo(logger.recentLogs.count - 1, anchor: .bottom)
                            }
                        }
                    }
                }

                // Action Bar
                HStack(spacing: 8) {
                    Button(role: .destructive, action: {
                        logger.clearLogs()
                        logger.clearCrashFile()
                    }) {
                        Label("Clear", systemImage: "trash")
                            .font(.caption)
                    }

                    Button(action: {
                        onReloadModel?()
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.clockwise")
                            Text("Reload Model")
                        }
                        .font(.caption2.bold())
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.tertiarySystemBackground))
                    .cornerRadius(6)

                    Spacer()

                    // Quick Test Permission Buttons
                    Button("Test Reminder") {
                        Task {
                            let tool = EventKitTool()
                            let res = try? await tool.execute(argumentsJson: "{\"action\": \"create_reminder\", \"title\": \"Test Reminder from Hermes Edge\"}")
                            AppLogger.shared.log("Direct reminder test result: \(res ?? "nil")", tag: "TEST")
                        }
                    }
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.tertiarySystemBackground))
                    .cornerRadius(6)

                    Button("Copy All") {
                        UIPasteboard.general.string = logger.readLogFile()
                    }
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.blue)
                    .foregroundStyle(.white)
                    .cornerRadius(6)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .navigationTitle("Live Diagnostics & Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func logColor(for log: String) -> Color {
        if log.contains("CRASH") || log.contains("Error") || log.contains("failed") {
            return .red
        } else if log.contains("SPEECH") {
            return .purple
        } else if log.contains("EVENTKIT") {
            return .orange
        } else if log.contains("TEST") {
            return .blue
        }
        return .primary
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
