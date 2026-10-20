import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

/// Durable write-ahead state store guaranteeing Hermes's "Persist-Before-Execute" invariant.
/// On iOS, if Jetsam abruptly terminates the app during tool execution, state remains consistent
/// across restarts via SQLite Write-Ahead Logging (WAL).
public actor PersistBeforeExecuteStore {
    #if canImport(SQLite3)
    private var db: OpaquePointer?
    #endif
    private let dbPath: URL

    // In-memory cache for fast lookups
    private var inMemoryMessages: [String: [MessageEnvelope]] = [:]
    private var inMemoryPendingTools: [String: PendingToolCall] = [:]

    public init(databaseURL: URL? = nil) {
        if let databaseURL {
            self.dbPath = databaseURL
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.dbPath = docs.appendingPathComponent("hermes_journal.sqlite")
        }

        #if canImport(SQLite3)
        openDatabase()
        createTables()
        loadPersistedState()
        #endif
    }

    #if canImport(SQLite3)
    private func openDatabase() {
        if sqlite3_open_v2(dbPath.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK {
            sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
            AppLogger.shared.log("Opened SQLite WAL journal at: \(dbPath.lastPathComponent)", tag: "PBE")
        } else {
            AppLogger.shared.log("Failed to open SQLite WAL database at \(dbPath.path)", tag: "PBE")
        }
    }

    private func createTables() {
        let sql = """
        CREATE TABLE IF NOT EXISTS messages (
            id TEXT PRIMARY KEY,
            conversation_id TEXT NOT NULL,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            tool_calls_json TEXT,
            tool_result_id TEXT,
            timestamp REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS pending_tools (
            tool_id TEXT PRIMARY KEY,
            conversation_id TEXT NOT NULL,
            name TEXT NOT NULL,
            arguments_json TEXT NOT NULL,
            timestamp REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_messages_conv ON messages(conversation_id, timestamp);
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func loadPersistedState() {
        // 1. Recover unacknowledged pending tools from previous crash
        let pendingSql = "SELECT tool_id, name, arguments_json FROM pending_tools;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, pendingSql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let idChars = sqlite3_column_text(stmt, 0),
                   let nameChars = sqlite3_column_text(stmt, 1),
                   let argsChars = sqlite3_column_text(stmt, 2) {
                    let id = String(cString: idChars)
                    let name = String(cString: nameChars)
                    let args = String(cString: argsChars)
                    let call = PendingToolCall(id: id, name: name, argumentsJson: args)
                    inMemoryPendingTools[id] = call
                    AppLogger.shared.log("Recovered unacknowledged tool call across crash: \(name) [\(id)]", tag: "RECOVERY")
                }
            }
        }
        sqlite3_finalize(stmt)
    }
    #endif

    /// Persists the model's tool-call intention BEFORE any side-effect or framework call occurs.
    public func recordPreExecution(conversationId: String, assistantMessage: MessageEnvelope) throws {
        // Cache in memory
        var thread = inMemoryMessages[conversationId] ?? []
        thread.append(assistantMessage)
        inMemoryMessages[conversationId] = thread

        if let calls = assistantMessage.toolCalls {
            for call in calls {
                inMemoryPendingTools[call.id] = call
            }
        }

        #if canImport(SQLite3)
        guard let db = self.db else { return }

        // Persist message
        let insertMsgSql = """
        INSERT OR REPLACE INTO messages (id, conversation_id, role, content, tool_calls_json, tool_result_id, timestamp)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, insertMsgSql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (assistantMessage.id.uuidString as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (conversationId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (assistantMessage.role.rawValue as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 4, (assistantMessage.content as NSString).utf8String, -1, nil)

            if let calls = assistantMessage.toolCalls,
               let data = try? JSONEncoder().encode(calls),
               let json = String(data: data, encoding: .utf8) {
                sqlite3_bind_text(stmt, 5, (json as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 5)
            }

            if let resultId = assistantMessage.toolResultId {
                sqlite3_bind_text(stmt, 6, (resultId as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 6)
            }

            sqlite3_bind_double(stmt, 7, assistantMessage.timestamp.timeIntervalSince1970)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)

        // Persist pending tool calls to disk before execution
        if let calls = assistantMessage.toolCalls {
            for call in calls {
                let insertToolSql = """
                INSERT OR REPLACE INTO pending_tools (tool_id, conversation_id, name, arguments_json, timestamp)
                VALUES (?, ?, ?, ?, ?);
                """
                var toolStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, insertToolSql, -1, &toolStmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(toolStmt, 1, (call.id as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(toolStmt, 2, (conversationId as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(toolStmt, 3, (call.name as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(toolStmt, 4, (call.argumentsJson as NSString).utf8String, -1, nil)
                    sqlite3_bind_double(toolStmt, 5, Date().timeIntervalSince1970)
                    sqlite3_step(toolStmt)
                }
                sqlite3_finalize(toolStmt)
            }
        }
        #endif
    }

    /// Records the tool execution output back to the conversation thread.
    public func recordToolResult(conversationId: String, toolCallId: String, output: String) {
        inMemoryPendingTools.removeValue(forKey: toolCallId)
        
        let toolMessage = MessageEnvelope(
            conversationId: conversationId,
            role: .tool,
            content: output,
            toolResultId: toolCallId
        )
        var thread = inMemoryMessages[conversationId] ?? []
        thread.append(toolMessage)
        inMemoryMessages[conversationId] = thread

        #if canImport(SQLite3)
        guard let db = self.db else { return }

        // Remove from pending_tools
        let deleteSql = "DELETE FROM pending_tools WHERE tool_id = ?;"
        var delStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, deleteSql, -1, &delStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(delStmt, 1, (toolCallId as NSString).utf8String, -1, nil)
            sqlite3_step(delStmt)
        }
        sqlite3_finalize(delStmt)

        // Persist tool result message
        let insertMsgSql = """
        INSERT OR REPLACE INTO messages (id, conversation_id, role, content, tool_calls_json, tool_result_id, timestamp)
        VALUES (?, ?, ?, ?, NULL, ?, ?);
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, insertMsgSql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (toolMessage.id.uuidString as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (conversationId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (toolMessage.role.rawValue as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 4, (toolMessage.content as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 5, (toolCallId as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 6, toolMessage.timestamp.timeIntervalSince1970)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        #endif
    }

    /// Fetches all active messages for an ongoing conversation.
    public func history(for conversationId: String) -> [MessageEnvelope] {
        if let cached = inMemoryMessages[conversationId], !cached.isEmpty {
            return cached
        }

        #if canImport(SQLite3)
        guard let db = self.db else { return [] }
        var fetched: [MessageEnvelope] = []
        let sql = """
        SELECT id, role, content, tool_calls_json, tool_result_id, timestamp
        FROM messages WHERE conversation_id = ? ORDER BY timestamp ASC;
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (conversationId as NSString).utf8String, -1, nil)
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let idStr = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
                      let uuid = UUID(uuidString: idStr),
                      let roleStr = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
                      let role = MessageRole(rawValue: roleStr),
                      let content = sqlite3_column_text(stmt, 2).map({ String(cString: $0) }) else {
                    continue
                }

                var calls: [PendingToolCall]? = nil
                if let callsJson = sqlite3_column_text(stmt, 3).map({ String(cString: $0) }),
                   let data = callsJson.data(using: .utf8) {
                    calls = try? JSONDecoder().decode([PendingToolCall].self, from: data)
                }

                let toolResultId = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
                let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))

                let msg = MessageEnvelope(
                    id: uuid,
                    conversationId: conversationId,
                    role: role,
                    content: content,
                    toolCalls: calls,
                    toolResultId: toolResultId,
                    timestamp: timestamp
                )
                fetched.append(msg)
            }
        }
        sqlite3_finalize(stmt)
        inMemoryMessages[conversationId] = fetched
        return fetched
        #else
        return []
        #endif
    }

    /// Checks if a previous tool call was left incomplete due to a background Jetsam crash.
    public func unacknowledgedToolCalls() -> [PendingToolCall] {
        return Array(inMemoryPendingTools.values)
    }

    deinit {
        #if canImport(SQLite3)
        if let db = db {
            sqlite3_close_v2(db)
        }
        #endif
    }
}
