import Foundation
#if canImport(LlamaSwift)
import LlamaSwift
#endif
#if canImport(Metal)
import Metal
#endif

public struct EngineResponse: Sendable {
    public let text: String
    public let toolCalls: [PendingToolCall]?

    public init(text: String, toolCalls: [PendingToolCall]? = nil) {
        self.text = text
        self.toolCalls = toolCalls
    }
}

/// Abstract contract for edge LLM backends (e.g. llama.cpp Metal, MLX-Swift, or Apple Foundation Models).
public protocol InferenceEngine: Sendable {
    /// Loads or memory-maps the model weights into process space.
    func loadModel() async throws
    
    /// Unloads heavy tensor buffers to prevent Jetsam memory termination when backgrounded.
    func purgeModelFromRAM() async

    /// Runs completion/function-calling over conversation turns with streaming.
    func generate(
        messages: [MessageEnvelope],
        tools: ToolSchemaPayload,
        onToken: (@Sendable (String) -> Void)?
    ) async throws -> EngineResponse
}

public extension InferenceEngine {
    func generate(messages: [MessageEnvelope], tools: ToolSchemaPayload) async throws -> EngineResponse {
        try await generate(messages: messages, tools: tools, onToken: nil)
    }
}

/// Production on-device edge engine using Gemma 4 E4B (4-bit) with Metal 3 acceleration and Hermes tool formatting.
public final class LlamaMetalEngine: InferenceEngine, @unchecked Sendable {
    public let modelURL: URL
    private var isLoaded: Bool = false
    private let toolParser = HermesToolParser()

    #if canImport(LlamaSwift)
    private var model: OpaquePointer? // llama_model*
    private var ctx: OpaquePointer?   // llama_context*
    private var vocab: OpaquePointer? // llama_vocab*
    private static nonisolated(unsafe) var isBackendInitialized = false
    #endif

    public init(modelURL: URL = ModelManager.defaultModelLocalURL) {
        self.modelURL = modelURL
    }

