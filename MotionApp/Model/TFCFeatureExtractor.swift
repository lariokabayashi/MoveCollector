//
//  TFCFeatureExtractor.swift
//  MotionApp
//
//  Wrapper Swift particionado dos backbones TFC.
//
//  PARIDADE ARQUITETURAL COM PYTHON:
//  - O notebook usa `FeatureExtractor._pretrain_partitioned` para treinar 3
//    backbones independentes (acc xyz, gyro xyz, lat/lon/alt), cada um vendo
//    apenas 3 canais. A inferência (`_partitioned_call`) roda os 3 modelos
//    sobre os mesmos dados (cada um na sua fatia de canais), pega `[z_t, z_f]`
//    de cada e concatena horizontalmente — resultado: embedding 256 × 3 = 768d.
//
//  - O modelo monolítico antigo (`TFC_Backbone.mlpackage`, 11 canais) NÃO está
//    sendo mais usado. Fica em disco mas o código não referencia.
//
//  - Cada `.mlpackage` particionado foi exportado pelo notebook com
//    `input_channels=3, TS_length=300`. Inputs: `x_t`, `x_f` shape [1, 3, 300].
//    Outputs: `h_t`, `z_t`, `h_f`, `z_f`. As classes Swift auto-geradas pelo
//    Xcode são `TFC_Backbone_Acc`, `TFC_Backbone_Gyro`, `TFC_Backbone_GPS`.
//

import Foundation
import CoreML
import Accelerate

/// Erros do extractor.
enum TFCExtractorError: Error {
    case modelNotLoaded
    case invalidInputShape(expected: [Int], got: [Int])
    case mlMultiArrayAllocationFailed
    case predictionFailed(Error)
    case fftSetupFailed
}

/// Configuração da pipeline TFC particionada.
struct TFCConfig {
    /// Canais ESPERADOS NO INPUT da pipeline (`SensorSchema.nChannels = 11`).
    /// Não é o mesmo que `channelsPerPartition` — esse é o número de canais
    /// do dataset cru; cada partição usa só um subset deles.
    let inputChannels: Int = SensorSchema.nChannels

    /// Tamanho de janela = 300 amostras = 15s @ 20 Hz.
    let windowSize: Int = 300

    /// Step entre janelas = window (sem overlap), igual ao Python.
    let stepSize: Int = 300

    /// Canais por partição (todas têm 3 — acc xyz, gyro xyz, lat/lon/alt).
    let channelsPerPartition: Int = 3

    /// Número de partições = 3.
    let nPartitions: Int = 3

    /// Dimensão de saída de cada cabeça projetora (z_t ou z_f).
    let projectionDim: Int = 128

    /// Embedding POR PARTIÇÃO = concat(z_t, z_f) = 256.
    var partitionEmbeddingDim: Int { projectionDim * 2 }

    /// Embedding FINAL = concat das 3 partições = 768.
    /// Esta é a dimensão que o clustering vê. Casada com `AppConstants.embeddingDim`.
    var embeddingDim: Int { partitionEmbeddingDim * nPartitions }
}

/// Descritor de uma partição. Mapeia um nome humano para os índices dos canais
/// no buffer de input (na ordem de `SensorSchema.featureColumns`).
struct TFCPartition {
    let name: String
    /// Índices em `SensorSchema.featureColumns` (0-based) dos canais que
    /// essa partição consome.
    let channelIndices: [Int]
}

/// Lista canônica das 3 partições. **A ORDEM IMPORTA** — bate com a ordem das
/// fatias no embedding final concatenado. Igual a `PARTITIONS_BY_NAME` no
/// notebook Python.
let kTFCPartitions: [TFCPartition] = [
    TFCPartition(name: "Acc",  channelIndices: [0, 1, 2]),  // acc_x, acc_y, acc_z
    TFCPartition(name: "Gyro", channelIndices: [3, 4, 5]),  // gyro_x, gyro_y, gyro_z
    TFCPartition(name: "GPS",  channelIndices: [6, 7, 8]),  // lat, lon, alt
    // OBS: hAcc (idx 9) e vAcc (idx 10) FICAM DE FORA. O Python só usa lat/lon/alt
    // na partição GPS — os canais de accuracy não vão pro modelo.
]

