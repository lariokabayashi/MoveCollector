//
//  CombinedSensorsChartView.swift
//  MotionApp
//
//  Equivalente nativo do `combined_sensors.html` do Python (Plotly).
//  Mostra, em painéis empilhados, a média por grupo de canais (acc, gyro,
//  GPS) sobre o tempo, com linhas verticais nos boundaries de cada episódio
//  e um cabeçalho mostrando os IDs dos episódios.
//

import SwiftUI
import Charts

/// Uma amostra agregada por grupo, pronta para o Chart.
struct SensorGroupSample: Identifiable {
    let id = UUID()
    let timestamp: Date
    let value: Double
    let group: String
}

@available(iOS 26.0, *)
struct CombinedSensorsChartView: View {
    /// Por grupo de canais (já agregados em média), um array de samples.
    let groupSeries: [(name: String, samples: [SensorGroupSample])]
    /// Episódios para desenhar boundaries verticais + faixa de IDs no topo.
    let episodes: [Episode]
    /// Timezone para o eixo X (mesmo papel do `America/Sao_Paulo` no Python).
    let displayTimezone: TimeZone

    var body: some View {
        VStack(spacing: 12) {
            // Faixa de episódios no topo (label centralizado, lateral = largura).
            EpisodeStripView(episodes: episodes,
                             rangeStart: groupSeries.first?.samples.first?.timestamp ?? Date(),
                             rangeEnd: groupSeries.first?.samples.last?.timestamp ?? Date())
                .frame(height: 32)

            ForEach(groupSeries.indices, id: \.self) { i in
                let g = groupSeries[i]
                VStack(alignment: .leading, spacing: 4) {
                    Text(g.name).font(.caption).foregroundStyle(.secondary)
                    Chart {
                        ForEach(g.samples) { s in
                            LineMark(
                                x: .value("t", s.timestamp),
                                y: .value(g.name, s.value)
                            )
                            .foregroundStyle(.primary)
                        }
                        // Boundaries verticais — mesma semântica do `add_vline` Python.
                        ForEach(episodes) { ep in
                            RuleMark(x: .value("ep_start", Date(timeIntervalSince1970: Double(ep.startMs) / 1000)))
                                .foregroundStyle(.gray.opacity(0.5))
                                .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 2]))
                            RuleMark(x: .value("ep_end", Date(timeIntervalSince1970: Double(ep.endMs) / 1000)))
                                .foregroundStyle(.gray.opacity(0.5))
                                .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 2]))
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic) { v in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel(format: .dateTime.hour().minute(), centered: false)
                        }
                    }
                    .frame(height: 110)
                }
            }
        }
        .environment(\.timeZone, displayTimezone)
    }
}

/// Faixa de IDs de episódio no topo (equivalente ao painel "Episodes" do Plotly).
@available(iOS 26.0, *)
private struct EpisodeStripView: View {
    let episodes: [Episode]
    let rangeStart: Date
    let rangeEnd: Date

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.gray.opacity(0.1))
                ForEach(episodes) { ep in
                    let total = max(1, rangeEnd.timeIntervalSince(rangeStart))
                    let startFrac = max(0, Date(timeIntervalSince1970: Double(ep.startMs) / 1000)
                                            .timeIntervalSince(rangeStart) / total)
                    let endFrac = min(1, Date(timeIntervalSince1970: Double(ep.endMs) / 1000)
                                            .timeIntervalSince(rangeStart) / total)
                    let x = geo.size.width * CGFloat(startFrac)
                    let w = max(2, geo.size.width * CGFloat(endFrac - startFrac))
                    Rectangle()
                        .fill(EpisodesMapView.color(for: ep.label))
                        .frame(width: w, height: 6)
                        .offset(x: x, y: 13)
                    Text("\(ep.label)")
                        .font(.caption2)
                        .frame(width: w, alignment: .center)
                        .offset(x: x, y: -2)
                }
            }
        }
    }
}
