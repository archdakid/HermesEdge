import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Executes Siri Shortcuts or passes inputs to predefined Shortcuts workflows.
/// This allows the assistant to execute actions in third-party apps that don't offer direct public APIs.
public final class ShortcutsTool: ToolContract, @unchecked Sendable {
    public let name = "run_siri_shortcut"
    public let description = "Run an existing Apple Siri Shortcut with optional text or data input to automate third-party apps."

    public var parametersJsonSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "shortcutName": [
                    "type": "string",
                    "description": "The exact name of the shortcut installed on the device"
                ],
                "input": [
                    "type": "string",
                    "description": "Text input or parameters to pass to the shortcut"
                ]
            ],
            "required": ["shortcutName"]
        ]
    }

    public init() {}

    public func execute(argumentsJson: String) async throws -> String {
        guard let data = argumentsJson.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let shortcutName = json["shortcutName"] as? String else {
            return "Error: Missing shortcutName."
        }

        let input = json["input"] as? String ?? ""
        guard let encodedName = shortcutName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let encodedInput = input.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return "Error: Could not encode URL parameters."
        }

        let urlString = "shortcuts://run-shortcut?name=\(encodedName)&input=text&text=\(encodedInput)"
        guard let url = URL(string: urlString) else {
            return "Error: Invalid shortcut URL generated."
        }

        #if canImport(UIKit)
        return await MainActor.run {
            if UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
                return "Successfully dispatched execution to Shortcut '\(shortcutName)'."
            } else {
                return "Error: Cannot open Shortcuts URL scheme."
            }
        }
        #else
        return "Simulated execution of shortcut '\(shortcutName)'."
        #endif
    }
}
