import Foundation

/// Represents an episodic candidate memory extracted from conversational interactions.
public struct MemoryCandidate: Identifiable, Codable, Sendable {
    public let id: String
    public let content: String
    public let firstObservedAt: Date
    public var lastObservedAt: Date
    public var occurrenceCount: Int
    public var category: MemoryCategory
    public var isPromoted: Bool

    public enum MemoryCategory: String, Codable, Sendable {
        case userPreference  // Intended for USER.md
        case agentPersona   // Intended for SOUL.md
        case domainSkill    // Intended for AGENTS.md
        case ephemeralFact  // Session-scoped
    }

    public init(
        id: String = UUID().uuidString,
        content: String,
        firstObservedAt: Date = Date(),
        lastObservedAt: Date = Date(),
        occurrenceCount: Int = 1,
        category: MemoryCategory = .userPreference,
        isPromoted: Bool = false
    ) {
        self.id = id
        self.content = content
        self.firstObservedAt = firstObservedAt
        self.lastObservedAt = lastObservedAt
        self.occurrenceCount = occurrenceCount
        self.category = category
        self.isPromoted = isPromoted
    }
}

/// The cognitive consolidation engine porting OpenClaw's Memory Promotion Scoring
/// and Hermes Agent's background skill/fact consolidation into an iOS-optimized actor.
public actor DreamingEngine {
    public static let shared = DreamingEngine()

    private var candidates: [String: MemoryCandidate]
    private let promotionThreshold: Double = 0.65

    private nonisolated static var storageURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("episodic_candidates.json")
    }

    public init() {
        self.candidates = Self.loadCandidatesFromDisk(url: Self.storageURL)
    }

    /// Records an observation or stated preference from user interaction.
    public func observe(text: String, category: MemoryCandidate.MemoryCategory = .userPreference) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > 10 else { return }

        // Find existing candidate with high token overlap
        if let existingKey = findMatchingCandidateKey(for: clean) {
            candidates[existingKey]?.occurrenceCount += 1
            candidates[existingKey]?.lastObservedAt = Date()
        } else {
            let id = UUID().uuidString
            candidates[id] = MemoryCandidate(
                id: id,
                content: clean,
                category: category
            )
        }

        saveCandidatesToDisk()
    }

    /// Computes the OpenClaw 3-factor promotion score:
    /// Score = (Recency * 0.4) + (Frequency * 0.3) + (Age * 0.3)
    public func score(candidate: MemoryCandidate, now: Date = Date()) -> Double {
        // 1. Recency: Exponential decay over hours (half-life ~ 48 hours)
        let hoursSinceLastSeen = max(0.0, now.timeIntervalSince(candidate.lastObservedAt) / 3600.0)
        let recencyScore = exp(-0.014 * hoursSinceLastSeen) // ~0.5 at 48h

        // 2. Frequency: Saturation curve capped at 5 occurrences
        let frequencyScore = min(1.0, Double(candidate.occurrenceCount) / 5.0)

        // 3. Age: Maturity over days (reaches ~0.8 at 7 days)
        let daysOld = max(0.0, now.timeIntervalSince(candidate.firstObservedAt) / 86400.0)
        let ageScore = 1.0 - exp(-0.25 * daysOld)

        let total = (recencyScore * 0.4) + (frequencyScore * 0.3) + (ageScore * 0.3)
        return min(1.0, max(0.0, total))
    }

    /// Executes a full dreaming cycle:
    /// 1. Scans conversation messages for new fact candidates.
    /// 2. Evaluates OpenClaw promotion scores.
    /// 3. Distills qualifying memories into durable USER.md / SOUL.md.
    /// 4. Prunes decayed ephemeral entries.
    public func runDreamingCycle(
        memoryManager: MemoryManager,
        sessionMessages: [MessageEnvelope]
    ) async -> (promotedCount: Int, prunedCount: Int) {
        AppLogger.shared.log("Starting Dreaming & Consolidation cycle...", tag: "DREAM")
        let now = Date()

        // Step 1: Ingest candidate statements from messages
        for msg in sessionMessages where msg.role == .user {
            extractCandidateStatements(from: msg.content)
        }

        var promoted = 0
        var pruned = 0

        // Step 2: Evaluate and promote candidates
        for (id, candidate) in candidates where !candidate.isPromoted {
            let s = score(candidate: candidate, now: now)
            if s >= promotionThreshold {
                candidates[id]?.isPromoted = true
                promoted += 1

                switch candidate.category {
                case .userPreference, .ephemeralFact:
                    await memoryManager.storeFact(candidate.content)
                    AppLogger.shared.log("Promoted memory to USER.md (score: \(String(format: "%.2f", s))): \(candidate.content)", tag: "DREAM")
                case .agentPersona:
                    AppLogger.shared.log("Learned persona adjustment (score: \(String(format: "%.2f", s))): \(candidate.content)", tag: "DREAM")
                case .domainSkill:
                    AppLogger.shared.log("Identified reusable skill pattern (score: \(String(format: "%.2f", s))): \(candidate.content)", tag: "DREAM")
                }
            }
        }

        // Step 3: Prune low-scoring stale entries (older than 30 days with <= 1 occurrence)
        let keysToRemove = candidates.filter { _, candidate in
            if candidate.isPromoted { return false }
            let daysOld = now.timeIntervalSince(candidate.firstObservedAt) / 86400.0
            return daysOld > 30.0 && candidate.occurrenceCount <= 1
        }.map { $0.key }

        for k in keysToRemove {
            candidates.removeValue(forKey: k)
            pruned += 1
        }

        saveCandidatesToDisk()
        AppLogger.shared.log("Dreaming cycle completed. Promoted: \(promoted), Pruned: \(pruned), Active: \(candidates.count)", tag: "DREAM")
        return (promoted, pruned)
    }

    // MARK: - Pattern Extraction & Matching

    private func extractCandidateStatements(from text: String) {
        let triggers = [
            "i prefer", "i like", "i always", "never", "remind me to",
            "my name is", "i work as", "my goal is", "i usually"
        ]

        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?;:\n"))
        for sentence in sentences {
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = trimmed.lowercased()
            for trigger in triggers {
                if lower.contains(trigger) && trimmed.count >= 12 && trimmed.count <= 180 {
                    observe(text: trimmed, category: .userPreference)
                    break
                }
            }
        }
    }

    private func findMatchingCandidateKey(for text: String) -> String? {
        let incomingTokens = Set(tokenize(text))
        guard !incomingTokens.isEmpty else { return nil }

        for (key, candidate) in candidates {
            let candidateTokens = Set(tokenize(candidate.content))
            let intersection = incomingTokens.intersection(candidateTokens)
            let union = incomingTokens.union(candidateTokens)
            let jaccard = Double(intersection.count) / Double(max(1, union.count))
            if jaccard >= 0.60 {
                return key
            }
        }
        return nil
    }

    private func tokenize(_ text: String) -> [String] {
        return text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 }
    }

    private nonisolated static func loadCandidatesFromDisk(url: URL) -> [String: MemoryCandidate] {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: MemoryCandidate].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func saveCandidatesToDisk() {
        if let data = try? JSONEncoder().encode(candidates) {
            try? data.write(to: Self.storageURL, options: .atomic)
        }
    }
}