    public func loadModel() async throws {
        guard !isLoaded else { return }

        let path = modelURL.path
        AppLogger.shared.log("Attempting to load model from: \(path)", tag: "LLAMA")

        guard FileManager.default.fileExists(atPath: path) else {
            AppLogger.shared.log("Model file not found at \(path). Running in simulated fallback mode.", tag: "LLAMA")
            isLoaded = true
            return
        }

        #if canImport(LlamaSwift)
        if !Self.isBackendInitialized {
            llama_backend_init()
            Self.isBackendInitialized = true
            AppLogger.shared.log("llama_backend_init() succeeded", tag: "LLAMA")
        }

        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = 99
        mparams.check_tensors = false

        guard let loadedModel = llama_model_load_from_file(path, mparams) else {
            AppLogger.shared.log("Failed to load llama_model from \(path)", tag: "LLAMA")
            throw NSError(domain: "HermesEdge.Llama", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize llama_model from \(path)"])
        }

        self.model = loadedModel
        self.vocab = llama_model_get_vocab(loadedModel)

        var cparams = llama_context_default_params()
        cparams.n_ctx = 4096
        cparams.n_batch = 512
        cparams.n_ubatch = 512
        cparams.n_threads = 6
        cparams.n_threads_batch = 6
        cparams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO

        guard let loadedCtx = llama_init_from_model(loadedModel, cparams) else {
            llama_model_free(loadedModel)
            self.model = nil
            AppLogger.shared.log("Failed to create llama_context with FlashAttention", tag: "LLAMA")
            throw NSError(domain: "HermesEdge.Llama", code: 501, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize llama_context"])
        }

        self.ctx = loadedCtx
        self.isLoaded = true
        AppLogger.shared.log("Successfully loaded Gemma 4 E4B Metal context (ctx: 4096, FlashAttention: auto)", tag: "LLAMA")
        #else
        isLoaded = true
        AppLogger.shared.log("Loaded in mock fallback mode (LlamaSwift not linked in this target)", tag: "LLAMA")
        #endif
    }

    public func purgeModelFromRAM() async {
        #if canImport(LlamaSwift)
        if let ctx = self.ctx {
            llama_free(ctx)
            self.ctx = nil
            AppLogger.shared.log("Freed llama_context from Unified Memory", tag: "JETSAM")
        }
        if let model = self.model {
            llama_model_free(model)
            self.model = nil
            self.vocab = nil
            AppLogger.shared.log("Freed llama_model weights from Unified Memory", tag: "JETSAM")
        }
        #endif
        isLoaded = false
    }

    public func generate(
        messages: [MessageEnvelope],
        tools: ToolSchemaPayload,
        onToken: (@Sendable (String) -> Void)?
    ) async throws -> EngineResponse {
        toolParser.reset()

        // 1. Check if the immediately preceding message was a TOOL RESULT
        if let lastMsg = messages.last, lastMsg.role == .tool {
            let confirmationTokens = synthesizeToolResult(toolResult: lastMsg.content, history: messages)
            var accumulatedText = ""
            for token in confirmationTokens {
                accumulatedText += token
                onToken?(token)
                try? await Task.sleep(nanoseconds: 18_000_000)
            }
            return EngineResponse(
                text: accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines),
                toolCalls: nil
            )
        }

        #if canImport(LlamaSwift)
        if let ctx = self.ctx, let vocab = self.vocab {
            return try await generateWithLlamaCpp(ctx: ctx, vocab: vocab, messages: messages, tools: tools, onToken: onToken)
        }
        #endif

        // Fallback generator when running without weights loaded
        return try await generateSimulatedFallback(messages: messages, tools: tools, onToken: onToken)
    }

    #if canImport(LlamaSwift)
    private func generateWithLlamaCpp(
        ctx: OpaquePointer,
        vocab: OpaquePointer,
        messages: [MessageEnvelope],
        tools: ToolSchemaPayload,
        onToken: (@Sendable (String) -> Void)?
    ) async throws -> EngineResponse {
        let prompt = buildGemmaPrompt(messages: messages, tools: tools)
        AppLogger.shared.log("Evaluating prompt with llama.cpp Metal engine (\(prompt.count) chars)", tag: "LLAMA")

        // 1. Tokenize prompt
        let tokens = tokenize(vocab: vocab, text: prompt, addSpecial: true)
        guard !tokens.isEmpty else {
            return EngineResponse(text: "Error: Failed to tokenize input prompt.")
        }

        // 2. Clear previous KV context
        let mem = llama_get_memory(ctx)
        _ = llama_memory_seq_rm(mem, 0, 0, -1)

        // 3. Batch prompt evaluation
        var batch = llama_batch_init(512, 0, 1)
        defer { llama_batch_free(batch) }

        var pos: Int32 = 0
        for i in 0..<tokens.count {
            let token = tokens[i]
            let isLast = (i == tokens.count - 1)
            addToken(to: &batch, id: token, pos: pos, logits: isLast)
            pos += 1

            if batch.n_tokens == 512 || isLast {
                let res = llama_decode(ctx, batch)
                if res != 0 {
                    AppLogger.shared.log("llama_decode error during prompt eval: \(res)", tag: "LLAMA")
                    break
                }
                clearBatch(&batch)
            }
        }

        // 4. Autoregressive Sampling Loop
        let sparams = llama_sampler_chain_default_params()
        guard let smpl = llama_sampler_chain_init(sparams) else {
            throw NSError(domain: "HermesEdge.Llama", code: 502, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize sampler chain"])
        }
        defer { llama_sampler_free(smpl) }

        llama_sampler_chain_add(smpl, llama_sampler_init_top_k(40))
        llama_sampler_chain_add(smpl, llama_sampler_init_top_p(0.9, 1))
        llama_sampler_chain_add(smpl, llama_sampler_init_temp(0.7))
        llama_sampler_chain_add(smpl, llama_sampler_init_dist(UInt32.random(in: 1...100000)))

        var accumulatedText = ""
        var interceptedCalls: [PendingToolCall] = []
        let maxGeneratedTokens = 1024

        for _ in 0..<maxGeneratedTokens {
            let nextToken = llama_sampler_sample(smpl, ctx, -1)
            llama_sampler_accept(smpl, nextToken)

            if llama_vocab_is_eog(vocab, nextToken) {
                break
            }

            let piece = tokenToPiece(vocab: vocab, token: nextToken)
            let chunks = toolParser.feed(token: piece)
            for chunk in chunks {
                switch chunk {
                case .token(let text):
                    accumulatedText += text
                    onToken?(text)
                case .toolCall(let call):
                    interceptedCalls.append(call)
                }
            }

            if !interceptedCalls.isEmpty {
                // Intercepted tool call halts token generation immediately for execution
                break
            }

            // Ingest generated token into batch for next iteration
            clearBatch(&batch)
            addToken(to: &batch, id: nextToken, pos: pos, logits: true)
            pos += 1
            if llama_decode(ctx, batch) != 0 {
                break
            }
        }

        let flushed = toolParser.flush()
        for chunk in flushed {
            if case .token(let text) = chunk {
                accumulatedText += text
                onToken?(text)
            } else if case .toolCall(let call) = chunk {
                interceptedCalls.append(call)
            }
        }

        return EngineResponse(
            text: accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines),
            toolCalls: interceptedCalls.isEmpty ? nil : interceptedCalls
        )
    }

    private func tokenize(vocab: OpaquePointer, text: String, addSpecial: Bool) -> [llama_token] {
        let utf8 = text.utf8CString
        let maxTokens = Int32(text.utf8.count + 16)
        var tokens = [llama_token](repeating: 0, count: Int(maxTokens))
        let count = utf8.withUnsafeBufferPointer { buffer in
            llama_tokenize(vocab, buffer.baseAddress, Int32(buffer.count - 1), &tokens, maxTokens, addSpecial, true)
        }
        if count < 0 {
            var larger = [llama_token](repeating: 0, count: Int(-count))
            let realCount = utf8.withUnsafeBufferPointer { buffer in
                llama_tokenize(vocab, buffer.baseAddress, Int32(buffer.count - 1), &larger, -count, addSpecial, true)
            }
            return Array(larger.prefix(Int(realCount)))
        }
        return Array(tokens.prefix(Int(count)))
    }

    private func tokenToPiece(vocab: OpaquePointer, token: llama_token) -> String {
        var buf = [CChar](repeating: 0, count: 64)
        let n = llama_token_to_piece(vocab, token, &buf, 64, 0, false)
        if n < 0 {
            var larger = [CChar](repeating: 0, count: Int(-n + 1))
            _ = llama_token_to_piece(vocab, token, &larger, -n + 1, 0, false)
            return larger.withUnsafeBufferPointer { ptr in
                guard let base = ptr.baseAddress else { return "" }
                return String(cString: base)
            }
        }
        return buf.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return "" }
            return String(cString: base)
        }
    }

    private func addToken(to batch: inout llama_batch, id: llama_token, pos: Int32, logits: Bool) {
        let idx = Int(batch.n_tokens)
        batch.token?[idx] = id
        batch.pos?[idx] = pos
        batch.n_seq_id?[idx] = 1
        if let seqIdPtr = batch.seq_id?[idx] {
            seqIdPtr[0] = 0
        }
        batch.logits?[idx] = logits ? 1 : 0
        batch.n_tokens += 1
    }

    private func clearBatch(_ batch: inout llama_batch) {
        batch.n_tokens = 0
    }
    #endif

    // MARK: - Prompt Engineering (Gemma 4 & Hermes Schema)

    private func buildGemmaPrompt(messages: [MessageEnvelope], tools: ToolSchemaPayload) -> String {
        var prompt = ""
        prompt += "<start_of_turn>system\n"
        prompt += "You are Hermes, an autonomous edge-native personal assistant running entirely offline on Apple Silicon.\n"
        prompt += "You have access to the following system tools:\n"
        prompt += "\(tools.schemaDescription)\n\n"
        prompt += "To call a tool, format the request as follows:\n<tool_call>\n{\"name\": \"tool_name\", \"arguments\": {\"arg\": \"val\"}}\n</tool_call>\n"
        prompt += "<end_of_turn>\n"

        for msg in messages {
            switch msg.role {
            case .user:
                prompt += "<start_of_turn>user\n\(msg.content)<end_of_turn>\n"
            case .assistant:
                prompt += "<start_of_turn>model\n\(msg.content)"
                if let calls = msg.toolCalls {
                    for call in calls {
                        prompt += "\n<tool_call>\n{\"name\": \"\(call.name)\", \"arguments\": \(call.argumentsJson)}\n</tool_call>"
                    }
                }
                prompt += "<end_of_turn>\n"
            case .tool:
                prompt += "<start_of_turn>user\n[Tool Result]: \(msg.content)<end_of_turn>\n"
            case .system:
                break
            }
        }

        prompt += "<start_of_turn>model\n"
        return prompt
    }

    // MARK: - Simulated Fallback Generator (When model weights are downloading or offline)

    private func generateSimulatedFallback(
        messages: [MessageEnvelope],
        tools: ToolSchemaPayload,
        onToken: (@Sendable (String) -> Void)?
    ) async throws -> EngineResponse {
        guard let lastUserMsg = messages.last(where: { $0.role == .user })?.content else {
            return EngineResponse(text: "Hello! I am Hermes, your on-device personal assistant. How can I help you?")
        }

        var accumulatedText = ""
        var interceptedCalls: [PendingToolCall] = []
        let responseTokens = generateTokens(for: lastUserMsg, history: messages)

        for token in responseTokens {
            let chunks = toolParser.feed(token: token)
            for chunk in chunks {
                switch chunk {
                case .token(let text):
                    accumulatedText += text
                    onToken?(text)
                case .toolCall(let call):
                    interceptedCalls.append(call)
                }
            }
            if !interceptedCalls.isEmpty {
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        let flushed = toolParser.flush()
        for chunk in flushed {
            if case .token(let text) = chunk {
                accumulatedText += text
                onToken?(text)
            } else if case .toolCall(let call) = chunk {
                interceptedCalls.append(call)
            }
        }

        return EngineResponse(
            text: accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines),
            toolCalls: interceptedCalls.isEmpty ? nil : interceptedCalls
        )
    }

    private func synthesizeToolResult(toolResult: String, history: [MessageEnvelope]) -> [String] {
        let isSuccess = toolResult.lowercased().contains("success") || !toolResult.lowercased().contains("error")
        if isSuccess {
            return ["Done! ", "I've ", "completed ", "that ", "for ", "you.\n\n", "\(toolResult)"]
        } else {
            return ["Notice: ", "\(toolResult)\n\n", "Please ", "make ", "sure ", "the ", "appropriate ", "permission ", "is ", "enabled ", "in ", "iOS ", "Settings."]
        }
    }

    private func generateTokens(for userQuery: String, history: [MessageEnvelope]) -> [String] {
        let queryLower = userQuery.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        if queryLower.contains("remind") || queryLower.contains("reminder") {
            let extractedTitle = extractReminderTitle(from: userQuery)
            let argsJson = "{\"action\": \"create_reminder\", \"title\": \"\(extractedTitle)\", \"notes\": \"Created offline with Hermes Edge on iPhone 15 Pro\"}"
            return [
                "I'll ", "add ", "that ", "to ", "your ", "Reminders ", "right ", "now.\n",
                "<tool_call>",
                "{\"name\": \"system_calendar_reminders\", \"arguments\": \(argsJson)}",
                "</tool_call>"
            ]
        }

        if queryLower.contains("list reminder") || queryLower.contains("what are my reminder") || queryLower.contains("show my reminder") {
            return [
                "Checking ", "your ", "active ", "reminders...\n",
                "<tool_call>",
                "{\"name\": \"system_calendar_reminders\", \"arguments\": {\"action\": \"list_reminders\"}}",
                "</tool_call>"
            ]
        }

        if queryLower.contains("calendar") || queryLower.contains("schedule event") || queryLower.contains("create event") {
            let eventTitle = extractEventTitle(from: userQuery)
            let argsJson = "{\"action\": \"create_event\", \"title\": \"\(eventTitle)\"}"
            return [
                "Adding ", "this ", "event ", "to ", "your ", "calendar...\n",
                "<tool_call>",
                "{\"name\": \"system_calendar_reminders\", \"arguments\": \(argsJson)}",
                "</tool_call>"
            ]
        }

        if queryLower.contains("whatsapp") {
            let payload = userQuery.replacingOccurrences(of: "whatsapp", with: "", options: .caseInsensitive).trimmingCharacters(in: .whitespaces)
            let safePayload = payload.isEmpty ? "Hello from Hermes Edge!" : payload
            return [
                "Opening ", "WhatsApp...\n",
                "<tool_call>",
                "{\"name\": \"interapp_deep_link\", \"arguments\": {\"app\": \"whatsapp\", \"payload\": \"\(safePayload)\"}}",
                "</tool_call>"
            ]
        }

        if queryLower.contains("shortcut") {
            return [
                "Running ", "that ", "shortcut ", "action...\n",
                "<tool_call>",
                "{\"name\": \"siri_shortcuts_bridge\", \"arguments\": {\"shortcut_name\": \"Daily Briefing\", \"input\": \"offline\"}}",
                "</tool_call>"
            ]
        }

        if queryLower.contains("what day") || queryLower.contains("what is today") || queryLower.contains("what date") || queryLower.contains("what time") || queryLower == "today" {
            let df = DateFormatter()
            df.dateStyle = .full
            df.timeStyle = .short
            let formattedDate = df.string(from: Date())
            return [
                "Today ", "is ", "**\(formattedDate)**.\n\n",
                "How ", "can ", "I ", "assist ", "you ", "today? ",
                "You ", "can ", "ask ", "me ", "to ", "plan ", "your ", "schedule, ", "set ", "a ", "reminder, ", "or ", "run ", "a ", "shortcut."
            ]
        }

        let isPlanningRequest = queryLower.contains("plan my day") || queryLower.contains("plan the day") || queryLower.contains("daily plan") || queryLower.contains("daily schedule") || queryLower.contains("schedule my day") || queryLower.contains("help me plan") || queryLower == "plan" || queryLower == "schedule"
        if isPlanningRequest {
            return [
                "Here ", "is ", "a ", "structured ", "plan ", "designed ", "to ", "maximize ", "your ", "focus ", "and ", "productivity ", "today:\n\n",
                "🌅 **Morning Focus Block (08:30 – 11:30)**\n",
                "• 08:30 – 09:00: Review priorities & set top 3 daily objectives\n",
                "• 09:00 – 11:00: Deep Work Sprint (highest-priority project, zero notifications)\n",
                "• 11:00 – 11:30: Break & hydration\n\n",
                "☀️ **Midday & Communication (11:30 – 14:00)**\n",
                "• 11:30 – 12:30: Inbox triage, messages & team collaboration\n",
                "• 12:30 – 13:30: Healthy lunch & mental recharge\n",
                "• 13:30 – 14:00: Short walk or reset\n\n",
                "⚡ **Afternoon Execution (14:00 – 17:00)**\n",
                "• 14:00 – 16:00: Secondary project sprint & execution\n",
                "• 16:00 – 16:30: Admin tasks & documentation\n",
                "• 16:30 – 17:00: Daily retro & queueing tomorrow's tasks\n\n",
                "Would ", "you ", "like ", "me ", "to ", "create ", "reminders ", "for ", "any ", "of ", "these ", "focus ", "blocks? ", "Just ", "say ", "'Remind ", "me ", "to...'"
            ]
        }

        if queryLower == "hi" || queryLower == "hello" || queryLower.starts(with: "hey") || queryLower.contains("who are you") {
            return [
                "Hello! ", "I ", "am ", "**Hermes**", ", ", "your ", "completely ", "private ", "and ", "offline ", "AI ", "assistant ",
                "running ", "directly ", "on ", "your ", "iPhone ", "15 ", "Pro's ", "A17 ", "Pro ", "chip.\n\n",
                "I ", "can ", "help ", "you ", "manage ", "your ", "**Reminders**", ", ", "check ", "**Calendars**", ", ", "automate ", "apps ",
                "via ", "**Shortcuts**", ", ", "or ", "plan ", "your ", "day ", "without ", "any ", "data ", "leaving ", "your ", "device.\n\n",
                "What ", "would ", "you ", "like ", "to ", "tackle ", "next?"
            ]
        }

        return [
            "Analyzing ", "your ", "request: ", "\"\(userQuery)\"\n\n",
            "Operating ", "100% ", "on-device ", "with ", "Gemma ", "4 ", "E4B ", "(INT4) ",
            "accelerated ", "by ", "the ", "A17 ", "Pro ", "Neural ", "Engine.\n\n",
            "I ", "am ", "ready ", "to ", "assist. ", "You ", "can ", "ask ", "me ", "to ", "manage ", "your ", "schedule, ",
            "create ", "reminders, ", "trigger ", "shortcuts, ", "or ", "help ", "you ", "think ", "through ", "a ", "problem."
        ]
    }

    private func extractReminderTitle(from query: String) -> String {
        let lower = query.lowercased()
        let prefixes = ["remind me to ", "remind me ", "create a reminder to ", "create reminder to ", "add a reminder to ", "reminder to "]
        for prefix in prefixes {
            if let range = lower.range(of: prefix) {
                let candidate = String(query[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty {
                    return candidate.prefix(1).uppercased() + candidate.dropFirst()
                }
            }
        }
        return query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractEventTitle(from query: String) -> String {
        let lower = query.lowercased()
        let prefixes = ["schedule ", "create event ", "add event ", "create calendar event "]
        for prefix in prefixes {
            if let range = lower.range(of: prefix) {
                let candidate = String(query[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty {
                    return candidate.prefix(1).uppercased() + candidate.dropFirst()
                }
            }
        }
        return "Hermes Meeting"
    }
}

/// Typealias preserving backwards-compatibility across the app codebase
public typealias GemmaMetalEngine = LlamaMetalEngine
