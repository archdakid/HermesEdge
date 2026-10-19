import Foundation

/// Manages context compaction, working memory, and durable USER.md / SOUL.md files for edge models.
/// Ported from Hermes Agent and OpenClaw memory architectures.
public actor MemoryManager {
    private var coreFacts: [String] = []
    private let maxTokensThreshold: Int

    private var userMarkdownURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("USER.md")
    }

    private var soulMarkdownURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("SOUL.md")
    }

    private var agentsMarkdownURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("AGENTS.md")
    }

    public init(maxTokensThreshold: Int = 3000) {
        self.maxTokensThreshold = maxTokensThreshold
        Task {
            await self.bootstrapMemoryFiles()
        }
    }

    /// Bootstraps durable SOUL.md, USER.md, and AGENTS.md in iOS Documents so they can be inspected in the Files app.
    public func bootstrapMemoryFiles() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)

        // 0. Ensure README.txt exists so iOS Files app immediately registers the folder
        let readmeURL = docs.appendingPathComponent("README.txt")
        if !FileManager.default.fileExists(atPath: readmeURL.path) {
            let readme = """
            HermesEdge On-Device Assistant
            -------------------------------
            This folder stores your private, on-device assistant data:
            - USER.md: User facts and preferences
            - SOUL.md: Assistant persona & tool calling contract
            - AGENTS.md: Subagent specialization roles
            - debug.log: Real-time diagnostics
            - chat_sessions.json: Topic conversation threads
            """
            try? readme.write(to: readmeURL, atomically: true, encoding: .utf8)
        }

        // 1. Ensure USER.md exists
        if !FileManager.default.fileExists(atPath: userMarkdownURL.path) {
            let defaultUser = """
            # USER PROFILE & MEMORY (USER.md)

            This file contains durable facts, preferences, and context about the user.
            Hermes Edge reads this file on startup and updates it as new facts are learned.

            ## Profile
            - Name: Chad Archie
            - Device: iPhone 15 Pro (Apple A17 Pro, 128GB+)
            - Primary Workflows: Software development, agentic workflows, on-device AI engineering, task automation.

            ## Core Preferences
            - Communication Style: Direct, concise, technical, no excessive fluff.
            - Scheduling: Prefers time-blocked daily schedules with deep-focus blocks in the morning.
            - Privacy: Maximum privacy, zero cloud transmission.
            - Tool Automation: Prefers having reminders, calendar events, and shortcuts created directly without asking for unnecessary manual confirmations.

            ## Learned Facts & Context
            - Active project: HermesEdge (offline iOS personal assistant).
            - Prefers using on-device models with hardware Metal acceleration.
            - Uses Siri Voice & Action Button for hands-free automation.
            """
            try? defaultUser.write(to: userMarkdownURL, atomically: true, encoding: .utf8)
        }

        // 2. Load facts from USER.md
        if let content = try? String(contentsOf: userMarkdownURL, encoding: .utf8) {
            let lines = content.components(separatedBy: .newlines)
            let facts = lines
                .filter { $0.trimmingCharacters(in: .whitespaces).starts(with: "- ") }
                .map { $0.replacingOccurrences(of: "- ", with: "").trimmingCharacters(in: .whitespaces) }
            self.coreFacts = facts
        }

        // 3. Ensure SOUL.md exists
        if !FileManager.default.fileExists(atPath: soulMarkdownURL.path) {
            let defaultSoul = """
            # SOUL OF HERMES EDGE

            You are **Hermes Edge**, a private, completely offline, on-device AI personal assistant running natively on Apple Silicon (iPhone 15 Pro / A17 Pro). You are architected on the principles of **Nous Hermes** and **OpenClaw**.

            ## 1. Core Operating Principles
            1. **100% Offline & Private**: You run exclusively on local neural hardware. No user data, messages, or tool interactions ever leave the physical device.
            2. **Persist-Before-Execute**: Before any external tool or side effect is dispatched (reminders, calendar events, shortcuts), your intention and arguments are persisted to local storage.
            3. **Context Economy for Edge Models**: Powered by Gemma 4 E4B (INT4). Keep answers clear, dense, actionable, and structured. Micro-compaction preserves key decisions while freeing context.
            4. **Multi-Agent Specialization**: You act as executive supervisor, routing to specialized subagents (Day Planner, System Automator, Memory Agent) when appropriate.

            ## 2. Tool Calling Format
            When you need to execute an action on the user's iPhone, respond with an XML `<tool_call>` block:
            <tool_call>
            {"name": "tool_name", "arguments": {"key": "value"}}
            </tool_call>

            When the tool completes, you will receive a `<tool_response>` block:
            <tool_response>
            {"name": "tool_name", "content": "result"}
            </tool_response>
            Upon receiving the tool response, synthesize a clear, friendly confirmation to the user and do not invoke the tool again.

            ## 3. Available Tools
            - `system_calendar_reminders`: Create reminders, check active reminders, create calendar events.
            - `siri_shortcuts_bridge`: Run user-created iOS Shortcuts.
            - `interapp_deep_link`: Open external apps (WhatsApp, Notes, Mail, Files, Drafts).
            """
            try? defaultSoul.write(to: soulMarkdownURL, atomically: true, encoding: .utf8)
        }

        // 4. Ensure AGENTS.md exists
        if !FileManager.default.fileExists(atPath: agentsMarkdownURL.path) {
            let defaultAgents = """
            # SUBAGENT ARCHITECTURE (AGENTS.md)

            On edge devices with lightweight models (Gemma 4 E4B / 4B INT4), breaking complex cognitive tasks across specialized subagent personas drastically increases output accuracy and prevents hallucination.

            ## 1. Executive Supervisor (`supervisor`)
            - Role: Entry point for all user requests (Chat, Siri Voice, Action Button).
            - Function: Categorizes intent and routes to specialized subagents.
            - Rules: Maintains conversation envelope and ensures tool responses are cleanly synthesized.

            ## 2. Day Planner Subagent (`planner`)
            - Specialization: Time-blocking, daily scheduling, productivity optimization, and routine tracking.
            - Workflow:
              1. Inspects user goals and scheduled events.
              2. Breaks day into three high-leverage blocks: Morning Deep Work, Midday Collaboration, Afternoon Execution.
              3. Prepares actionable reminders or calendar events.

            ## 3. System Action Subagent (`automator`)
            - Specialization: Interacting with native iOS systems via EventKit, Shortcuts, and URL schemes.
            - Workflow: Extracts parameters, emits valid XML tool calls, halts for execution.

            ## 4. Memory & Context Subagent (`memory`)
            - Specialization: Long-term fact extraction, USER.md maintenance, and context micro-compaction.
            - Workflow: Scans messages for persistent facts, updates USER.md on disk, compresses history when near token limits.
            """
            try? defaultAgents.write(to: agentsMarkdownURL, atomically: true, encoding: .utf8)
        }
    }

    /// Stores a persistent piece of information and writes it into USER.md.
    public func storeFact(_ fact: String) {
        coreFacts.append(fact)
        if let handle = try? FileHandle(forWritingTo: userMarkdownURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            if let data = "\n- \(fact)".data(using: .utf8) {
                handle.write(data)
            }
        }
    }

    public func retrieveFacts() -> [String] {
        return coreFacts
    }

    public func readUserMarkdown() -> String {
        return (try? String(contentsOf: userMarkdownURL, encoding: .utf8)) ?? "# USER.md"
    }

    public func readSoulMarkdown() -> String {
        return (try? String(contentsOf: soulMarkdownURL, encoding: .utf8)) ?? "# SOUL.md"
    }

    public func readAgentsMarkdown() -> String {
        return (try? String(contentsOf: agentsMarkdownURL, encoding: .utf8)) ?? "# AGENTS.md"
    }

    /// Builds the system prompt with injected SOUL rules and USER.md facts.
    public func buildSystemPrompt(basePrompt: String) -> String {
        var prompt = basePrompt
        if !coreFacts.isEmpty {
            let factsBlock = coreFacts.map { "- \($0)" }.joined(separator: "\n")
            prompt += """
            \n\n<UserKnowledgeBase>
            \(factsBlock)
            </UserKnowledgeBase>
            """
        }
        return prompt
    }

    /// Performs micro-compaction on conversation history when the context window nears capacity.
    public func compactHistory(messages: [MessageEnvelope]) -> [MessageEnvelope] {
        let totalChars = messages.reduce(0) { $0 + $1.content.count }
        guard totalChars > (maxTokensThreshold * 4) else {
            return messages
        }

        guard messages.count > 6 else { return messages }

        let systemMessages = messages.filter { $0.role == .system }
        let recentMessages = messages.suffix(4)
        let middleMessages = messages.dropFirst(systemMessages.count).dropLast(4)

        let summaryText = "[Summary of \(middleMessages.count) previous turns: discussed user requests and executed tools on-device]"
        let summaryEnvelope = MessageEnvelope(
            conversationId: messages.first?.conversationId ?? UUID().uuidString,
            role: .system,
            content: summaryText
        )

        return systemMessages + [summaryEnvelope] + Array(recentMessages)
    }
}
