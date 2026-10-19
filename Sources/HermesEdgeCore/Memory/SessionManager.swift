import Foundation
import Combine

/// A conversation session / topic thread.
public struct ChatSession: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var title: String
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, title: String = "New Conversation", createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Persistent Multi-Session and Chat History Manager storing threads in iOS Documents.
@MainActor
public final class SessionManager: ObservableObject {
    public static let shared = SessionManager()

    @Published public private(set) var sessions: [ChatSession] = []
    @Published public var currentSessionId: String = ""

    private var sessionMessages: [String: [MessageEnvelope]] = [:]

    private var storageFileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("chat_sessions.json")
    }

    private struct PersistedData: Codable {
        let sessions: [ChatSession]
        let messages: [String: [MessageEnvelope]]
        let activeSessionId: String?
    }

    public init() {
        loadFromDisk()
    }

    public var currentSession: ChatSession? {
        sessions.first(where: { $0.id == currentSessionId })
    }

    /// Creates a new chat topic thread.
    public func createSession(title: String = "New Conversation") -> ChatSession {
        let newSession = ChatSession(title: title)
        sessions.insert(newSession, at: 0)
        currentSessionId = newSession.id
        sessionMessages[newSession.id] = []
        saveToDisk()
        return newSession
    }

    /// Switches the active conversation thread.
    public func selectSession(id: String) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        currentSessionId = id
        saveToDisk()
    }

    /// Retrieves messages for a given session.
    public func messages(for sessionId: String) -> [MessageEnvelope] {
        return sessionMessages[sessionId] ?? []
    }

    /// Saves messages to the active session and updates timestamps.
    public func saveMessages(_ msgs: [MessageEnvelope], for sessionId: String) {
        sessionMessages[sessionId] = msgs

        if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
            sessions[idx].updatedAt = Date()
            // Auto-generate title from first user message if still default
            if sessions[idx].title == "New Conversation", let firstUserMsg = msgs.first(where: { $0.role == .user }) {
                let clean = firstUserMsg.content.prefix(30).trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty {
                    sessions[idx].title = clean
                }
            }
        }

        saveToDisk()
    }

    /// Deletes a session and its message history.
    public func deleteSession(id: String) {
        sessions.removeAll(where: { $0.id == id })
        sessionMessages.removeValue(forKey: id)

        if currentSessionId == id {
            currentSessionId = sessions.first?.id ?? createSession().id
        }

        saveToDisk()
    }

    /// Renames a session.
    public func renameSession(id: String, newTitle: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].title = newTitle
        saveToDisk()
    }

    private func loadFromDisk() {
        let url = storageFileURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(PersistedData.self, from: data) else {
            // First run: Initialize default session
            let initial = createSession(title: "Hermes Assistant")
            currentSessionId = initial.id
            return
        }

        self.sessions = decoded.sessions
        self.sessionMessages = decoded.messages
        if let active = decoded.activeSessionId, sessions.contains(where: { $0.id == active }) {
            self.currentSessionId = active
        } else {
            self.currentSessionId = sessions.first?.id ?? createSession().id
        }
    }

    private func saveToDisk() {
        let dataToSave = PersistedData(
            sessions: sessions,
            messages: sessionMessages,
            activeSessionId: currentSessionId
        )
        if let encoded = try? JSONEncoder().encode(dataToSave) {
            try? encoded.write(to: storageFileURL, options: .atomic)
        }
    }
}
