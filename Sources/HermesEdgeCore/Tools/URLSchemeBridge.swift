import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Tool enabling the assistant to interact with external iOS apps via Deep Linking and x-callback-url.
/// Supports writing notes in Obsidian/Drafts/Bear, composing messages in WhatsApp, etc.
public final class URLSchemeTool: ToolContract, @unchecked Sendable {
    public let name = "interapp_deep_link"
    public let description = "Send data or open actions in installed third-party apps via URL schemes (e.g. WhatsApp, Drafts, Bear, Obsidian)."

    public var parametersJsonSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "app": [
                    "type": "string",
                    "enum": ["whatsapp", "drafts", "bear", "obsidian", "generic_url"],
                    "description": "The target app to communicate with"
                ],
                "action": [
                    "type": "string",
                    "description": "Specific action (e.g. 'send_message', 'create_note', 'append')"
                ],
                "payload": [
                    "type": "string",
                    "description": "The text content, note body, or message to pass to the app"
                ],
                "recipient": [
                    "type": "string",
                    "description": "Recipient phone or identifier if applicable (e.g. for WhatsApp)"
                ]
            ],
            "required": ["app", "payload"]
        ]
    }

    public init() {}

    public func execute(argumentsJson: String) async throws -> String {
        guard let data = argumentsJson.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let app = json["app"] as? String,
              let payload = json["payload"] as? String else {
            return "Error: Missing required app or payload parameter."
        }

        let encodedText = payload.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        var targetUrlString = ""

        switch app.lowercased() {
        case "whatsapp":
            let phone = json["recipient"] as? String ?? ""
            if phone.isEmpty {
                targetUrlString = "whatsapp://send?text=\(encodedText)"
            } else {
                targetUrlString = "https://api.whatsapp.com/send?phone=\(phone)&text=\(encodedText)"
            }

        case "drafts":
            targetUrlString = "drafts://x-callback-url/create?text=\(encodedText)"

        case "bear":
            targetUrlString = "bear://x-callback-url/create?text=\(encodedText)"

        case "obsidian":
            targetUrlString = "obsidian://new?content=\(encodedText)"

        default:
            targetUrlString = payload
        }

        guard let url = URL(string: targetUrlString) else {
            return "Error: Invalid URL produced for app '\(app)'."
        }

        #if canImport(UIKit)
        return await MainActor.run {
            if UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
                return "Successfully passed data to \(app)."
            } else {
                return "Error: App '\(app)' is not installed or URL scheme is not allowed."
            }
        }
        #else
        return "Dispatched deep link to \(app): \(targetUrlString)"
        #endif
    }
}
