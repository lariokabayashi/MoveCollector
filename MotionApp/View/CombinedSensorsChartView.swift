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

struct SensorGroupSeries: Identifiable {
    let id = UUID()
    let name: String
    let samples: [SensorGroupSample]
}

@available(iOS 26.0, *)
struct CombinedSensorsChartView: View {
    /// Por grupo de canais (já agregados em média), um array de samples.
    let groupSeries: [SensorGroupSeries]
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

// MARK: - Mock data + Preview
//
// Gera séries proceduralmente para visualizar a view sem precisar de uma
// sessão real no Core Data. Acc/Gyro têm padrões sinusoidais diferentes para
// dar contraste visual, e os episódios cobrem janelas contíguas que somam o
// range total da série.
@available(iOS 26.0, *)
enum CombinedSensorsMock {
    /// Origem fixa para reproduzir o mesmo preview entre re-renders.
    /// Fica no passado para o eixo X mostrar horas "redondas".
    static let startDate: Date = {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 5; comps.day = 23
        comps.hour = 9; comps.minute = 0; comps.second = 0
        return Calendar(identifier: .gregorian).date(from: comps) ?? Date()
    }()

    /// 30 min de coleta @ 1 amostra a cada 9s (≈ 200 pontos por série).
    static let totalDurationSec: TimeInterval = 30 * 60
    static let nSamples = 200

    /// Acelerômetro: 2 componentes sinusoidais somadas, picos onde o
    /// "usuário" mudaria de atividade. Amplitude em m/s² ~ [-2, 2].
    static func makeAccelerometerSeries() -> SensorGroupSeries {
        var samples: [SensorGroupSample] = []
        samples.reserveCapacity(nSamples)
        let step = totalDurationSec / Double(nSamples - 1)
        for i in 0..<nSamples {
            let t = Double(i) * step
            let value =
                1.4 * sin(2 * .pi * t / 120)        // ciclo de 2 min
              + 0.5 * sin(2 * .pi * t / 17)         // tremor ~17s
              + 0.2 * sin(2 * .pi * t / 3.1 + 0.6)  // ruído rápido
            samples.append(SensorGroupSample(
                timestamp: startDate.addingTimeInterval(t),
                value: value,
                group: "Accelerometer"
            ))
        }
        return SensorGroupSeries(name: "Accelerometer", samples: samples)
    }

    /// Giroscópio: amplitude menor, frequência levemente diferente —
    /// realista para coleta de marcha/atividade leve. rad/s ~ [-0.6, 0.6].
    static func makeGyroscopeSeries() -> SensorGroupSeries {
        var samples: [SensorGroupSample] = []
        samples.reserveCapacity(nSamples)
        let step = totalDurationSec / Double(nSamples - 1)
        for i in 0..<nSamples {
            let t = Double(i) * step
            let value =
                0.35 * cos(2 * .pi * t / 90)
              + 0.15 * sin(2 * .pi * t / 11 + 1.2)
              + 0.08 * sin(2 * .pi * t / 1.7)
            samples.append(SensorGroupSample(
                timestamp: startDate.addingTimeInterval(t),
                value: value,
                group: "Gyroscope"
            ))
        }
        return SensorGroupSeries(name: "Gyroscope", samples: samples)
    }

    /// 4 episódios cobrindo o range total. Boundaries alinhados a
    /// frações fixas pra ser fácil bater o olho no plot.
    static func makeEpisodes() -> [Episode] {
        let startMs = Int64(startDate.timeIntervalSince1970 * 1000)
        let totalMs = Int64(totalDurationSec * 1000)
        // 4 episódios de tamanhos variados (somam 100%):
        let fractions: [(Double, Double)] = [
            (0.00, 0.20),   // 6 min
            (0.20, 0.55),   // 10.5 min
            (0.55, 0.80),   // 7.5 min
            (0.80, 1.00),   // 6 min
        ]
        var episodes: [Episode] = []
        for (i, (a, b)) in fractions.enumerated() {
            let sMs = startMs + Int64(Double(totalMs) * a)
            let eMs = startMs + Int64(Double(totalMs) * b)
            episodes.append(Episode(
                label: i + 1,
                startWindowIdx: Int(Double(nSamples) * a),
                endWindowIdx: Int(Double(nSamples) * b),
                startMs: sMs,
                endMs: eMs
            ))
        }
        return episodes
    }

    static var seriesPreview: [SensorGroupSeries] {
        [makeAccelerometerSeries(), makeGyroscopeSeries()]
    }
}

@available(iOS 26.0, *)
#Preview("CombinedSensors — mock") {
    CombinedSensorsChartView(
        groupSeries: CombinedSensorsMock.seriesPreview,
        episodes: CombinedSensorsMock.makeEpisodes(),
        displayTimezone: TimeZone.current
    )
    .padding()
}

@available(iOS 26.0, *)
#Preview("CombinedSensors — vazio") {
    // Preview do estado "sem dados" pra confirmar que a view não crasha
    // quando groupSeries.first?.samples vier vazio.
    CombinedSensorsChartView(
        groupSeries: [],
        episodes: [],
        displayTimezone: TimeZone.current
    )
    .padding()
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
