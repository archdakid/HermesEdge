import Foundation
import Speech
import AVFoundation
import Combine

/// Crash-proof, on-device speech recognition and synthesis manager for offline voice interaction on iPhone 15 Pro.
@MainActor
public final class SpeechManager: NSObject, ObservableObject, SFSpeechRecognizerDelegate {
    public static let shared = SpeechManager()

    @Published public var isRecording: Bool = false
    @Published public var isSpeaking: Bool = false
    @Published public var liveTranscription: String = ""
    @Published public var isAuthorized: Bool = false
    @Published public var errorMessage: String? = nil

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    private let speechSynthesizer = AVSpeechSynthesizer()

    public override init() {
        super.init()
        speechRecognizer?.delegate = self
        checkAuthorization()
        AppLogger.shared.log("SpeechManager initialized (Authorized: \(isAuthorized)).", tag: "SPEECH")
    }

    public func checkAuthorization() {
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        let micStatus = AVAudioSession.sharedInstance().recordPermission
        isAuthorized = (speechStatus == .authorized && micStatus == .granted)
    }

    /// Requests Speech Recognition and Microphone permissions sequentially on MainActor.
    public func requestPermissions(completion: @escaping (Bool) -> Void) {
        AppLogger.shared.log("Requesting Speech Recognition permission...", tag: "SPEECH")
        SFSpeechRecognizer.requestAuthorization { [weak self] speechStatus in
            Task { @MainActor in
                AppLogger.shared.log("Speech Recognition status: \(speechStatus.rawValue)", tag: "SPEECH")
                if speechStatus != .authorized {
                    self?.errorMessage = "Speech Recognition permission was not granted."
                    completion(false)
                    return
                }

                AppLogger.shared.log("Requesting Microphone permission...", tag: "SPEECH")
                AVAudioSession.sharedInstance().requestRecordPermission { micGranted in
                    Task { @MainActor in
                        AppLogger.shared.log("Microphone granted: \(micGranted)", tag: "SPEECH")
                        self?.isAuthorized = micGranted
                        if !micGranted {
                            self?.errorMessage = "Microphone permission was not granted."
                        }
                        completion(micGranted)
                    }
                }
            }
        }
    }

    /// Toggles voice recording on or off safely.
    public func toggleRecording(onUpdate: @escaping (String) -> Void) {
        if isRecording {
            AppLogger.shared.log("User tapped mic to STOP recording.", tag: "SPEECH")
            stopRecording()
            return
        }

        AppLogger.shared.log("User tapped mic to START recording.", tag: "SPEECH")
        let micPermission = AVAudioSession.sharedInstance().recordPermission
        let speechStatus = SFSpeechRecognizer.authorizationStatus()

        if micPermission != .granted || speechStatus != .authorized {
            AppLogger.shared.log("Permissions missing (Mic: \(micPermission.rawValue), Speech: \(speechStatus.rawValue)). Requesting...", tag: "SPEECH")
            requestPermissions { [weak self] granted in
                if granted {
                    self?.errorMessage = "Permissions granted! Tap the mic again to speak."
                } else {
                    self?.errorMessage = "Microphone & Speech permissions required. Enable in iOS Settings -> HermesEdge."
                }
            }
            return
        }

        startRecordingSafely(onUpdate: onUpdate)
    }

    /// Starts streaming speech recognition with defensive guards against audio crashes.
    private func startRecordingSafely(onUpdate: @escaping (String) -> Void) {
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            errorMessage = "On-device speech recognition is not available."
            AppLogger.shared.log("Speech recognizer unavailable.", tag: "SPEECH")
            return
        }

        stopSpeaking()
        stopRecording()
        liveTranscription = ""
        errorMessage = nil

        AppLogger.shared.log("Configuring audio session for voice recording...", tag: "SPEECH")
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            let msg = "Audio session configuration failed: \(error.localizedDescription)"
            errorMessage = msg
            AppLogger.shared.log(msg, tag: "SPEECH")
            return
        }

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            errorMessage = "Could not initialize speech recognition request."
            return
        }

        if speechRecognizer.supportsOnDeviceRecognition {
            recognitionRequest.requiresOnDeviceRecognition = true
            AppLogger.shared.log("On-device offline speech recognition enabled.", tag: "SPEECH")
        }
        recognitionRequest.shouldReportPartialResults = true

        // Create fresh AVAudioEngine instance to avoid contaminated graph state
        let engine = AVAudioEngine()
        self.audioEngine = engine

        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        AppLogger.shared.log("Audio inputNode sampleRate=\(recordingFormat.sampleRate), channels=\(recordingFormat.channelCount)", tag: "SPEECH")

        guard recordingFormat.sampleRate > 0 && recordingFormat.channelCount > 0 else {
            errorMessage = "Audio hardware sample rate is 0. Please tap mic again."
            AppLogger.shared.log("Aborted: sampleRate=0", tag: "SPEECH")
            return
        }

        // Use format: nil to tap native output format safely
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
            isRecording = true
            AppLogger.shared.log("AVAudioEngine started successfully. Listening...", tag: "SPEECH")
        } catch {
            inputNode.removeTap(onBus: 0)
            let msg = "Audio engine failed to start: \(error.localizedDescription)"
            errorMessage = msg
            AppLogger.shared.log(msg, tag: "SPEECH")
            return
        }

        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result {
                let transcription = result.bestTranscription.formattedString
                Task { @MainActor in
                    self.liveTranscription = transcription
                    onUpdate(transcription)
                }
            }

            if let error = error {
                Task { @MainActor in
                    AppLogger.shared.log("Recognition task ended with error: \(error.localizedDescription)", tag: "SPEECH")
                    self.stopRecording()
                }
            } else if result?.isFinal ?? false {
                Task { @MainActor in
                    AppLogger.shared.log("Recognition task completed final result.", tag: "SPEECH")
                    self.stopRecording()
                }
            }
        }
    }

    /// Safely halts recording and deallocates audio engine.
    public func stopRecording() {
        if let engine = audioEngine {
            if engine.isRunning {
                engine.stop()
            }
            engine.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false
        AppLogger.shared.log("Recording stopped and audio engine cleared.", tag: "SPEECH")
    }

    /// Reads text aloud using iOS's neural text-to-speech voice completely offline.
    public func speak(text: String) {
        guard !text.isEmpty else { return }
        stopSpeaking()

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        isSpeaking = true
        speechSynthesizer.speak(utterance)
        AppLogger.shared.log("Speaking: \"\(text.prefix(40))...\"", tag: "SPEECH")
    }

    public func stopSpeaking() {
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
    }
}
