import Foundation
import Speech
import AVFoundation
import Combine

/// On-device speech recognition and synthesis manager for offline voice interaction on iPhone 15 Pro.
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
    private let audioEngine = AVAudioEngine()
    private let speechSynthesizer = AVSpeechSynthesizer()

    public override init() {
        super.init()
        speechRecognizer?.delegate = self
        checkAuthorization()
    }

    public func checkAuthorization() {
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        let micStatus = AVAudioSession.sharedInstance().recordPermission

        isAuthorized = (speechStatus == .authorized && micStatus == .granted)
    }

    public func requestPermissions(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            AVAudioSession.sharedInstance().requestRecordPermission { micGranted in
                Task { @MainActor in
                    self.isAuthorized = (status == .authorized && micGranted)
                    completion(self.isAuthorized)
                }
            }
        }
    }

    /// Toggles voice recording on or off.
    public func toggleRecording(onUpdate: @escaping (String) -> Void) {
        if isRecording {
            stopRecording()
        } else {
            startRecording(onUpdate: onUpdate)
        }
    }

    /// Starts streaming speech recognition using Apple Neural Engine on-device models.
    public func startRecording(onUpdate: @escaping (String) -> Void) {
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            errorMessage = "On-device speech recognition is not available on this device."
            return
        }

        stopSpeaking()
        stopRecording()
        liveTranscription = ""
        errorMessage = nil

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            errorMessage = "Could not activate audio session: \(error.localizedDescription)"
            return
        }

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else { return }

        // Enforce 100% on-device offline recognition when supported on A17 Pro
        if speechRecognizer.supportsOnDeviceRecognition {
            recognitionRequest.requiresOnDeviceRecognition = true
        }
        recognitionRequest.shouldReportPartialResults = true

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            self.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            errorMessage = "Audio engine could not start: \(error.localizedDescription)"
            return
        }

        isRecording = true

        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result {
                let transcription = result.bestTranscription.formattedString
                Task { @MainActor in
                    self.liveTranscription = transcription
                    onUpdate(transcription)
                }
            }

            if error != nil || (result?.isFinal ?? false) {
                Task { @MainActor in
                    self.stopRecording()
                }
            }
        }
    }

    /// Stops listening and finalizes transcription.
    public func stopRecording() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false
    }

    /// Reads text aloud using iOS's neural text-to-speech voice.
    public func speak(text: String) {
        guard !text.isEmpty else { return }
        stopSpeaking()

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0

        isSpeaking = true
        speechSynthesizer.speak(utterance)
    }

    public func stopSpeaking() {
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
    }
}
