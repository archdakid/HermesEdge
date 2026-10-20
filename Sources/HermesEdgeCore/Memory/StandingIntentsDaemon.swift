import Foundation

/// Trigger conditions for autonomous standing background intents.
public enum IntentCondition: Codable, Sendable, Equatable {
    case dailyAt(hour: Int, minute: Int)
    case recurringInterval(seconds: TimeInterval)
    case eventKitReminderDue
}

/// A persistent standing intent monitored and autonomously evaluated on-device.
public struct StandingIntent: Identifiable, Codable, Sendable {
    public let id: String
    public var title: String
    public var condition: IntentCondition
    public var prompt: String
    public var isEnabled: Bool
    public var lastEvaluatedAt: Date?
    public var lastTriggeredAt: Date?

    public init(
        id: String = UUID().uuidString,
        title: String,
        condition: IntentCondition,
        prompt: String,
        isEnabled: Bool = true,
        lastEvaluatedAt: Date? = nil,
        lastTriggeredAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.condition = condition
        self.prompt = prompt
        self.isEnabled = isEnabled
        self.lastEvaluatedAt = lastEvaluatedAt
        self.lastTriggeredAt = lastTriggeredAt
    }
}

/// Autonomous background daemon evaluating standing intents on Apple Silicon.
public actor StandingIntentsDaemon {
    public static let shared = StandingIntentsDaemon()

    private var intents: [StandingIntent]

    private nonisolated static var storageURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("standing_intents.json")
    }

    public init() {
        var loaded = Self.loadFromDisk(url: Self.storageURL)
        if loaded.isEmpty {
            loaded = Self.defaultIntents()
            Self.save(loaded, to: Self.storageURL)
        }
        self.intents = loaded
    }

    /// Evaluates all registered intents and triggers execution if criteria are met.
    public func evaluateAll(agent: AgentStateMachine, now: Date = Date()) async -> [String] {
        AppLogger.shared.log("Evaluating standing intents...", tag: "INTENT")
        var executed: [String] = []

        for i in 0..<intents.count {
            guard intents[i].isEnabled else { continue }
            let intent = intents[i]

            if shouldTrigger(intent: intent, now: now) {
                intents[i].lastTriggeredAt = now
                intents[i].lastEvaluatedAt = now
                executed.append(intent.title)

                AppLogger.shared.log("Standing intent triggered: \(intent.title)", tag: "INTENT")

                // Dispatch synthetic user prompt into agent
                let syntheticMsg = MessageEnvelope(
                    conversationId: "standing-intent-\(intent.id)",
                    role: .user,
                    content: intent.prompt
                )

                do {
                    _ = try await agent.processTurn(
                        conversationId: "standing-intent-\(intent.id)",
                        userMessage: syntheticMsg
                    ) { _ in }
                } catch {
                    AppLogger.shared.log("Error evaluating intent [\(intent.title)]: \(error.localizedDescription)", tag: "INTENT")
                }
            } else {
                intents[i].lastEvaluatedAt = now
            }
        }

        saveToDisk()
        return executed
    }

    public func register(intent: StandingIntent) {
        intents.removeAll(where: { $0.id == intent.id })
        intents.append(intent)
        saveToDisk()
    }

    public func activeIntents() -> [StandingIntent] {
        return intents
    }

    // MARK: - Evaluation Logic

    private func shouldTrigger(intent: StandingIntent, now: Date) -> Bool {
        let calendar = Calendar.current

        switch intent.condition {
        case .dailyAt(let targetHour, let targetMin):
            let currentHour = calendar.component(.hour, from: now)
            let currentMin = calendar.component(.minute, from: now)

            // Trigger window: within target hour and minute range
            guard currentHour == targetHour && abs(currentMin - targetMin) <= 15 else {
                return false
            }

            // Only fire once per calendar day
            if let last = intent.lastTriggeredAt, calendar.isDate(last, inSameDayAs: now) {
                return false
            }
            return true

        case .recurringInterval(let seconds):
            guard let last = intent.lastTriggeredAt else { return true }
            return now.timeIntervalSince(last) >= seconds

        case .eventKitReminderDue:
            // Check if at least 1 hour has elapsed since last check
            if let last = intent.lastTriggeredAt, now.timeIntervalSince(last) < 3600 {
                return false
            }
            return true
        }
    }

    private nonisolated static func defaultIntents() -> [StandingIntent] {
        let morningPlanner = StandingIntent(
            title: "Morning Routine & Focus Planner",
            condition: .dailyAt(hour: 8, minute: 0),
            prompt: "Good morning! Please check my active reminders and calendar events, and build a high-focus time block plan for today."
        )

        let consolidationIntent = StandingIntent(
            title: "Evening Memory Dreaming",
            condition: .dailyAt(hour: 22, minute: 0),
            prompt: "Review our completed interactions today and distill key preferences or learned rules into permanent memory."
        )

        return [morningPlanner, consolidationIntent]
    }

    private nonisolated static func loadFromDisk(url: URL) -> [StandingIntent] {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([StandingIntent].self, from: data) else {
            return []
        }
        return decoded
    }

    private nonisolated static func save(_ list: [StandingIntent], to url: URL) {
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func saveToDisk() {
        Self.save(intents, to: Self.storageURL)
    }
}
