//
//  EpisodeBarChartView.swift
//  MotionApp
//
//  Created by Larissa Okabayashi on 24/03/26.
//

import Foundation
import SwiftUI

/// Paleta de cores CANÔNICA dos episódios, compartilhada por TODAS as
/// visualizações (mapa, bar chart, faixa de episódios do combined sensors e
/// lista de episódios).
///
/// Por que isto existe: antes cada view definia a própria paleta — o mapa/lista/
/// faixa usavam uma sequência de 14 cores e o bar chart usava OUTRA de 10 cores
/// em ordem diferente. Resultado: o mesmo grupo (episódio) aparecia vermelho no
/// mapa e azul no bar chart. Centralizar aqui garante "mesmo label ⇒ mesma cor"
/// em toda a UI (requisito 1.1/1.2). NÃO defina paletas locais em nenhuma view —
/// sempre chame `EpisodeColorPalette.color(for:)`.
///
/// `label` é o ID 1-based do episódio (run consecutiva), o MESMO produzido por
/// `EpisodeBuilder.getStartEndLabel`. Mantido sem `@available` para poder ser
/// usado por views com e sem anotação de versão.
enum EpisodeColorPalette {
    // Sequencia liderada pelas cores da marca e SEM `.black` (que ficava
    // invisivel no dark mode). Todas as entradas sao legiveis sobre fundo escuro.
    static let colors: [Color] = [
        .brandLime, .brandBlue, .brandGreen, .brandRed, .orange,
        .pink, .cyan, .yellow, .indigo, .teal,
        .mint, .brown, .purple, .white,
    ]

    static func color(for label: Int) -> Color {
        colors[(max(0, label - 1)) % colors.count]
    }
}

struct EpisodeSegment: Identifiable {
    let id = UUID()
    /// ID 1-based do episódio (run consecutiva), igual a `Episode.label` /
    /// `getStartEndLabel`. NÃO é o cluster id cru — ver `makeSegments`.
    let label: Int
    let startIndex: Int
    let endIndex: Int
    var length: Int { endIndex - startIndex + 1 }
}

struct EpisodeBarChartView: View {
    /// Labels de cluster por janela (`fcluster_custom`, 1..K). Podem repetir
    /// (mesma atividade revisitada). O bar chart os converte em EPISÓDIOS
    /// (runs consecutivas) com IDs 1-based, ver `makeSegments`.
    let labels: [Int]
    var segments: [EpisodeSegment] { makeSegments(from: labels) }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(segments) { seg in
                    let fraction = CGFloat(seg.length) / CGFloat(labels.count)
                    Rectangle()
                        .fill(EpisodeColorPalette.color(for: seg.label))
                        .frame(width: max(1, geo.size.width * fraction))
                        .overlay(
                            Text("\(seg.label)")
                                .font(.caption2)
                                .foregroundStyle(.white)
                                .padding(2),
                            alignment: .center
                        )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            )
        }
    }

    /// Converte a sequência de labels de CLUSTER em segmentos de EPISÓDIO.
    ///
    /// FIX (1.2 — labels incorretos): antes cada segmento exibia/colored pelo
    /// label de cluster cru (`current`). Isso divergia do resto do app: a lista
    /// de episódios mostra "Ep 1, Ep 2, Ep 3, Ep 4" e o mapa mostra "Grupo 1..N"
    /// usando o ID 1-based de RUN (`getStartEndLabel`). Com clusters repetidos
    /// (ex.: [1,1,2,2,1,1,3]) o bar chart mostrava "1,2,1,3" enquanto a lista
    /// mostrava "1,2,3,4" para os MESMOS dados — labels que não batiam.
    ///
    /// Agora cada run consecutiva recebe um ID sequencial 1-based (`episodeId`),
    /// idêntico ao `epId` de `EpisodeBuilder.getStartEndLabel` e a `Episode.label`.
    /// O número de segmentos passa a ser exatamente o número de episódios, e o
    /// label/cor de cada barra casa com o mapa, a faixa e a lista.
    func makeSegments(from labels: [Int]) -> [EpisodeSegment] {
        guard !labels.isEmpty else { return [] }
        var segments: [EpisodeSegment] = []
        var start = 0
        var current = labels[0]
        var episodeId = 1
        for i in 1..<labels.count {
            if labels[i] != current {
                segments.append(EpisodeSegment(label: episodeId, startIndex: start, endIndex: i - 1))
                start = i
                current = labels[i]
                episodeId += 1
            }
        }
        segments.append(EpisodeSegment(label: episodeId, startIndex: start, endIndex: labels.count - 1))
        return segments
    }
}