/// Extractor particionado. Substitui o antigo `TFCFeatureExtractor` monolítico.
/// Carrega os 3 backbones particionados e produz embeddings 768-d concatenados.
///
/// API pública mantida igual à versão anterior: `init() throws` +
/// `embed(windowed:) throws -> [Float]`. O `SensorManagerViewModel` não muda.
final class TFCFeatureExtractor {
    let config = TFCConfig()

    private let accModel: TFC_Backbone_Acc
    private let gyroModel: TFC_Backbone_Gyro
    private let gpsModel: TFC_Backbone_GPS

    /// - Parameter computeUnits: política de compute do CoreML. O default
    ///   `.cpuAndNeuralEngine` preserva o comportamento antigo (e o `init()`
    ///   sem argumentos continua válido por causa do valor default). O
    ///   benchmark de latência usa `.cpuOnly` para forçar a comparação ANE×CPU
    ///   — é exatamente este o flag que torna o experimento possível.
    init(computeUnits: MLComputeUnits = .cpuAndNeuralEngine) throws {
        let cfg = MLModelConfiguration()
        // CPU + ANE: o TFC é pequeno (conv1d + linear), roda muito bem no
        // Neural Engine quando disponível, com CPU como fallback. Carregar
        // os 3 modelos é instantâneo (~1ms cada) — não precisa otimizar load.
        cfg.computeUnits = computeUnits

        self.accModel  = try TFC_Backbone_Acc(configuration: cfg)
        self.gyroModel = try TFC_Backbone_Gyro(configuration: cfg)
        self.gpsModel  = try TFC_Backbone_GPS(configuration: cfg)
    }

    // MARK: - API pública

    /// Embed completo de um `WindowedSensorDataset`. Retorna `(W, 768)` flat
    /// row-major, float32, onde o eixo D=768 é o concat de:
    ///   [z_t_acc(128) | z_f_acc(128) | z_t_gyro(128) | z_f_gyro(128) | z_t_gps(128) | z_f_gps(128)]
    ///
    /// **IMPORTANTE**: a normalização global por canal (`normalize_features`
    /// no Python) deve ter sido aplicada ao input ANTES desta chamada. Quem
    /// faz isso é o `runDailyClustering` no `SensorManagerViewModel`.
    func embed(windowed: WindowedSensorDataset) throws -> [Float] {
        let W = windowed.count
        guard W > 0 else { return [] }

        precondition(windowed.windowSize == config.windowSize,
                     "windowSize esperado \(config.windowSize), recebido \(windowed.windowSize)")
        precondition(windowed.nChannels == config.inputChannels,
                     "inputChannels esperado \(config.inputChannels), recebido \(windowed.nChannels)")

        let T = config.windowSize
        let totalD = config.embeddingDim              // 768
        let partD = config.partitionEmbeddingDim      // 256
        let projD = config.projectionDim              // 128

        var out = [Float](repeating: 0, count: W * totalD)

        for w in 0..<W {
            // (C=11, T) flat — buffer da janela inteira.
            let windowFlat = Array(windowed.window(at: w))

            for (pIdx, partition) in kTFCPartitions.enumerated() {
                // 1) Extrai os 3 canais da partição: (C_part=3, T) flat row-major.
                let partInput = extractPartitionInput(
                    windowFlat: windowFlat,
                    channelIndices: partition.channelIndices,
                    T: T
                )

                // 2) x_t = sinal cru da partição; x_f = |FFT| por canal.
                let xT = partInput
                let xF = magnitudeFFTPerChannel(
                    buffer: partInput,
                    channels: config.channelsPerPartition,
                    timeSteps: T
                )

                // 3) Inferência no modelo da partição correta.
                let (zt, zf) = try runPartitionedModel(
                    partitionIndex: pIdx,
                    xT: xT, xF: xF,
                    C: config.channelsPerPartition,
                    T: T
                )

                // 4) Escreve [z_t | z_f] na fatia desta partição no embedding final.
                //    Layout: emb[w][pIdx*256 .. pIdx*256+128] = z_t
                //            emb[w][pIdx*256+128 .. pIdx*256+256] = z_f
                let base = w * totalD + pIdx * partD
                for i in 0..<projD {
                    out[base + i] = zt[i]
                    out[base + projD + i] = zf[i]
                }
            }
        }
        return out
    }

    // MARK: - Instrumentação (benchmark de latência)

