//
//  EpisodeBuilder.swift
//  MotionApp
//
//  Equivalente Swift das funções `get_start_end_label`, `episode_to_ms`,
//  `compute_episodes` da pipeline Python de referência.
//
//  Esta camada vive **acima** do `Utils.swift` (que tem o linkage Ward + fcluster
//  parcial) e **abaixo** do ViewModel: o ViewModel chama `EpisodeBuilder.run(...)`
//  passando embeddings (768-d por janela, particionado) + timestamps de janela, e recebe
//  `[Episode]` com `startMs` / `endMs` / `label` prontos para visualização.
//

import Foundation

/// Um episódio derivado do clustering. Paridade EXATA com Python, o que
/// implica uma semântica assimétrica para `endMs` que vale registrar:
///
/// - Para o ÚLTIMO episódio da sequência: `endMs` = ts do primeiro sample
///   da última janela DESTE episódio (`end` em `getStartEndLabel` = `len - 1`).
///
/// - Para episódios INTERMEDIÁRIOS: `endMs` = ts do primeiro sample da
///   PRIMEIRA janela do PRÓXIMO episódio (`end` em `getStartEndLabel` = `i`
///   no momento da transição). Ou seja, há um *overlap de fronteira* de 1
///   janela: `episode[i].endMs == episode[i+1].startMs`.
///
/// Consequências:
/// - `durationMs` de episódios intermediários inclui implicitamente a janela
///   do próximo episódio. Para usar como duração real, faça
///   `min(endMs - startMs, próximo.startMs - startMs)`.
/// - Em `gatherEpisodePoints`, um ponto GPS exatamente na fronteira (ts ==
///   `episode.endMs`) é atribuído ao episódio anterior. Em prática isso é
///   1 ponto em milhares — irrelevante visualmente, mas vale saber.
///
/// Mantemos essa semântica deliberadamente para que o eixo X dos plots
/// (Plotly Python e Swift Charts) caia exatamente nas mesmas posições.
struct Episode: Identifiable, Equatable {
    let id = UUID()
    let label: Int      // 1-based, igual ao `fcluster_custom` do Python
    let startWindowIdx: Int
    let endWindowIdx: Int
    let startMs: Int64
    let endMs: Int64

    var durationMs: Int64 { endMs - startMs }

    static func == (lhs: Episode, rhs: Episode) -> Bool {
        lhs.label == rhs.label
            && lhs.startWindowIdx == rhs.startWindowIdx
            && lhs.endWindowIdx == rhs.endWindowIdx
            && lhs.startMs == rhs.startMs
            && lhs.endMs == rhs.endMs
    }
}

enum EpisodeBuilder {

    /// Equivale a `get_start_end_label(vector)` do Python.
    /// A partir de uma sequência de labels por janela, retorna runs consecutivas:
    /// `{start: idx_inicial_da_run, end: idx_final_da_run, label: 1..k_run}`.
    ///
    /// **Cuidado**: o `label` do retorno NÃO é o cluster label — é um ID 1-based
    /// que enumera os runs na ordem em que aparecem (mesmo comportamento da
    /// versão Python). Isso é o que o resto do pipeline usa pra colorir o mapa
    /// e fazer o overlay no plot.
    static func getStartEndLabel(_ labels: [Int]) -> [(start: Int, end: Int, label: Int)] {
        guard !labels.isEmpty else { return [] }
        var sequences: [(start: Int, end: Int, label: Int)] = []
        var last = labels[0]
        var iStart = 0
        var epId = 1
        for i in 0..<labels.count {
            if last != labels[i] {
                sequences.append((start: iStart, end: i, label: epId))
                iStart = i
                last = labels[i]
                epId += 1
            }
        }
        // Última run vai até o fim. **Detalhe**: o Python coloca `end = len - 1`.
        sequences.append((start: iStart, end: labels.count - 1, label: epId))
        return sequences
    }

    /// Promove índices de janela para timestamps Unix-ms.
    /// Equivale a `episode_to_ms(episodes, dataset)` do Python.
    ///
    /// - Parameters:
    ///   - runs: saída de `getStartEndLabel`.
    ///   - windowStartTimestamps: array com `dataset.window_timestamp(idx, 0)` para cada janela.
    static func episodesToMs(
        runs: [(start: Int, end: Int, label: Int)],
        windowStartTimestamps: [Int64]
    ) -> [Episode] {
        return runs.map { r in
            // Clamp por segurança — `getStartEndLabel` já garante start/end
            // dentro do range, mas defensivo é melhor.
            let s = max(0, min(r.start, windowStartTimestamps.count - 1))
            let e = max(0, min(r.end, windowStartTimestamps.count - 1))
            return Episode(
                label: r.label,
                startWindowIdx: r.start,
                endWindowIdx: r.end,
                startMs: windowStartTimestamps[s],
                endMs: windowStartTimestamps[e]
            )
        }
    }

    /// Pipeline completa: embeddings → linkage adjacente Ward → fcluster → episodes.
    ///
    /// - Parameters:
    ///   - embeddings: buffer flat row-major (W, D) float32. D = 768 (particionado) ou 256 (monolítico).
    ///   - W: número de janelas.
    ///   - D: dimensão do embedding.
    ///   - windowStartTimestamps: timestamps Unix-ms do início de cada janela. Tamanho W.
    ///   - numberOfEpisodes: K — quantos clusters cortar (parâmetro do fcluster).
    ///   - utils: instância usada para linkage + fcluster (reutiliza implementação já testada).
    /// - Returns: `(episodes, labels)` onde `labels` é o vetor 1..K por janela
    ///   (útil pra renderizar o map / bar chart) e `episodes` é a forma "runs".
    static func computeEpisodes(
        embeddings: [Float],
        W: Int,
        D: Int,
        windowStartTimestamps: [Int64],
        numberOfEpisodes K: Int,
        utils: Utils
    ) -> (episodes: [Episode], labels: [Int]) {
        precondition(embeddings.count == W * D, "embeddings tem que ser W*D")
        precondition(windowStartTimestamps.count == W,
                     "windowStartTimestamps.count(\(windowStartTimestamps.count)) ≠ W(\(W))")

        guard W >= 2 else {
            // Nada para clusterizar: 0 ou 1 janela → 1 episódio trivial.
            let label = 1
            let labels = Array(repeating: label, count: W)
            let episodes: [Episode] = W == 1
                ? [Episode(label: 1, startWindowIdx: 0, endWindowIdx: 0,
                           startMs: windowStartTimestamps[0], endMs: windowStartTimestamps[0])]
                : []
            return (episodes, labels)
        }

        // 1) Converte buffer flat para [[Float]] (formato esperado pelo Utils).
        //    Para W ~ poucas centenas em coleta curta, é trivial em RAM.
        var matrix = [[Float]](repeating: [], count: W)
        for w in 0..<W {
            let row = Array(embeddings[(w * D)..<((w + 1) * D)])
            matrix[w] = row
        }

        // 2) Linkage adjacente Ward com parada antecipada em K clusters.
        //    Mesmas semânticas do Python: depois de `n - K` merges, paramos.
        let Z = utils.linkageAdjacentWard(matrix, stopAtK: K)

        // 3) fcluster a partir do Z parcial → labels 1..k por janela.
        let labels = utils.fclusterFromPartialZ(Z: Z, n: W)

        // 4) Runs + promoção para timestamps ms.
        let runs = getStartEndLabel(labels)
        let episodes = episodesToMs(runs: runs, windowStartTimestamps: windowStartTimestamps)

        return (episodes, labels)
    }
}
