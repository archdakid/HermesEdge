import Foundation

/// Defines a structured tool schema executable by the Hermes agent loop on iOS.
public protocol ToolContract: Sendable {
    var name: String { get }
    var description: String { get }
    var parametersJsonSchema: [String: Any] { get }

    func execute(argumentsJson: String) async throws -> String
}

/// Boundary error adapted from OpenClaw's Apple Foundation Models Swift integration.
/// Thrown when the model attempts a tool call, halting text streaming so the orchestrator can take over.
public struct ToolBoundarySignal: Error, Sendable {
    public let toolCalls: [PendingToolCall]

    public init(toolCalls: [PendingToolCall]) {
        self.toolCalls = toolCalls
    }
}

/// Sendable container for tool schemas crossing actor boundaries.
public struct ToolSchemaPayload: @unchecked Sendable {
    public let raw: [[String: Any]]

    public init(_ raw: [[String: Any]]) {
        self.raw = raw
    }
}

/// Registry of tools available to the edge model on iOS.
public actor ToolRegistry {
    private var tools: [String: any ToolContract] = [:]

    public init() {}

    public func register(tool: any ToolContract) {
        tools[tool.name] = tool
    }

    public func get(name: String) -> (any ToolContract)? {
        return tools[name]
    }

    public func allSchemas() -> ToolSchemaPayload {
        let list: [[String: Any]] = tools.values.map { tool in
            [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": tool.parametersJsonSchema
                ]
            ]
        }
        return ToolSchemaPayload(list)
    }

    public func executeTool(call: PendingToolCall) async throws -> String {
        guard let tool = tools[call.name] else {
            return "Error: Unknown tool '\(call.name)'."
        }
        return try await tool.execute(argumentsJson: call.argumentsJson)
    }
}