    /// Tempos por estágio de UMA janela, em nanosegundos (clock monotônico).
    /// `modelNs` tem um elemento por partição na ordem de `kTFCPartitions`
    /// (0=Acc, 1=Gyro, 2=GPS). `fftNs` é a soma das 3 FFTs por partição.
    struct WindowTiming {
        var fftNs: UInt64 = 0
        var modelNs: [UInt64] = [0, 0, 0]
        var totalNs: UInt64 = 0
    }

    /// Igual ao corpo interno de `embed(windowed:)` para UMA janela, mas
    /// cronometrando cada estágio. Recebe a janela já no layout flat
    /// `(C=inputChannels, T=windowSize)` row-major (igual ao que
    /// `WindowedSensorDataset.window(at:)` produz). Usado só pelo
    /// `LatencyBenchmark`; o caminho de produção continua em `embed(windowed:)`.
    func embedTimedSingleWindow(_ windowFlat: [Float]) throws
        -> (embedding: [Float], timing: WindowTiming) {
        precondition(windowFlat.count == config.inputChannels * config.windowSize,
                     "windowFlat deve ter inputChannels*windowSize = "
                     + "\(config.inputChannels * config.windowSize) floats, "
                     + "recebido \(windowFlat.count)")

        let T = config.windowSize
        let totalD = config.embeddingDim
        let partD = config.partitionEmbeddingDim
        let projD = config.projectionDim

        var out = [Float](repeating: 0, count: totalD)
        var timing = WindowTiming()
        let tStart = DispatchTime.now().uptimeNanoseconds

        for (pIdx, partition) in kTFCPartitions.enumerated() {
            let partInput = extractPartitionInput(
                windowFlat: windowFlat,
                channelIndices: partition.channelIndices,
                T: T
            )
            let xT = partInput

            let fftStart = DispatchTime.now().uptimeNanoseconds
            let xF = magnitudeFFTPerChannel(
                buffer: partInput,
                channels: config.channelsPerPartition,
                timeSteps: T
            )
            let fftEnd = DispatchTime.now().uptimeNanoseconds
            timing.fftNs &+= fftEnd &- fftStart

            let mStart = DispatchTime.now().uptimeNanoseconds
            let (zt, zf) = try runPartitionedModel(
                partitionIndex: pIdx,
                xT: xT, xF: xF,
                C: config.channelsPerPartition,
                T: T
            )
            let mEnd = DispatchTime.now().uptimeNanoseconds
            timing.modelNs[pIdx] = mEnd &- mStart

            let base = pIdx * partD
            for i in 0..<projD {
                out[base + i] = zt[i]
                out[base + projD + i] = zf[i]
            }
        }

        timing.totalNs = DispatchTime.now().uptimeNanoseconds &- tStart
        return (out, timing)
    }

    // MARK: - Helpers internos

    /// Extrai um subconjunto de canais do buffer flat (C_full, T) row-major e
    /// devolve novo buffer flat (C_part, T) row-major.
    private func extractPartitionInput(
        windowFlat: [Float],
        channelIndices: [Int],
        T: Int
    ) -> [Float] {
        let cPart = channelIndices.count
        var out = [Float](repeating: 0, count: cPart * T)
        for (newCh, oldCh) in channelIndices.enumerated() {
            // Copia contígua: T floats sequenciais do canal `oldCh`.
            // Pointer-aware seria mais rápido; loop direto é claro o bastante
            // pra T=300 × 3 canais × W janelas (poucos ms total).
            for t in 0..<T {
                out[newCh * T + t] = windowFlat[oldCh * T + t]
            }
        }
        return out
    }

    /// Despacha pro modelo correto baseado em `partitionIndex`. Devolve
    /// `(z_t, z_f)` como `[Float]` de tamanho `projectionDim` cada.
    private func runPartitionedModel(
        partitionIndex: Int,
        xT: [Float],
        xF: [Float],
        C: Int,
        T: Int
    ) throws -> ([Float], [Float]) {
        let shape: [NSNumber] = [1, NSNumber(value: C), NSNumber(value: T)]
        guard let xTArr = try? MLMultiArray(shape: shape, dataType: .float32),
              let xFArr = try? MLMultiArray(shape: shape, dataType: .float32) else {
            throw TFCExtractorError.mlMultiArrayAllocationFailed
        }
        try copyFloatBuffer(xT, into: xTArr)
        try copyFloatBuffer(xF, into: xFArr)

        do {
            switch partitionIndex {
            case 0:
                let o = try accModel.prediction(x_t: xTArr, x_f: xFArr)
                return (mlArrayToFloats(o.z_t), mlArrayToFloats(o.z_f))
            case 1:
                let o = try gyroModel.prediction(x_t: xTArr, x_f: xFArr)
                return (mlArrayToFloats(o.z_t), mlArrayToFloats(o.z_f))
            case 2:
                let o = try gpsModel.prediction(x_t: xTArr, x_f: xFArr)
                return (mlArrayToFloats(o.z_t), mlArrayToFloats(o.z_f))
            default:
                preconditionFailure("partition index inválido: \(partitionIndex)")
            }
        } catch {
            throw TFCExtractorError.predictionFailed(error)
        }
    }

