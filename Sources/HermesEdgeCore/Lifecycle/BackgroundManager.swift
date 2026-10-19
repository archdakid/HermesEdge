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

    @objc private func handleMemoryWarning() {
        print("[BackgroundManager] OS Memory Warning received! Purging edge LLM buffers to prevent Jetsam kill.")
        Task {
            await engine?.purgeModelFromRAM()
        }
    }

    @objc private func handleAppDidEnterBackground() {
        if !isAudioSessionActive {
            print("[BackgroundManager] App backgrounded without active voice session. Freeing inactive tensor memory.")
            Task {
                await engine?.purgeModelFromRAM()
            }
        }
    }
}
