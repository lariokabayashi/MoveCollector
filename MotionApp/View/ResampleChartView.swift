import SwiftUI
import Charts
import CoreData

struct PlotPoint: Identifiable {
    let id = UUID()
    let t: Double
    let v: Double
}

struct SeriesPoint: Identifiable {
    let id = UUID()
    let series: String // "Original" ou "Reamostrado"
    let t: Double
    let v: Double
}

struct ResampleChartView: View {
    @ObservedObject var viewModel: SensorManagerVMComplete

    // Compute a common t0 across both series to avoid huge epoch values on X
    private var t0: Double? {
        let tOriginal = viewModel.chartOriginalAX.first?.t
        let tResampled = viewModel.chartResampledAX.first?.t
        switch (tOriginal, tResampled) {
        case let (o?, r?):
            return min(o, r)
        case let (o?, nil):
            return o
        case let (nil, r?):
            return r
        default:
            return nil
        }
    }

    private func toRelativePoints(_ samples: [Sample]) -> [PlotPoint] {
        guard let base = t0 else { return [] }
        return samples
            .sorted(by: { $0.t < $1.t })
            .map { PlotPoint(t: $0.t - base, v: $0.ax) }
    }

    var originalPoints: [PlotPoint] { toRelativePoints(viewModel.chartOriginalAX) }
    var resampledPoints: [PlotPoint] { toRelativePoints(viewModel.chartResampledAX) }

    var combinedPoints: [SeriesPoint] {
        let o = originalPoints.map { SeriesPoint(series: "Original", t: $0.t, v: $0.v) }
        let r = resampledPoints.map { SeriesPoint(series: "Reamostrado", t: $0.t, v: $0.v) }
        return o + r
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Comparação: Sinal Original vs Reamostrado (ax)")
                .font(.headline)
            Chart(combinedPoints) { p in
                // Linha da série
                LineMark(
                    x: .value("t", p.t),
                    y: .value("ax", p.v),
                    series: .value("Série", p.series)
                )
                .interpolationMethod(.linear)
                .foregroundStyle(by: .value("Série", p.series))
                .symbol(by: .value("Série", p.series))

                // Pontos (marcadores) — ajudam a distinguir séries sobrepostas
                PointMark(
                    x: .value("t", p.t),
                    y: .value("ax", p.v)
                )
                .foregroundStyle(by: .value("Série", p.series))
                .symbol(by: .value("Série", p.series))
                .symbolSize(40)
            }
            .chartXAxisLabel("Tempo relativo (s)")
            .chartYAxisLabel("ax")
            .chartLegend(position: .bottom, alignment: .leading)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6))
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 5))
            }
            .frame(height: 260)
        }
        .padding()
    }
}
