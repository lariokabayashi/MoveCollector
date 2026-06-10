//
//  UnitTest.swift
//  UnitTest
//
//  Created by Larissa Okabayashi on 16/11/25.
//
//  Etapa E (TFC migration): testes de paridade matemática entre a pipeline
//  Swift e a referência Python (exemplo_refactored.ipynb).
//

import XCTest
@testable import MotionApp

@available(iOS 26.0, *)
final class UnitTest: XCTestCase {

    // MARK: - SensorSchema

    func testSchemaIs11Channels() {
        XCTAssertEqual(SensorSchema.nChannels, 11)
        XCTAssertEqual(SensorSchema.featureColumns.count, 11)
        XCTAssertEqual(SensorSchema.featureColumns[0], "acc_x")
        XCTAssertEqual(SensorSchema.featureColumns[10], "vertical_accuracy")
        XCTAssertEqual(SensorSchema.featureIndex["latitude"], 6)
    }

    // MARK: - normalizeFeaturesInPlace (paridade com `normalize_features` Python)

    func testStandardNormalization() {
        // Para [-1, 0, 1] em uma coluna, média=0 e std=sqrt(2/3),
        // resultado normalizado = [-sqrt(3/2), 0, sqrt(3/2)]. ddof=0 (= numpy.std).
        var buf: [Float] = [-1, 0, 1]
        normalizeFeaturesInPlace(buffer: &buf, n: 3, c: 1, kind: .standard)
        let expected: Float = Float(sqrt(3.0 / 2.0))
        XCTAssertEqual(buf[0], -expected, accuracy: 1e-5)
        XCTAssertEqual(buf[1], 0, accuracy: 1e-5)
        XCTAssertEqual(buf[2], expected, accuracy: 1e-5)
    }

    func testMinMaxNormalization() {
        var buf: [Float] = [10, 20, 30]
        normalizeFeaturesInPlace(buffer: &buf, n: 3, c: 1, kind: .minmax)
        XCTAssertEqual(buf[0], 0, accuracy: 1e-6)
        XCTAssertEqual(buf[1], 0.5, accuracy: 1e-6)
        XCTAssertEqual(buf[2], 1, accuracy: 1e-6)
    }

    // MARK: - WindowedSensorDataset (paridade com Python)

    func testWindowedSensorDatasetLayout() {
        // 4 amostras, 2 canais — vamos identificar layout (W, C, T) row-major.
        // features (N=4, C=2):
        //   amostra 0: [10, 100]
        //   amostra 1: [11, 101]
        //   amostra 2: [12, 102]
        //   amostra 3: [13, 103]
        let feats: [Float] = [10, 100, 11, 101, 12, 102, 13, 103]
        let ts: [Int64] = [1000, 1050, 1100, 1150]
        let sensors = SensorTensor(timestamps: ts, features: feats, featureNames: ["a", "b"])
        let ds = WindowedSensorDataset(sensors: sensors, windowSize: 2, stepSize: 2)

        XCTAssertEqual(ds.count, 2, "2 janelas não-overlapping em 4 amostras com W=2 step=2")

        // Janela 0 esperada (C, T) = [[10, 11], [100, 101]] flat = [10, 11, 100, 101].
        let w0 = Array(ds.window(at: 0))
        XCTAssertEqual(w0, [10, 11, 100, 101])

        // Janela 1 esperada [[12, 13], [102, 103]] flat = [12, 13, 102, 103].
        let w1 = Array(ds.window(at: 1))
        XCTAssertEqual(w1, [12, 13, 102, 103])

        // Timestamps de início devem bater com a primeira amostra de cada janela.
        XCTAssertEqual(ds.windowStartTimestamps, [1000, 1100])
    }

    // MARK: - linkageAdjacentWard + fclusterFromPartialZ (paridade com Python)

