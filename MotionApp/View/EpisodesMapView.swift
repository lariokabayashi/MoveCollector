//
//  EpisodesMapView.swift
//  MotionApp
//
//  Equivalente nativo do `groups_map.html` do Python.
//  Renderiza, sobre um MapKit, todos os pontos GPS de uma sessão agrupados
//  e coloridos por episódio (run de label consecutiva).
//
//  Por que MapKit em vez de WebView com Folium:
//  - Zero dependência externa.
//  - Pan/zoom nativo, low latency, integra com sistema (Find My / dark mode).
//  - Custo: a paleta tem que ser construída manualmente — implementada aqui.
//

import SwiftUI
import MapKit

/// Um ponto na trilha de um episódio.
struct EpisodePoint: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let label: Int
    let timestampMs: Int64
}

/// View principal. Aceita uma lista de pontos GPS já casados com `label`
/// (o casamento é feito no ViewModel; aqui é só renderização).
@available(iOS 26.0, *)
struct EpisodesMapView: View {
    @Environment(\.dismiss) private var dismiss
    let points: [EpisodePoint]

    @State private var cameraPosition: MapCameraPosition
    /// Ponto cujo horário está sendo exibido (equivalente ao `tooltip` do
    /// folium, que no Python aparece no hover). No iOS, revelado por toque.
    @State private var selectedPointId: UUID?

    // Formatters em fuso local — mesma convenção do resto do app
    // (SegmentationCardView, CombinedSensorsChartView). O Python usa
    // America/Sao_Paulo fixo; aqui seguimos `TimeZone.current` para casar com
    // as demais telas nativas.
    private static let hmFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = .current
        return f
    }()
    private static let hmsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = .current
        return f
    }()

    private func hm(_ ms: Int64) -> String {
        Self.hmFormatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
    private func hms(_ ms: Int64) -> String {
        Self.hmsFormatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    /// Intervalo [primeiro, último] timestamp de cada grupo, para compor o nome
    /// "Grupo N (t0–t1)" — equivalente ao `Group {gi+1} ({t0}-{t1})` do folium.
    /// Os pontos chegam ordenados por tempo, mas min/max é robusto de qualquer forma.
    private var groupTimeRanges: [Int: (start: Int64, end: Int64)] {
        var ranges: [Int: (start: Int64, end: Int64)] = [:]
        for p in points {
            if let r = ranges[p.label] {
                ranges[p.label] = (min(r.start, p.timestampMs), max(r.end, p.timestampMs))
            } else {
                ranges[p.label] = (p.timestampMs, p.timestampMs)
            }
        }
        return ranges
    }

    init(points: [EpisodePoint]) {
        self.points = points
        // Câmera inicial centrada no primeiro ponto (se houver).
        if let first = points.first {
            _cameraPosition = State(initialValue: .region(MKCoordinateRegion(
                center: first.coordinate,
                latitudinalMeters: 800,
                longitudinalMeters: 800
            )))
        } else {
            _cameraPosition = State(initialValue: .automatic)
        }
    }

    var body: some View {
        Map(position: $cameraPosition) {
            ForEach(points) { p in
                Annotation("", coordinate: p.coordinate, anchor: .center) {
                    Circle()
                        .fill(Self.color(for: p.label))
                        .frame(width: 8, height: 8)
                        // Borda transparente (sem contorno branco): na visão
                        // panorâmica (zoom out) o contorno branco de 1pt dominava
                        // os pontos de 8pt e os deixava esbranquiçados.
                        // Tooltip de horário (HH:mm:ss) flutuando acima do ponto.
                        // `overlay` não altera o frame do círculo, então o ponto
                        // permanece exatamente sobre a coordenada.
                        .overlay(alignment: .bottom) {
                            if selectedPointId == p.id {
                                Text("Grupo \(p.label) · \(hms(p.timestampMs))")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(.thinMaterial, in: Capsule())
                                    .fixedSize()
                                    .offset(y: -16)
                            }
                        }
                        // Área de toque maior que os 8 pt visíveis, para facilitar
                        // selecionar o ponto e revelar o horário.
                        .padding(8)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedPointId = (selectedPointId == p.id) ? nil : p.id
                        }
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .overlay(alignment: .topLeading) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .padding(8)
            }
            .buttonStyle(.plain)
            .background(.thinMaterial, in: Circle())
            .padding(8)
        }
        .overlay(alignment: .topTrailing) {
            // Mini-legenda com label → cor + intervalo de horário, equivalente
            // à camada `LayerControl` do Folium ("Group N (t0-t1)").
            let uniqueLabels = Array(Set(points.map(\.label))).sorted()
            let ranges = groupTimeRanges
            VStack(alignment: .leading, spacing: 4) {
                ForEach(uniqueLabels, id: \.self) { l in
                    HStack(spacing: 6) {
                        Circle().fill(Self.color(for: l)).frame(width: 8, height: 8)
                        if let r = ranges[l] {
                            Text("Grupo \(l) (\(hm(r.start))–\(hm(r.end)))").font(.caption2)
                        } else {
                            Text("Grupo \(l)").font(.caption2)
                        }
                    }
                }
            }
            .padding(8)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(8)
        }
    }

    /// Cor canônica do episódio. Delega para `EpisodeColorPalette` para que mapa,
    /// bar chart, faixa de episódios e lista usem EXATAMENTE a mesma paleta
    /// (requisito 1.1 — "renderizado consistentemente entre todos os grupos").
    /// Mantido como atalho estático por compatibilidade com os call-sites
    /// existentes (`EpisodesMapView.color(for:)`).
    static func color(for label: Int) -> Color {
        EpisodeColorPalette.color(for: label)
    }
}


