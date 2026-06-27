//
//  AudioLabelRecorder.swift
//  MotionApp
//
//  Grava uma curta nota de voz e a transcreve (no dispositivo, quando possível)
//  para sugerir automaticamente o rótulo de um episódio. Tudo offline/local,
//  coerente com a proposta privacy-first do app.
//

import Foundation
import AVFoundation
import Speech

/// Pequeno guard thread-safe para evitar retomar uma continuation mais de uma
/// vez (o handler do `recognitionTask` pode disparar múltiplas vezes).
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func markResumed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

@MainActor
final class AudioLabelRecorder: NSObject, ObservableObject {

    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
        case finished
        case denied
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published var transcript: String = ""

    private var recorder: AVAudioRecorder?
    private(set) var fileName: String?

    private static let documentsDirectory: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }()

    var isRecording: Bool { phase == .recording }

    // MARK: - Permissões

    /// Pede microfone + reconhecimento de fala. Retorna `true` se ao menos o
    /// microfone foi liberado (transcrição é best-effort).
    func requestPermissions() async -> Bool {
        let micGranted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
        guard micGranted else {
            phase = .denied
            return false
        }

        _ = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        return true
    }

    // MARK: - Gravação

    func startRecording() {
        let name = "episode-label-\(UUID().uuidString).m4a"
        let url = Self.documentsDirectory.appendingPathComponent(name)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers])
            try session.setActive(true, options: [])

            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.record()
            recorder = rec
            fileName = name
            transcript = ""
            phase = .recording
        } catch {
            phase = .failed("Não foi possível iniciar a gravação.")
        }
    }

    func stopRecording() {
        guard let recorder, recorder.isRecording else { return }
        let url = recorder.url
        recorder.stop()
        self.recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])

        phase = .transcribing
        Task { await transcribe(url: url) }
    }

    // MARK: - Transcrição

    private func transcribe(url: URL) async {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "pt-BR")) ?? SFSpeechRecognizer(),
              recognizer.isAvailable
        else {
            // Sem transcrição: ainda há áudio salvo; usuário digita o rótulo.
            phase = .finished
            return
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

        do {
            let text = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                // `recognitionTask` pode chamar o handler várias vezes (resultados
                // parciais). Garantimos que a continuation seja retomada UMA vez.
                let resumed = ResumeGuard()
                recognizer.recognitionTask(with: request) { result, error in
                    if let error {
                        if resumed.markResumed() { cont.resume(throwing: error) }
                        return
                    }
                    if let result, result.isFinal {
                        if resumed.markResumed() {
                            cont.resume(returning: result.bestTranscription.formattedString)
                        }
                    }
                }
            }
            transcript = text
            phase = .finished
        } catch {
            // Falha de transcrição não é fatal: mantém o áudio e deixa o
            // usuário digitar o rótulo manualmente.
            phase = .finished
        }
    }

    // MARK: - Limpeza

    /// Remove o arquivo gravado caso o usuário cancele sem salvar.
    func discardRecording() {
        if let fileName {
            let url = Self.documentsDirectory.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: url)
        }
        fileName = nil
        transcript = ""
        phase = .idle
    }
}

