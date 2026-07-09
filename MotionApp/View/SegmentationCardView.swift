//
//  SegmentationCardView.swift
//  MotionApp
//
//  UI para disparar o clustering hierárquico (Run_Daily_Clustering) e
//  visualizar os episódios resultantes (barras coloridas + mapa MapKit).
//

import SwiftUI

@available(iOS 26.0, *)
struct SegmentationCardView: View {
    @ObservedObject var sensorManager: SensorManagerViewModel
    @ObservedObject var labelStore: EpisodeLabelStore
    @Binding var targetEpisodes: Int

    /// Episódio cujo rótulo por voz está sendo editado (dispara o sheet).
    @State private var labelingEpisode: Episode?

    // Usamos `.sheet(item:)` (em vez de `.sheet(isPresented:)`) porque os dados
    // são carregados de forma assíncrona logo antes de apresentar. Com
    // `isPresented`, o SwiftUI capturava o conteúdo do sheet com os arrays ainda
    // vazios na 1ª apresentação (mapa/gráfico em branco no primeiro toque).
    // Passando o dado via `item`, o sheet é sempre construído com o valor pronto.
    @State private var mapData: MapEpisodesData?
    @State private var combinedData: CombinedSensorsData?

    private struct MapEpisodesData: Identifiable {
        let id = UUID()
        let points: [EpisodePoint]
    }

    private struct CombinedSensorsData: Identifiable {
        let id = UUID()
        let series: [SensorGroupSeries]
    }