    // MARK: - FFT (paridade com `fft.fft(x).abs()` do PyTorch)
    //
    // Tratado por canal. Reaproveita o mesmo algoritmo do monolítico —
    // só muda o `C` (3 em vez de 11). Para T=300 (= 2² × 3 × 5²), vDSP_DFT
    // não suporta (precisa de f × 2^n com f ∈ {1,3,5,15}), então o fallback
    // O(T²) é usado. Custo: ~90k mul por canal × 3 canais × 3 partições
    // × W janelas. Pra W=500 ainda fica em centenas de ms total.

    func magnitudeFFTPerChannel(buffer: [Float], channels C: Int, timeSteps T: Int) -> [Float] {
        precondition(buffer.count == C * T, "Buffer deve ter C*T floats")

        guard let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(T), .FORWARD) else {
            return naiveDFTMagnitudePerChannel(buffer: buffer, channels: C, timeSteps: T)
        }
        defer { vDSP_DFT_DestroySetup(setup) }

        var result = [Float](repeating: 0, count: C * T)
        var inputReal = [Float](repeating: 0, count: T)
        var inputImag = [Float](repeating: 0, count: T)
        var outputReal = [Float](repeating: 0, count: T)
        var outputImag = [Float](repeating: 0, count: T)

        for ch in 0..<C {
            for t in 0..<T { inputReal[t] = buffer[ch * T + t] }
            for t in 0..<T { inputImag[t] = 0 }

            vDSP_DFT_Execute(setup,
                             &inputReal, &inputImag,
                             &outputReal, &outputImag)

            outputReal.withUnsafeMutableBufferPointer { reP in
                outputImag.withUnsafeMutableBufferPointer { imP in
                    var split = DSPSplitComplex(realp: reP.baseAddress!, imagp: imP.baseAddress!)
                    var mags = [Float](repeating: 0, count: T)
                    mags.withUnsafeMutableBufferPointer { magP in
                        vDSP_zvabs(&split, 1, magP.baseAddress!, 1, vDSP_Length(T))
                    }
                    for t in 0..<T { result[ch * T + t] = mags[t] }
                }
            }
        }
        return result
    }

    private func naiveDFTMagnitudePerChannel(buffer: [Float], channels C: Int, timeSteps T: Int) -> [Float] {
        var result = [Float](repeating: 0, count: C * T)
        let twoPiOverT = 2.0 * Double.pi / Double(T)
        for ch in 0..<C {
            for k in 0..<T {
                var re = 0.0
                var im = 0.0
                for t in 0..<T {
                    let angle = twoPiOverT * Double(k) * Double(t)
                    let x = Double(buffer[ch * T + t])
                    re += x * cos(angle)
                    im -= x * sin(angle)
                }
                result[ch * T + k] = Float(sqrt(re * re + im * im))
            }
        }
        return result
    }

    // MARK: - MLMultiArray helpers

    private func copyFloatBuffer(_ src: [Float], into dst: MLMultiArray) throws {
        precondition(dst.dataType == .float32, "Esperado float32")
        precondition(src.count == dst.count, "Tamanho divergente: src=\(src.count) dst=\(dst.count)")
        let ptr = dst.dataPointer.assumingMemoryBound(to: Float.self)
        src.withUnsafeBufferPointer { sp in
            ptr.update(from: sp.baseAddress!, count: src.count)
        }
    }

    private func mlArrayToFloats(_ arr: MLMultiArray) -> [Float] {
        let n = arr.count
        var out = [Float](repeating: 0, count: n)
        let ptr = arr.dataPointer.assumingMemoryBound(to: Float.self)
        out.withUnsafeMutableBufferPointer { dp in
            dp.baseAddress!.update(from: ptr, count: n)
        }
        return out
    }
}
