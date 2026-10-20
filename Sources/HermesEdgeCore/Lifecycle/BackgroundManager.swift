import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Manages iOS background execution, audio sessions, and memory lifecycle to prevent Jetsam kills.
public final class BackgroundManager: @unchecked Sendable {
    public static let shared = BackgroundManager()

    private var engine: (any InferenceEngine)?
    private var isAudioSessionActive = false

    private init() {
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        #endif
    }

    public func configure(engine: any InferenceEngine) {
        self.engine = engine
    }

    /// Activates background audio mode for hands-free continuous voice conversation (like ChatGPT Voice Mode).
    public func enableVoiceConversationMode() {
        #if canImport(AVFoundation)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .defaultToSpeaker])
            try session.setActive(true)
            isAudioSessionActive = true
            print("[BackgroundManager] Audio session active for background voice.")
        } catch {
            print("[BackgroundManager] Failed to activate audio session: \(error)")
        }
        #endif
    }

    public func disableVoiceConversationMode() {
        #if canImport(AVFoundation)
        do {
            try AVAudioSession.sharedInstance().setActive(false)
            isAudioSessionActive = false
        } catch {
            print("[BackgroundManager] Failed to deactivate audio session: \(error)")
        }
        #endif
    }

    /// Runs OpenClaw cognitive consolidation in the background.
    public func runDreamingConsolidation(
        memoryManager: MemoryManager,
        messages: [MessageEnvelope]
    ) async -> (promotedCount: Int, prunedCount: Int) {
        return await DreamingEngine.shared.runDreamingCycle(
            memoryManager: memoryManager,
            sessionMessages: messages
        )
    }

    /// Evaluates scheduled standing intents in the background.
    public func evaluateStandingIntents(agent: AgentStateMachine) async -> [String] {
        return await StandingIntentsDaemon.shared.evaluateAll(agent: agent)
    }

    @objc private func handleMemoryWarning() {
        AppLogger.shared.log("OS Memory Warning received from iOS runtime", tag: "JETSAM")
        #if canImport(UIKit)
        let state = UIApplication.shared.applicationState
        if state == .background {
            AppLogger.shared.log("App is in background during memory warning. Purging edge LLM buffers to satisfy Jetsam.", tag: "JETSAM")
            Task {
                await engine?.purgeModelFromRAM()
            }
        } else {
            AppLogger.shared.log("App is active in foreground. Retaining resident model context.", tag: "JETSAM")
        }
        #endif
    }

    @objc private func handleAppDidEnterBackground() {
        if !isAudioSessionActive {
            AppLogger.shared.log("App backgrounded without active voice session. Monitoring memory.", tag: "LIFECYCLE")
        }
    }
}