    private static let tsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone.current
        return f
    }()

    /// Segundos por janela = `windowSize / sensorFrequencyHz` = 300/20 = 15.
    private var secondsPerWindow: Double {
        Double(AppConstants().windowSize) / AppConstants().sensorFrequencyHz
    }

    /// W (número de janelas coletadas) — fonte para o range dinâmico de K.
    private var W: Int { sensorManager.windowCount }

    /// K máximo permitido pelo `fcluster_custom`: não pode passar de W.
    /// Floor em 2 (precisa de pelo menos 2 clusters pra fazer cut).
    /// Teto em 30 só pra não deixar o stepper subir infinitamente em coletas
    /// gigantes — pra precisão maior, o usuário ainda pode escolher exatamente
    /// o valor desejado tocando no número.
    private var maxK: Int { max(2, min(W, 30)) }

    /// K mínimo: 2 (cluster trivial só com 1 grupo é inútil).
    private var minK: Int { 2 }

    /// Pode processar? Só faz sentido se W >= 2.
    private var canProcess: Bool { W >= 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Segmentação")
                    .font(.headline)
                Spacer()
                Button("Processar") {
                    // Clamp defensivo: se W mudou desde a última seleção do
                    // stepper (ex.: usuário deixou cair de 20→8 janelas por
                    // alguma razão), evita pedir K > W que iria virar erro.
                    let k = min(max(targetEpisodes, minK), maxK)
                    targetEpisodes = k
                    sensorManager.runDailyClustering(t: k)
                }
                .buttonStyle(.bordered)
                .tint(.brandBlue)
                .controlSize(.small)
                .disabled(!canProcess)
            }

            // Contexto: quanto dado o usuário tem em mãos.
            contextLine

            // Seleção de K via Stepper — preciso, integer-nativo, range dinâmico.
            HStack {
                Text("Episódios alvo")
                    .foregroundStyle(.secondary)
                Spacer()
                Stepper(value: $targetEpisodes, in: minK...maxK, step: 1) {
                    Text("\(targetEpisodes)")
                        .font(.body.monospacedDigit())
                        .frame(minWidth: 28, alignment: .trailing)
                }
                .fixedSize()
                .disabled(!canProcess)
            }

            if !sensorManager.clusterLabels.isEmpty {
                EpisodeBarChartView(labels: sensorManager.clusterLabels)
                    .frame(height: 80)
            } else {
                Text(canProcess
                     ? "Toque em Processar para gerar episódios."
                     : "Coletando janelas… aguarde pelo menos 30 s.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            // Lista compacta de episódios com timestamps em fuso local.
            if !sensorManager.episodes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(sensorManager.episodes) { ep in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(EpisodesMapView.color(for: ep.label))
                                .frame(width: 8, height: 8)
                            Text("Ep \(ep.label)")
                                .font(.caption)
                                .frame(width: 44, alignment: .leading)
                            if let label = labelStore.label(for: ep), !label.text.isEmpty {
                                Text(label.text)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                            } else {
                                Text("\(format(ep.startMs)) → \(format(ep.endMs))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                labelingEpisode = ep
                            } label: {
                                Image(systemName: labelStore.label(for: ep)?.hasAudio == true
                                      ? "mic.fill" : "mic")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }

                Button {
                    Task {
                        if let sid = sensorManager.displaySessionId {
                            let points = await sensorManager.gatherEpisodePoints(
                                forSession: sid, episodes: sensorManager.episodes)
                            if !points.isEmpty {
                                mapData = MapEpisodesData(points: points)
                            }
                        }
                    }
                } label: {
                    Label("Abrir mapa de episódios", systemImage: "map")
                }
                .buttonStyle(.bordered)
                .tint(.brandBlue)
                .controlSize(.small)

                Button {
                    Task {
                        if let sid = sensorManager.displaySessionId {
                            let series = await sensorManager.populateGroupSeries(forSession: sid)
                            combinedData = CombinedSensorsData(series: series)
                        }
                    }
                } label: {
                    Label("Abrir gráfico de sensores combinados", systemImage: "chart.xyaxis.line")
                }
                .buttonStyle(.bordered)
                .tint(.brandBlue)
                .controlSize(.small)
            }

            if !sensorManager.linkageMatrix.isEmpty {
                Text("Linkage rows: \(sensorManager.linkageMatrix.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .cardStyle()
        .onChange(of: W) { _, newW in
            // Se o usuário tinha pedido K > maxK quando havia mais janelas
            // e agora o cap caiu (reset ou nova coleta), aperta o valor pra
            // dentro do range. Evita estado inválido no Stepper.
            let clamped = min(max(targetEpisodes, minK), max(2, min(newW, 30)))
            if clamped != targetEpisodes { targetEpisodes = clamped }
        }
        .sheet(item: $mapData) { data in
            EpisodesMapView(points: data.points)
        }
        .sheet(item: $combinedData) { data in
            CombinedSensorsChartView(
                groupSeries: data.series,
                episodes: sensorManager.episodes,
                displayTimezone: TimeZone.current
            )
            .padding()
        }
        .sheet(item: $labelingEpisode) { ep in
            EpisodeAudioLabelView(episode: ep, store: labelStore)
        }
    }

    /// Linha de contexto: "X janelas coletadas (≈ Y min) — máx K = Z".
    /// Dá ao usuário a noção do que está disponível antes dele escolher K.
    @ViewBuilder
    private var contextLine: some View {
        let totalSec = Double(W) * secondsPerWindow
        let minutes = totalSec / 60
        HStack(spacing: 6) {
            Image(systemName: W >= 2 ? "checkmark.circle" : "clock")
                .font(.caption)
                .foregroundStyle(W >= 2 ? Color.brandGreen : Color.secondary)
            Group {
                if W == 0 {
                    Text("Aguardando 1ª janela (≥ 15 s)")
                } else if W == 1 {
                    Text("1 janela (≈ 15 s) — colete mais para segmentar")
                } else {
                    Text("\(W) janela\(W == 1 ? "" : "s") ")
                        + Text("(≈ \(formatMinutes(minutes))) — máx K = \(maxK)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func format(_ ms: Int64) -> String {
        let d = Date(timeIntervalSince1970: Double(ms) / 1000)
        return Self.tsFormatter.string(from: d)
    }

    private func formatMinutes(_ minutes: Double) -> String {
        if minutes < 1 {
            return "\(Int(minutes * 60)) s"
        }
        if minutes < 60 {
            return String(format: "%.1f min", minutes)
        }
        let h = Int(minutes) / 60
        let m = Int(minutes) % 60
        return "\(h) h \(m) min"
    }
}


