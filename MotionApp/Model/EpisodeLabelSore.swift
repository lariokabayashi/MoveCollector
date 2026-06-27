//
//  EpisodeLabelStore.swift
//  MotionApp
//
//  Armazena rótulos (texto + nota de voz opcional) atribuídos pelo usuário a
//  cada episódio de movimento. A chave é o `startMs` do episódio, que é estável
//  para uma mesma segmentação (mais robusto que o `id` UUID, que é regerado a
//  cada reprocessamento). Persiste em UserDefaults para sobreviver a relaunch.
//

import Foundation
import Combine

/// Rótulo de um episódio: um texto curto + caminho relativo (em Documents) de
/// uma nota de voz opcional que originou esse texto via transcrição.
struct EpisodeLabel: Codable, Equatable {
    var text: String
    var audioFileName: String?

    var hasAudio: Bool { audioFileName != nil }
}

@MainActor
final class EpisodeLabelStore: ObservableObject {

    @Published private(set) var labels: [String: EpisodeLabel] = [:]

    private let defaultsKey = "episodeLabels.v1"

    init() {
        load()
    }

    private func key(for episode: Episode) -> String { String(episode.startMs) }

    func label(for episode: Episode) -> EpisodeLabel? {
        labels[key(for: episode)]
    }

    func setLabel(_ label: EpisodeLabel, for episode: Episode) {
        labels[key(for: episode)] = label
        persist()
    }

    func removeLabel(for episode: Episode) {
        labels[key(for: episode)] = nil
        persist()
    }

    // MARK: - Persistência

    private func persist() {
        guard let data = try? JSONEncoder().encode(labels) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: EpisodeLabel].self, from: data)
        else { return }
        labels = decoded
    }
}