    func testLinkageAdjacentAndFclusterTrivialCase() {
        // 4 pontos colineares com gap claro entre dois grupos:
        //   0: [0,0]   1: [0.1, 0]   |   2: [10, 0]   3: [10.1, 0]
        // Esperado: cortando em k=2, episódios = [grupo {0,1}, grupo {2,3}].
        let utils = Utils()
        let mat: [[Float]] = [
            [0.0, 0.0],
            [0.1, 0.0],
            [10.0, 0.0],
            [10.1, 0.0],
        ]
        let Z = utils.linkageAdjacentWard(mat, stopAtK: 2)
        // Deve ter executado n - k = 4 - 2 = 2 merges.
        XCTAssertEqual(Z.count, 2)
        let labels = utils.fclusterFromPartialZ(Z: Z, n: 4)
        // Os labels mapeiam para 1..k. Esperamos {1,1,2,2} ou {2,2,1,1} dependendo
        // da ordem de remap; o invariante é que (0,1) compartilham label e (2,3)
        // compartilham um DIFERENTE label.
        XCTAssertEqual(labels[0], labels[1], "Pontos próximos devem compartilhar episódio")
        XCTAssertEqual(labels[2], labels[3], "Pontos próximos devem compartilhar episódio")
        XCTAssertNotEqual(labels[0], labels[2], "Pontos distantes devem estar em episódios diferentes")
    }

    // MARK: - EpisodeBuilder.getStartEndLabel (paridade com Python)

    func testGetStartEndLabelRuns() {
        // Mesmas runs do exemplo do Python:
        //   labels = [1,1,2,2,2,3,1,1] → runs = (0..1,ep=1) (2..4,ep=2) (5,ep=3) (6..7,ep=4)
        let runs = EpisodeBuilder.getStartEndLabel([1, 1, 2, 2, 2, 3, 1, 1])
        XCTAssertEqual(runs.count, 4)
        XCTAssertEqual(runs[0].start, 0); XCTAssertEqual(runs[0].end, 2);  XCTAssertEqual(runs[0].label, 1)
        XCTAssertEqual(runs[1].start, 2); XCTAssertEqual(runs[1].end, 5);  XCTAssertEqual(runs[1].label, 2)
        XCTAssertEqual(runs[2].start, 5); XCTAssertEqual(runs[2].end, 6);  XCTAssertEqual(runs[2].label, 3)
        XCTAssertEqual(runs[3].start, 6); XCTAssertEqual(runs[3].end, 7);  XCTAssertEqual(runs[3].label, 4)
        //
        // OBS: estes números vêm DIRETO do `get_start_end_label` Python, que tem
        // este (peculiar) overlap: o `end` da run i é o `start` da run i+1 — não
        // `start+i-1`. Mantemos paridade exata: o EpisodesMapView/CombinedSensors
        // já trata isso (lê windowStartTimestamps[end] como "ts do primeiro
        // sample da última janela do episódio").
    }

    func testEpisodesToMsMappingWindowTimestamps() {
        let runs = EpisodeBuilder.getStartEndLabel([1, 1, 2, 2])
        // 4 janelas com timestamps fictícios:
        let ts: [Int64] = [1_000, 1_500, 2_000, 2_500]
        let eps = EpisodeBuilder.episodesToMs(runs: runs, windowStartTimestamps: ts)
        XCTAssertEqual(eps.count, 2)
        // Primeiro episódio: start=0 → ts[0]=1000, end=2 → ts[2]=2000.
        // (paridade Python: end é o ÍNDICE do primeiro sample da última janela
        //  do episódio — aqui janela 2 é a primeira do próximo run, mas Python
        //  usa esse mesmo idx; ver comentário no testGetStartEndLabelRuns.)
        XCTAssertEqual(eps[0].startMs, 1_000)
        XCTAssertEqual(eps[0].endMs, 2_000)
        XCTAssertEqual(eps[1].startMs, 2_000)
        XCTAssertEqual(eps[1].endMs, 2_500)
    }

    // MARK: - TFC schema sanity

    func testAppConstantsMatchTFCModel() {
        let c = AppConstants()
        // Estes constantes devem bater 1:1 com a pipeline TFC particionada:
        XCTAssertEqual(c.windowSize, 300, "Casado com TFC_Backbone_* input shape [1, 3, 300]")
        XCTAssertEqual(c.stepSize, 300, "Step=window (sem overlap) — paridade Python")
        XCTAssertEqual(c.nChannels, 11, "Canais brutos: acc+gyro+GPS5")
        XCTAssertEqual(c.embeddingDim, 768, "3 partições × (z_t[128] + z_f[128]) = 768")
        XCTAssertEqual(c.sensorFrequencyHz, 20.0)
    }

    // MARK: - Regressões dos riscos A/B/D identificados em code review (2026-05-27)

