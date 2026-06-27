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

    // MARK: - Estado de seleção
    //
    // A view mostra SEMPRE o range completo (sem zoom/pan) — opção deliberada por
    // robustez: gestos customizados brigavam com o dismiss do sheet e com a
    // seleção. A única interação é o toque para inspecionar um instante.
    //
    /// Instante selecionado para o tooltip (compartilhado entre os painéis → o
    /// indicador vertical e os valores aparecem alinhados em todos eles).
    @State private var selectedDate: Date? = nil

    /// Largura FIXA reservada para os rótulos do eixo Y em TODOS os painéis e na
    /// faixa de episódios. É o que garante o alinhamento horizontal pedido pelo
    /// orientador: como o inset esquerdo de cada Chart é determinado pela largura
    /// do eixo Y, fixá-la torna a área de plotagem idêntica em todos → as linhas
    /// tracejadas dos episódios batem exatamente com os segmentos coloridos do
    /// topo. (Com as séries todas em z-score a magnitude é comparável entre
    /// painéis, mas fixar a largura segue importante para travar o alinhamento.)
    private let yAxisLabelWidth: CGFloat = 48

    /// Range completo do eixo X, derivado do menor/maior timestamp entre TODAS as
    /// séries. Compartilhado por todos os painéis → mantém a sincronização
    /// horizontal entre acc, gyro, GPS e a faixa de episódios.
    private var fullDomain: ClosedRange<Date>? {
        let starts = groupSeries.compactMap { $0.samples.first?.timestamp }
        let ends = groupSeries.compactMap { $0.samples.last?.timestamp }
        guard let lo = starts.min(), let hi = ends.max(), lo < hi else { return nil }
        return lo...hi
    }

    /// Cor distinta por grupo, para legibilidade entre painéis e no tooltip
    /// (requisito 1.4 — "legendas, cores ... legíveis"). Com as séries em z-score
    /// as magnitudes já são comparáveis; cada painel ainda tem seu eixo Y próprio.
    private func color(for name: String) -> Color {
        switch name {
        case "Accelerometer":  return .blue
        case "Gyroscope":      return .green
        case "GPS":            return .orange
        default:               return .primary
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            header

            // Faixa de episódios no topo — agora é um Chart com o MESMO eixo X
            // (domínio + config) e a MESMA largura de eixo Y dos painéis, então
            // os segmentos coloridos ficam perfeitamente alinhados com as linhas
            // tracejadas de boundary desenhadas em cada painel.
            episodeStrip

            ForEach(groupSeries.indices, id: \.self) { i in
                panel(for: groupSeries[i], showXLabels: i == groupSeries.count - 1)
            }
        }
        .environment(\.timeZone, displayTimezone)
    }

    // MARK: - Faixa de episódios (equivalente ao painel "Episodes" do Plotly)
    @ViewBuilder
    private var episodeStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Episódios").font(.caption).foregroundStyle(.secondary)
            Chart {
                ForEach(episodes) { ep in
                    RectangleMark(
                        xStart: .value("início", dateFromMs(ep.startMs)),
                        xEnd: .value("fim", dateFromMs(ep.endMs)),
                        yStart: .value("y0", 0.0),
                        yEnd: .value("y1", 1.0)
                    )
                    .foregroundStyle(EpisodeColorPalette.color(for: ep.label))
                    .annotation(position: .overlay) {
                        Text("\(ep.label)")
                            .font(.caption2).bold()
                            .foregroundStyle(.white)
                    }
                }
                boundaryRules
                selectionRule
            }
            .chartYScale(domain: 0...1)
            .chartXScale(domain: fullDomain ?? Date()...Date())
            .chartYAxis { yAxis(for: nil) }
            .chartXAxis { sharedXAxis(showLabels: false) }
            .frame(height: 34)
        }
    }

    // MARK: - Cabeçalho
    @ViewBuilder
    private var header: some View {
        HStack {
            Text("Toque p/ inspecionar")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Painel de uma série
    @ViewBuilder
    private func panel(for g: SensorGroupSeries, showXLabels: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(color(for: g.name)).frame(width: 8, height: 8)
                Text(g.name).font(.caption).foregroundStyle(.secondary)
                if let sel = selectedDate, let v = value(of: g, at: sel) {
                    Spacer()
                    Text(formatValue(v, for: g.name))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(color(for: g.name))
                }
            }

            Chart {
                ForEach(g.samples) { s in
                    LineMark(
                        x: .value("t", s.timestamp),
                        y: .value(g.name, s.value)
                    )
                    .foregroundStyle(color(for: g.name))
                }
                // Fallback: uma LineMark com 1 ponto só não desenha nada
                // (precisa de ≥ 2 vértices). Garante que uma série mínima —
                // ex.: 1 único fix de GPS numa coleta parada — apareça.
                if g.samples.count == 1, let only = g.samples.first {
                    PointMark(
                        x: .value("t", only.timestamp),
                        y: .value(g.name, only.value)
                    )
                    .foregroundStyle(color(for: g.name))
                }
                // Boundaries verticais — mesma semântica do `add_vline` Python.
                boundaryRules
                // Indicador vertical do tooltip — sincronizado entre painéis.
                selectionRule
            }
            // Eixo Y próprio, ajustado aos dados DESTE painel (com padding).
            // Mesmo com z-score, manter domínio explícito protege contra um range
            // degenerado (série quase constante) em que a linha não seria
            // desenhada. Ver `yDomain(for:)`.
            .chartYScale(domain: yDomain(for: g))
            // Domínio X COMPLETO e idêntico em todos os painéis → sincronização
            // horizontal entre acc, gyro, GPS e a faixa de episódios.
            .chartXScale(domain: fullDomain ?? Date()...Date())
            // Largura de eixo Y FIXA → alinhamento horizontal com a faixa de
            // episódios e os demais painéis.
            .chartYAxis { yAxis(for: g) }
            // Rótulos de hora só no painel de baixo; os demais reservam o
            // mesmo espaço (rótulo transparente) para manter a área de
            // plotagem idêntica.
            .chartXAxis { sharedXAxis(showLabels: showXLabels) }
            // Tooltip por toque (única interação da view).
            .chartXSelection(value: $selectedDate)
            .frame(height: 110)
        }
    }

    // MARK: - Marcas compartilhadas (boundaries + seleção)

    /// Linhas verticais tracejadas nos boundaries dos episódios. DASHED e mais
    /// escuras para se distinguirem do grid (que agora é SÓLIDO e claro) — pedido
    /// do orientador: "as linhas do grid se confundem com as dos episódios".
    @ChartContentBuilder
    private var boundaryRules: some ChartContent {
        ForEach(boundaryDates, id: \.self) { d in
            RuleMark(x: .value("boundary", d))
                .foregroundStyle(.gray.opacity(0.75))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }

    @ChartContentBuilder
    private var selectionRule: some ChartContent {
        if let sel = selectedDate {
            RuleMark(x: .value("sel", sel))
                .foregroundStyle(.primary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1))
        }
    }

    // MARK: - Eixos compartilhados (mesma geometria em todos os charts)

    /// Eixo Y de largura fixa. Para os painéis (`g != nil`) mostra os valores
    /// formatados; para a faixa de episódios (`g == nil`) reserva a MESMA largura
    /// com um rótulo em branco, garantindo o alinhamento.
    @AxisContentBuilder
    private func yAxis(for g: SensorGroupSeries?) -> some AxisContent {
        AxisMarks(position: .leading) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                .foregroundStyle(.gray.opacity(0.18))
            AxisValueLabel {
                if let g, let d = value.as(Double.self) {
                    Text(formatAxis(d, for: g.name))
                        .frame(width: yAxisLabelWidth, alignment: .trailing)
                } else {
                    Text(" ").frame(width: yAxisLabelWidth, alignment: .trailing)
                }
            }
        }
    }

    /// Eixo X comum: grid SÓLIDO (não tracejado) e rótulos de hora. Os rótulos
    /// são desenhados em todos os charts (mesma geometria) mas só ficam visíveis
    /// quando `showLabels` é true — assim o inset inferior é idêntico em todos.
    @AxisContentBuilder
    private func sharedXAxis(showLabels: Bool) -> some AxisContent {
        AxisMarks(values: .automatic) { _ in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                .foregroundStyle(.gray.opacity(0.18))
            AxisTick()
            AxisValueLabel(format: .dateTime.hour().minute())
                .foregroundStyle(showLabels ? Color.secondary : Color.clear)
        }
    }

    // MARK: - Helpers de domínio / formatação

    private func dateFromMs(_ ms: Int64) -> Date {
        Date(timeIntervalSince1970: Double(ms) / 1000.0)
    }

    /// Boundaries únicos (início de cada episódio + fim de todos), ordenados.
    /// Set dedup evita desenhar a mesma linha duas vezes em episódios contíguos.
    private var boundaryDates: [Date] {
        guard !episodes.isEmpty else { return [] }
        var ms = Set<Int64>()
        for ep in episodes { ms.insert(ep.startMs); ms.insert(ep.endMs) }
        return ms.sorted().map { dateFromMs($0) }
    }

    /// Domínio Y do painel = [min, max] dos dados com padding. Trata o caso quase
    /// constante (ex.: uma série z-score sem variação) para que a linha não fique
    /// colada na borda nem desapareça num range degenerado.
    private func yDomain(for g: SensorGroupSeries) -> ClosedRange<Double> {
        let vals = g.samples.map(\.value)
        guard let lo = vals.min(), let hi = vals.max() else { return -1...1 }
        if lo == hi {
            let pad = max(abs(lo) * 0.0005, 0.5)
            return (lo - pad)...(hi + pad)
        }
        let pad = (hi - lo) * 0.12
        return (lo - pad)...(hi + pad)
    }

    /// Rótulo do eixo Y. Todas as séries estão agora em unidades de z-score
    /// (paridade com normalization="standard" do run_local.py), então o GPS não
    /// precisa mais de casas extras — o formato é uniforme entre os painéis.
    private func formatAxis(_ v: Double, for name: String) -> String {
        String(format: "%.1f", v)
    }

    /// Valor do tooltip — uniforme, pois todas as séries são z-scores adimensionais.
    private func formatValue(_ v: Double, for name: String) -> String {
        String(format: "%.2f", v)
    }

    // MARK: - Tooltip lookup

    /// Valor da série mais próximo (no tempo) do instante `date`. Linear O(n) com
    /// n ≤ ~2000 — barato para uma seleção pontual.
    private func value(of series: SensorGroupSeries, at date: Date) -> Double? {
        guard var bestDiff = series.samples.first.map({
            abs($0.timestamp.timeIntervalSince(date))
        }) else { return nil }
        var best = series.samples[0].value
        for s in series.samples {
            let d = abs(s.timestamp.timeIntervalSince(date))
            if d < bestDiff { bestDiff = d; best = s.value }
        }
        return best
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

    /// Série "GPS" de mock: média dos dois eixos JÁ Z-SCORED (paridade com o app,
    /// que padroniza latitude/longitude antes de mediar). Valores adimensionais
    /// em torno de 0, na mesma faixa de acc/gyro — reflete o que a referência
    /// em Python desenha sob normalization="standard".
    static func makeGPSSeries() -> SensorGroupSeries {
        var samples: [SensorGroupSample] = []
        samples.reserveCapacity(nSamples)
        let step = totalDurationSec / Double(nSamples - 1)
        for i in 0..<nSamples {
            let t = Double(i) * step
            // Deslocamento espacial normalizado: tendência lenta + leve ondulação.
            let value =
                1.6 * sin(2 * .pi * t / 600 - 0.4)
              + 0.25 * sin(2 * .pi * t / 47)
            samples.append(SensorGroupSample(
                timestamp: startDate.addingTimeInterval(t),
                value: value,
                group: "GPS"
            ))
        }
        return SensorGroupSeries(name: "GPS", samples: samples)
    }

    static var seriesPreview: [SensorGroupSeries] {
        [makeAccelerometerSeries(), makeGyroscopeSeries(), makeGPSSeries()]
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

