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
    @Binding var availableTargets: [Int]

    @State private var showMap = false
    @State private var mapPoints: [EpisodePoint] = []
    @State private var showCombinedSensors = false

    private static let tsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone.current
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Segmentação")
                    .font(.headline)
                Spacer()
                Button("Processar") {
                    sensorManager.runDailyClustering(t: targetEpisodes)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            HStack {
                Text("Episódios")
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $targetEpisodes) {
                    ForEach(availableTargets, id: \.self) { t in
                        Text("\(t)").tag(t)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
            }

            if !sensorManager.clusterLabels.isEmpty {
                EpisodeBarChartView(labels: sensorManager.clusterLabels)
                    .frame(height: 80)
            } else {
                Text("Sem dados de clustering ainda.")
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
                    showCombinedSensors = true
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
        .sheet(isPresented: $showMap) {
            EpisodesMapView(points: mapPoints)
                .ignoresSafeArea()
        }
//        .sheet(isPresented: $showCombinedSensors) {
//            CombinedSensorsChartView(
//                groupSeries: sensorManager.groupSeries,
//                episodes: sensorManager.episodes,
//                displayTimezone: TimeZone.current
//            )
//            .padding()
//        }
    }

    private func format(_ ms: Int64) -> String {
        let d = Date(timeIntervalSince1970: Double(ms) / 1000)
        return Self.tsFormatter.string(from: d)
    }
}