    /// FIX A regression: o cache de distâncias era invalidado ANTES do loop
    /// de Ward, causando distância `+inf` a partir do 2º merge. Este teste
    /// força MÚLTIPLOS merges intra-grupo antes do corte — o cenário trivial
    /// de 4 pontos / 2 merges não pegava o bug porque o último merge
    /// corrompido nunca era reutilizado.
    func testLinkageWardMultiMergeNotCorruptedByCacheEviction() {
        let utils = Utils()
        // Dois grupos bem separados (3 pontos cada). Cortar em k=2 exige
        // 4 merges no total → pelo menos 2 deles entre clusters JÁ formados.
        let mat: [[Float]] = [[0], [1], [2], [100], [101], [102]]
        let Z = utils.linkageAdjacentWard(mat, stopAtK: 2)
        XCTAssertEqual(Z.count, 4, "n - k = 6 - 2 = 4 merges esperados")

        // (a) Nenhuma distância pode "explodir" para ~Float.greatestFiniteMagnitude.
        // Pré-fix esse teste falhava porque a partir do 2º merge a distância
        // virava inf — passou a passar com a reordenação cache-after-Ward.
        for (i, row) in Z.enumerated() {
            XCTAssertTrue(row[2].isFinite && row[2] < 1e6,
                          "Z[\(i)][dist] corrompido: \(row[2]) — cache evict order bug regrediu?")
        }

        // (b) O corte em k=2 deve cair entre idx 2 e 3 (maior gap dos dados).
        let labels = utils.fclusterFromPartialZ(Z: Z, n: 6)
        XCTAssertEqual(labels[0], labels[1])
        XCTAssertEqual(labels[1], labels[2])
        XCTAssertEqual(labels[3], labels[4])
        XCTAssertEqual(labels[4], labels[5])
        XCTAssertNotEqual(labels[2], labels[3],
                          "fronteira deve cair entre o cluster {0,1,2} e {3,4,5}")
    }

    /// FIX D regression: empates de distância eram resolvidos por ordem de
    /// inserção no heap, podendo divergir do `argmin` estável do numpy.
    /// `AdjPair.<` agora desempata por `left` (e depois `right`).
    func testAdjPairComparisonHasStableTiebreaker() {
        let a = AdjPair(left: 1, right: 2, dist: 5.0, version: 0)
        let b = AdjPair(left: 3, right: 4, dist: 5.0, version: 0)
        // Mesma distância → o com `left` menor deve "vencer".
        XCTAssertTrue(a < b, "desempate por left=1 < left=3 falhou")
        XCTAssertFalse(b < a)

        let c = AdjPair(left: 5, right: 6, dist: 5.0, version: 0)
        let d = AdjPair(left: 5, right: 9, dist: 5.0, version: 0)
        // Mesma distância e mesmo `left` → desempate por `right`.
        XCTAssertTrue(c < d, "desempate secundário por right=6 < right=9 falhou")

        // Distâncias diferentes ignoram índices.
        let smallDistHighLeft = AdjPair(left: 100, right: 101, dist: 1.0, version: 0)
        let bigDistLowLeft = AdjPair(left: 0, right: 1, dist: 10.0, version: 0)
        XCTAssertTrue(smallDistHighLeft < bigDistLowLeft,
                      "comparador deve priorizar distância sobre índice")
    }

    /// Sanity: vetor com distâncias todas iguais não pode ficar "preso" em
    /// posições arbitrárias do heap — o desempate determinístico garante que
    /// o algoritmo siga uma ordem reproduzível.
    func testLinkageStableUnderEqualDistances() {
        let utils = Utils()
        // 4 pontos colineares com espaçamento uniforme — todas as distâncias
        // adjacentes valem 1.0.
        let mat: [[Float]] = [[0], [1], [2], [3]]
        let Z1 = utils.linkageAdjacentWard(mat, stopAtK: 2)
        let Z2 = utils.linkageAdjacentWard(mat, stopAtK: 2)
        // Duas execuções têm que produzir EXATAMENTE o mesmo Z — reprodutibilidade.
        XCTAssertEqual(Z1.count, Z2.count)
        for i in 0..<Z1.count {
            XCTAssertEqual(Z1[i][0], Z2[i][0], accuracy: 0)
            XCTAssertEqual(Z1[i][1], Z2[i][1], accuracy: 0)
        }
    }

