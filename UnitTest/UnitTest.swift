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
        // Estes constantes devem bater 1:1 com o .mlpackage:
        XCTAssertEqual(c.windowSize, 300, "Casado com TFC_Backbone input shape [1,11,300]")
        XCTAssertEqual(c.stepSize, 300, "Step=window (sem overlap) — paridade Python")
        XCTAssertEqual(c.nChannels, 11, "Canais: acc+gyro+GPS5")
        XCTAssertEqual(c.embeddingDim, 256, "concat(z_t [128], z_f [128]) = 256")
        XCTAssertEqual(c.sensorFrequencyHz, 20.0)
    }
}
