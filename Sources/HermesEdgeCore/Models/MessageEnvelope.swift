import Foundation

/// Unified messaging model adopted from OpenClaw's channel routing architecture.
/// Normalizes inputs from UI, Siri, Action Button, WhatsApp, or Telegram.
public struct MessageEnvelope: Identifiable, Codable, Sendable {
    public let id: String
    public let conversationId: String
    public let channel: ChannelSource
    public let sender: SenderIdentity
    public let role: MessageRole
    public let content: String
    public let toolCalls: [PendingToolCall]?
    public let toolResultId: String?
    public let createdAt: Date
    public let metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        conversationId: String,
        channel: ChannelSource = .appUI,
        sender: SenderIdentity = .user,
        role: MessageRole,
        content: String,
        toolCalls: [PendingToolCall]? = nil,
        toolResultId: String? = nil,
        createdAt: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.conversationId = conversationId
        self.channel = channel
        self.sender = sender
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolResultId = toolResultId
        self.createdAt = createdAt
        self.metadata = metadata
    }
}

public enum MessageRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    case tool
}

public enum ChannelSource: String, Codable, Sendable {
    case appUI
    case siriVoice
    case actionButton
    case shortcuts
    case backgroundPush
    case externalRelay
}

public enum SenderIdentity: String, Codable, Sendable {
    case user
    case assistant
    case system
    case externalParticipant
}

public struct PendingToolCall: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let argumentsJson: String

    public init(id: String = UUID().uuidString, name: String, argumentsJson: String) {
        self.id = id
        self.name = name
        self.argumentsJson = argumentsJson
    }
}