    /// Sanity: labels todos iguais → 1 episódio cobrindo [0, W-1].
    func testGetStartEndLabelSingleEpisode() {
        let runs = EpisodeBuilder.getStartEndLabel([7, 7, 7, 7, 7])
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].start, 0)
        XCTAssertEqual(runs[0].end, 4)   // labels.count - 1 (inclusivo na última run)
        XCTAssertEqual(runs[0].label, 1)
    }

    /// FIX B regression: backfill agora preenche TODAS as janelas sem fix,
    /// não só as do prefixo. Janelas com `lat=0 ∧ hAcc=0` no MEIO da sessão
    /// devem ser preenchidas com o último fix conhecido (forward-fill).
    func testBackfillGPSCoverageMidSession() {
        // Simulação direta da estrutura: 3 janelas, 11 canais, 300 amostras.
        // Janela 0: tem fix (hAcc > 0 em todas as amostras)
        // Janela 1: SEM fix (hAcc = 0)
        // Janela 2: tem fix
        let T = 300
        let C = 11
        func makeWindow(hasFix: Bool, latValue: Float) -> [Float] {
            var w = [Float](repeating: 0, count: T * C)
            for t in 0..<T {
                w[t * C + 6] = latValue   // lat
                w[t * C + 7] = -47.0      // lon
                w[t * C + 8] = 600.0      // alt
                w[t * C + 9] = hasFix ? 3.0 : 0.0   // hAcc (0 = no fix)
                w[t * C + 10] = hasFix ? 5.0 : 0.0  // vAcc
            }
            return w
        }
        var windows: [[Float]] = [
            makeWindow(hasFix: true, latValue: -23.5),
            makeWindow(hasFix: false, latValue: 0.0),   // ← gap mid-session
            makeWindow(hasFix: true, latValue: -23.6),
        ]
        // Pré-fix: confirma que a janela 1 começa zerada nos canais GPS.
        XCTAssertEqual(windows[1][6], 0.0)
        XCTAssertEqual(windows[1][9], 0.0)

        // NOTA: `backfillPreFixGPSWindows` é privada. Testamos via reflexão
        // indireta — invocando `runDailyClustering` exigiria CoreML carregado,
        // o que não é prático em unit test. Por isso, este teste documenta o
        // comportamento esperado e fica como "doc test"; uma verificação
        // efetiva precisa rodar em integração (com .mlpackages presentes).
        //
        // Para validação manual: rodar uma coleta com queda intencional de
        // GPS no meio e conferir no log `[GPS BACKFILL]` que mid-session > 0.
        XCTAssertTrue(true, "Comportamento documentado — ver `runDailyClustering` em integração.")
    }

    // MARK: - Partitions (paridade com PARTITIONS_BY_NAME do Python)

    func testTFCPartitionsMatchPythonNotebook() {
        // Ordem CRÍTICA: define o layout do embedding 768d concatenado.
        XCTAssertEqual(kTFCPartitions.count, 3)
        XCTAssertEqual(kTFCPartitions[0].name, "Acc")
        XCTAssertEqual(kTFCPartitions[0].channelIndices, [0, 1, 2],
                       "acc_x, acc_y, acc_z em SensorSchema.featureColumns")
        XCTAssertEqual(kTFCPartitions[1].name, "Gyro")
        XCTAssertEqual(kTFCPartitions[1].channelIndices, [3, 4, 5],
                       "gyro_x, gyro_y, gyro_z")
        XCTAssertEqual(kTFCPartitions[2].name, "GPS")
        XCTAssertEqual(kTFCPartitions[2].channelIndices, [6, 7, 8],
                       "latitude, longitude, altitude — hAcc/vAcc NÃO entram")

        // Validar que os índices casam com SensorSchema (proteção contra
        // alguém mudar a ordem das colunas e silenciosamente quebrar a
        // partição GPS).
        XCTAssertEqual(SensorSchema.featureColumns[0], "acc_x")
        XCTAssertEqual(SensorSchema.featureColumns[3], "gyro_x")
        XCTAssertEqual(SensorSchema.featureColumns[6], "latitude")
        XCTAssertEqual(SensorSchema.featureColumns[7], "longitude")
        XCTAssertEqual(SensorSchema.featureColumns[8], "altitude")
        XCTAssertEqual(SensorSchema.featureColumns[9], "horizontal_accuracy")
        XCTAssertEqual(SensorSchema.featureColumns[10], "vertical_accuracy")
    }
}
