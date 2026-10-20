import Foundation
import EventKit

/// Native tool allowing the agent to read and write Calendar Events and Reminders on iOS.
public final class EventKitTool: ToolContract, @unchecked Sendable {
    public let name = "system_calendar_reminders"
    public let description = "Read, create, or modify user Reminders and Calendar events on the device."

    public var parametersJsonSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "action": [
                    "type": "string",
                    "enum": ["create_reminder", "list_reminders", "create_event", "list_events"],
                    "description": "The calendar/reminder operation to perform"
                ],
                "title": [
                    "type": "string",
                    "description": "Title of the reminder or calendar event"
                ],
                "dueDate": [
                    "type": "string",
                    "description": "ISO-8601 formatted date/time for the event or reminder"
                ],
                "notes": [
                    "type": "string",
                    "description": "Optional notes or details for the item"
                ]
            ],
            "required": ["action"]
        ]
    }

    private let eventStore = EKEventStore()

    public init() {}

    public func execute(argumentsJson: String) async throws -> String {
        guard let data = argumentsJson.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = json["action"] as? String else {
            return "Error: Invalid JSON arguments."
        }

        switch action {
        case "create_reminder":
            let title = json["title"] as? String ?? "New Reminder"
            let notes = json["notes"] as? String
            return try await createReminder(title: title, notes: notes)
            
        case "list_reminders":
            return try await listReminders()

        case "create_event":
            let title = json["title"] as? String ?? "New Event"
            return try await createEvent(title: title)

        default:
            return "Action '\(action)' not implemented."
        }
    }

    private func ensureRemindersPermission() async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        AppLogger.shared.log("Current Reminders authorizationStatus: \(status.rawValue)", tag: "EVENTKIT")
        if status == .fullAccess || status == .authorized {
            return true
        }

        AppLogger.shared.log("Requesting full access to Reminders from iOS...", tag: "EVENTKIT")
        if #available(iOS 17.0, *) {
            do {
                let granted = try await eventStore.requestFullAccessToReminders()
                AppLogger.shared.log("Reminders full access request result: \(granted)", tag: "EVENTKIT")
                return granted
            } catch {
                AppLogger.shared.log("Reminders access error: \(error.localizedDescription)", tag: "EVENTKIT")
                return false
            }
        } else {
            return await withCheckedContinuation { cont in
                eventStore.requestAccess(to: .reminder) { ok, _ in
                    cont.resume(returning: ok)
                }
            }
        }
    }

    private func ensureCalendarPermission() async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        AppLogger.shared.log("Current Calendar authorizationStatus: \(status.rawValue)", tag: "EVENTKIT")
        if status == .fullAccess || status == .authorized {
            return true
        }

        AppLogger.shared.log("Requesting full access to Calendar from iOS...", tag: "EVENTKIT")
        if #available(iOS 17.0, *) {
            do {
                let granted = try await eventStore.requestFullAccessToEvents()
                AppLogger.shared.log("Calendar full access request result: \(granted)", tag: "EVENTKIT")
                return granted
            } catch {
                AppLogger.shared.log("Calendar access error: \(error.localizedDescription)", tag: "EVENTKIT")
                return false
            }
        } else {
            return await withCheckedContinuation { cont in
                eventStore.requestAccess(to: .event) { ok, _ in
                    cont.resume(returning: ok)
                }
            }
        }
    }

    private func createReminder(title: String, notes: String?) async throws -> String {
        guard await ensureRemindersPermission() else {
            return "Permission to access Reminders was not granted. Please allow Reminders in iOS Settings -> Privacy & Security -> Reminders."
        }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title
        reminder.notes = notes
        reminder.calendar = eventStore.defaultCalendarForNewReminders()

        try eventStore.save(reminder, commit: true)
        AppLogger.shared.log("Successfully saved reminder: '\(title)'", tag: "EVENTKIT")
        return "Successfully created reminder: '\(title)'"
    }

    private func listReminders() async throws -> String {
        guard await ensureRemindersPermission() else {
            return "Permission to access Reminders was not granted. Please allow Reminders in iOS Settings -> Privacy & Security -> Reminders."
        }

        let predicate = eventStore.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        return await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                let items = (reminders ?? []).prefix(10).map { "- \($0.title ?? "Untitled")" }.joined(separator: "\n")
                continuation.resume(returning: items.isEmpty ? "No active reminders found." : items)
            }
        }
    }

    private func createEvent(title: String) async throws -> String {
        guard await ensureCalendarPermission() else {
            return "Permission to access Calendar was not granted. Please allow Calendars in iOS Settings -> Privacy & Security -> Calendars."
        }

        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = Date()
        event.endDate = Date().addingTimeInterval(3600)
        event.calendar = eventStore.defaultCalendarForNewEvents

        try eventStore.save(event, span: .thisEvent)
        AppLogger.shared.log("Successfully saved calendar event: '\(title)'", tag: "EVENTKIT")
        return "Created calendar event: '\(title)' for 1 hour starting now."
    }
}
