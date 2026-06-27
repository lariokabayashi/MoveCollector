//
//  EpisodeAudioLabelView.swift
//  MotionApp
//
//  Sheet para rotular um episódio por voz: grava uma nota curta, transcreve
//  automaticamente no dispositivo e usa o texto como rótulo (editável).
//

import SwiftUI

@available(iOS 26.0, *)
struct EpisodeAudioLabelView: View {
    let episode: Episode
    @ObservedObject var store: EpisodeLabelStore

    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = AudioLabelRecorder()

    @State private var labelText: String = ""
    @State private var permissionRequested = false

    private static let tsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = .current
        return f
    }()

    private func format(_ ms: Int64) -> String {
        Self.tsFormatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                VStack(spacing: 4) {
                    Text("Episódio")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(format(episode.startMs)) → \(format(episode.endMs))")
                        .font(.headline.monospacedDigit())
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))

                recordButton

                statusLine

                VStack(alignment: .leading, spacing: 8) {
                    Text("Rótulo")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("Ex.: corrida no parque", text: $labelText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...3)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Rotular por voz")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") {
                        recorder.discardRecording()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") { save() }
                        .disabled(labelText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let existing = store.label(for: episode) {
                    labelText = existing.text
                }
            }
            .onChange(of: recorder.transcript) { _, newValue in
                if !newValue.isEmpty { labelText = newValue }
            }
        }
    }

    @ViewBuilder
    private var recordButton: some View {
        Button {
            Task { await toggleRecording() }
        } label: {
            ZStack {
                Circle()
                    .fill(recorder.isRecording ? Color.red : Color.accentColor)
                    .frame(width: 96, height: 96)
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .disabled(recorder.phase == .transcribing)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch recorder.phase {
        case .idle:
            Text("Toque para gravar uma nota de voz")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .recording:
            Label("Gravando… toque para parar", systemImage: "waveform")
                .font(.footnote)
                .foregroundStyle(.red)
        case .transcribing:
            HStack(spacing: 8) {
                ProgressView()
                Text("Transcrevendo…")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        case .finished:
            Label("Transcrição pronta — ajuste o texto se quiser", systemImage: "checkmark.circle")
                .font(.footnote)
                .foregroundStyle(.green)
        case .denied:
            Text("Permissão de microfone negada. Habilite em Ajustes.")
                .font(.footnote)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
        case .failed(let message):
            Text(message)
                .font(.footnote)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
        }
    }

    private func toggleRecording() async {
        if recorder.isRecording {
            recorder.stopRecording()
            return
        }
        if !permissionRequested {
            permissionRequested = true
            let ok = await recorder.requestPermissions()
            guard ok else { return }
        }
        recorder.startRecording()
    }

    private func save() {
        let trimmed = labelText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.setLabel(EpisodeLabel(text: trimmed, audioFileName: recorder.fileName), for: episode)
        dismiss()
    }
}

