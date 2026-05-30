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
    @Binding var targetEpisodes: Int

    @State private var showMap = false
    @State private var mapPoints: [EpisodePoint] = []
    @State private var groupSeries: [SensorGroupSeries] = []
    @State private var showCombinedSensors = false

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
                                .frame(width: 50, alignment: .leading)
                            Text("\(format(ep.startMs)) → \(format(ep.endMs))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                }

                Button {
                    Task {
                        if let sid = sensorManager.lastSessionId {
                            mapPoints = await sensorManager.gatherEpisodePoints(forSession: sid)
                            showMap = !mapPoints.isEmpty
                        }
                    }
                } label: {
                    Label("Abrir mapa de episódios", systemImage: "map")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    Task {
                        if let sid = sensorManager.lastSessionId {
                            groupSeries = await sensorManager.populateGroupSeries(forSession: sid)
                            showCombinedSensors = true
                        }
                    }
                } label: {
                    Label("Abrir plot combined sensors", systemImage: "chart.xyaxis.line")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if !sensorManager.linkageMatrix.isEmpty {
                Text("Linkage rows: \(sensorManager.linkageMatrix.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(.background))
        .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 4)
        .onChange(of: W) { _, newW in
            // Se o usuário tinha pedido K > maxK quando havia mais janelas
            // e agora o cap caiu (reset ou nova coleta), aperta o valor pra
            // dentro do range. Evita estado inválido no Stepper.
            let clamped = min(max(targetEpisodes, minK), max(2, min(newW, 30)))
            if clamped != targetEpisodes { targetEpisodes = clamped }
        }
        .sheet(isPresented: $showMap) {
            EpisodesMapView(points: mapPoints)
                .ignoresSafeArea()
        }
        .sheet(isPresented: $showCombinedSensors) {
            CombinedSensorsChartView(
                groupSeries: groupSeries,
                episodes: sensorManager.episodes,
                displayTimezone: TimeZone.current
            )
            .padding()
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
                .foregroundStyle(W >= 2 ? .green : .secondary)
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
