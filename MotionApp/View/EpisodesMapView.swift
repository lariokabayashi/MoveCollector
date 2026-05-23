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
    let points: [EpisodePoint]
    /// Quantidade de cores na paleta (mesma do Python).
    private static let palette: [Color] = [
        .red, .blue, .green, .purple, .orange,
        .pink, .black, .yellow, .indigo, .teal,
        .gray, .brown, .mint, .cyan,
    ]

    @State private var cameraPosition: MapCameraPosition

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
                        .overlay(Circle().stroke(.white, lineWidth: 1))
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .overlay(alignment: .topTrailing) {
            // Mini-legenda com label → cor (igual à camada `LayerControl` do Folium).
            let uniqueLabels = Array(Set(points.map(\.label))).sorted()
            VStack(alignment: .leading, spacing: 4) {
                ForEach(uniqueLabels, id: \.self) { l in
                    HStack(spacing: 6) {
                        Circle().fill(Self.color(for: l)).frame(width: 8, height: 8)
                        Text("Grupo \(l)").font(.caption2)
                    }
                }
            }
            .padding(8)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(8)
        }
    }

    static func color(for label: Int) -> Color {
        return palette[(max(0, label - 1)) % palette.count]
    }
}
