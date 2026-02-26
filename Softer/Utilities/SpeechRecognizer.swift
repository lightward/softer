import Foundation
import Speech
import AVFoundation

@Observable
@MainActor
final class SpeechRecognizer {
    var isRecording = false
    var transcript = ""
    var permissionDenied = false

    private var audioEngine: AVAudioEngine?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?

    func startRecording() {
        // If already recording, stop instead
        if isRecording {
            stopRecording()
            return
        }

        Task {
            let authorized = await requestPermissions()
            guard authorized else {
                permissionDenied = true
                return
            }
            permissionDenied = false
            beginRecognition()
        }
    }

    func stopRecording() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        audioEngine = nil
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false
    }

    private func requestPermissions() async -> Bool {
        // Speech recognition permission
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else { return false }

        // Microphone permission
        #if os(iOS)
        let micGranted: Bool
        if AVAudioApplication.shared.recordPermission == .granted {
            micGranted = true
        } else {
            micGranted = await AVAudioApplication.requestRecordPermission()
        }
        return micGranted
        #elseif os(macOS)
        let micGranted: Bool
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            micGranted = true
        } else {
            micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        }
        return micGranted
        #endif
    }

    private func beginRecognition() {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            print("[Speech] Recognizer not available")
            return
        }

        recognizer.supportsOnDeviceRecognition = true

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }

        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            #endif

            engine.prepare()
            try engine.start()
        } catch {
            print("[Speech] Audio engine failed to start: \(error)")
            return
        }

        self.audioEngine = engine
        self.recognitionRequest = request
        self.isRecording = true

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }

                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }

                if error != nil || (result?.isFinal ?? false) {
                    self.stopRecording()
                }
            }
        }
    }
}
