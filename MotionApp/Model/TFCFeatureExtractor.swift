//
//  TFCFeatureExtractor.swift
//  MotionApp
//
//  Wrapper Swift do `TFC_Backbone.mlpackage`.
//
//  Equivalência com a pipeline Python de referência:
//  - `TFC_Transforms.__call__` em Python computa `freq = fft.fft(x).abs()` e
//    devolve `(x, aug_t, freq, aug_f)`. Em **inferência** (sem treino) só
//    precisamos de `x_t = x` e `x_f = |FFT(x)|` — o resto é augmentation só
//    usada no contrastive loss.
//  - O backbone recebe `(x_t, x_f) shape [1, 11, 300]` e devolve
//    `(h_t [1,2400], z_t [1,128], h_f [1,2400], z_f [1,128])`.
//  - O embedding final usado para clustering é `concat([z_t, z_f]) shape [256]`,
//    em float32. Cf. `FeatureExtractor._embed` no Python.
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

/// Configuração da pipeline TFC, casada com o `.mlpackage`.
struct TFCConfig {
    /// Canais esperados pelo backbone (= `SensorSchema.nChannels` = 11).
    let inputChannels: Int = SensorSchema.nChannels
    /// Tamanho de janela (= 300, declarado no .mlpackage).
    let windowSize: Int = 300
    /// Passo entre janelas. Igual ao Python: `step_size = window_size` (sem overlap).
    let stepSize: Int = 300
    /// Dimensão de saída do projector (= 128 por cabeça). `concat([z_t, z_f])` = 256.
    let projectionDim: Int = 128
    /// Dimensão final do embedding usado para clustering (= 256).
    var embeddingDim: Int { projectionDim * 2 }
}

/// Extractor on-device baseado no `TFC_Backbone.mlpackage`.
///
/// Uso típico:
/// ```swift
/// let extractor = try TFCFeatureExtractor()
/// let embeddings = try extractor.embed(windowed: windowedDataset)
/// // embeddings: [Float] de tamanho W * 256, row-major (W, 256).
/// ```
final class TFCFeatureExtractor {
    let config = TFCConfig()
    private let model: TFC_Backbone

    /// FFT setup reutilizável (alocar uma vez é muito mais barato que por janela).
    /// Tamanho fixo = windowSize (300), real-to-complex via vDSP.
    private let fftSetup: vDSP.FFT<DSPSplitComplex>?

    init() throws {
        // Por que CPU+ANE: o TFC tem só conv1d + batchnorm + linear — roda
        // muito bem no Neural Engine. CPU como fallback é instantâneo p/ esta
        // ordem de grandeza (W ~ poucas centenas em coleta curta).
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuAndNeuralEngine
        self.model = try TFC_Backbone(configuration: cfg)

        // vDSP precisa de N potência-de-2. 300 NÃO é. Vamos pad-to-512 (próxima
        // potência-de-2) e usar só os primeiros 300 do output — mesmo que o
        // Python (numpy.fft.fft com N arbitrário) o output magnitude é
        // diferente bin-a-bin, mas o que vai pro modelo é "uma representação
        // de frequência de magnitude da janela". O modelo foi treinado com
        // np.fft.fft direto de tamanho 300, então pra paridade exata vamos
        // computar via Bluestein/Chirp-Z (não-power-of-two).
        //
        // Atalho prático: vDSP_DFT (em vez de vDSP.FFT) aceita comprimentos
        // arbitrários — usamos isso abaixo, então `fftSetup` aqui fica nil.
        self.fftSetup = nil
    }

    // MARK: - API pública

    /// Embed completo de um `WindowedSensorDataset`. Devolve `(W, 256)` flat
    /// row-major, float32.
    func embed(windowed: WindowedSensorDataset) throws -> [Float] {
        let W = windowed.count
        guard W > 0 else { return [] }
        precondition(windowed.windowSize == config.windowSize,
                     "windowSize esperado \(config.windowSize), recebido \(windowed.windowSize)")
        precondition(windowed.nChannels == config.inputChannels,
                     "inputChannels esperado \(config.inputChannels), recebido \(windowed.nChannels)")

        var out = [Float](repeating: 0, count: W * config.embeddingDim)

        // Vai janela-a-janela. Para coleta curta (W << 100) isso é trivial em latência.
        // Se virar gargalo, agrupar em batch via MLBatchProvider é trivial.
        for w in 0..<W {
            let (zt, zf) = try embedSingle(windowed: windowed, idx: w)
            for i in 0..<config.projectionDim {
                out[w * config.embeddingDim + i] = zt[i]
            }
            for i in 0..<config.projectionDim {
                out[w * config.embeddingDim + config.projectionDim + i] = zf[i]
            }
        }
        return out
    }

    /// Embed de uma janela específica. Retorna `(z_t, z_f)` cada um com 128 floats.
    func embedSingle(windowed: WindowedSensorDataset, idx: Int) throws -> ([Float], [Float]) {
        // 1) Buffer da janela (layout C, T) flat de tamanho C*T.
        let slice = windowed.window(at: idx)
        let cFlat = Array(slice)  // copia barata; CT = 11*300 = 3300 floats.

        // 2) x_t = janela direta; x_f = |DFT(janela)|, computado por canal.
        let xT = cFlat
        let xF = magnitudeFFTPerChannel(buffer: cFlat,
                                        channels: config.inputChannels,
                                        timeSteps: config.windowSize)

        // 3) Embala em MLMultiArray [1, C, T] float32 cada.
        let shape: [NSNumber] = [1,
                                 NSNumber(value: config.inputChannels),
                                 NSNumber(value: config.windowSize)]
        guard let xTArr = try? MLMultiArray(shape: shape, dataType: .float32),
              let xFArr = try? MLMultiArray(shape: shape, dataType: .float32) else {
            throw TFCExtractorError.mlMultiArrayAllocationFailed
        }
        try copyFloatBuffer(xT, into: xTArr)
        try copyFloatBuffer(xF, into: xFArr)

        // 4) Inferência.
        let output: TFC_BackboneOutput
        do {
            output = try model.prediction(x_t: xTArr, x_f: xFArr)
        } catch {
            throw TFCExtractorError.predictionFailed(error)
        }

        // 5) Extrai z_t [1, 128] e z_f [1, 128] como Float arrays.
        let zT = mlArrayToFloats(output.z_t)
        let zF = mlArrayToFloats(output.z_f)
        return (zT, zF)
    }

    // MARK: - FFT (paridade com `fft.fft(x).abs()` do PyTorch)

    /// |FFT| por canal sobre buffer (C, T) flat.
    /// Devolve buffer (C, T) flat (mesmo shape) com magnitudes.
    ///
    /// Por que vDSP_DFT_zop_CreateSetup com tipo `.complexComplex` e parte
    /// imaginária zerada: replicamos exatamente `torch.fft.fft(x).abs()`, que
    /// trata `x` como sinal complexo de parte real = `x`, parte imaginária = 0,
    /// e devolve N coeficientes complexos cujos módulos são a magnitude.
    /// Usar real-to-complex (.forward) economizaria metade da computação MAS
    /// devolveria só N/2+1 bins, o que QUEBRA a paridade — o modelo viu N=300
    /// bins durante o treino.
    func magnitudeFFTPerChannel(buffer: [Float], channels C: Int, timeSteps T: Int) -> [Float] {
        precondition(buffer.count == C * T, "Buffer deve ter C*T floats")

        // vDSP_DFT_zop_CreateSetup aceita tamanhos não-power-of-2 (vai pra
        // Bluestein internamente). T=300 cai nesse caso.
        guard let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(T), .FORWARD) else {
            // Fallback explícito: implementação naive O(T²). Custo p/ T=300 = 90k mul,
            // ainda barato (<1ms) e garante paridade matemática.
            return naiveDFTMagnitudePerChannel(buffer: buffer, channels: C, timeSteps: T)
        }
        defer { vDSP_DFT_DestroySetup(setup) }

        var result = [Float](repeating: 0, count: C * T)

        // Buffers reutilizáveis por canal.
        var inputReal = [Float](repeating: 0, count: T)
        var inputImag = [Float](repeating: 0, count: T)
        var outputReal = [Float](repeating: 0, count: T)
        var outputImag = [Float](repeating: 0, count: T)

        for ch in 0..<C {
            // Copia o canal `ch` para inputReal (T floats consecutivos).
            for t in 0..<T {
                inputReal[t] = buffer[ch * T + t]
            }
            // inputImag já é zero.
            for t in 0..<T { inputImag[t] = 0 }

            vDSP_DFT_Execute(setup,
                             &inputReal, &inputImag,
                             &outputReal, &outputImag)

            // magnitude = sqrt(re^2 + im^2). Usa vDSP_zvabs para evitar loop manual.
            outputReal.withUnsafeMutableBufferPointer { reP in
                outputImag.withUnsafeMutableBufferPointer { imP in
                    var split = DSPSplitComplex(realp: reP.baseAddress!, imagp: imP.baseAddress!)
                    var mags = [Float](repeating: 0, count: T)
                    mags.withUnsafeMutableBufferPointer { magP in
                        vDSP_zvabs(&split, 1, magP.baseAddress!, 1, vDSP_Length(T))
                    }
                    for t in 0..<T {
                        result[ch * T + t] = mags[t]
                    }
                }
            }
        }
        return result
    }

    /// Fallback ingênuo (não usado se vDSP_DFT estiver disponível).
    /// Idêntico em valor a `torch.fft.fft(x).abs()`.
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

    /// Copia um [Float] flat para um MLMultiArray Float32 contíguo.
    private func copyFloatBuffer(_ src: [Float], into dst: MLMultiArray) throws {
        precondition(dst.dataType == .float32, "Esperado float32")
        precondition(src.count == dst.count, "Tamanho de buffer divergente: src=\(src.count) dst=\(dst.count)")
        let ptr = dst.dataPointer.assumingMemoryBound(to: Float.self)
        src.withUnsafeBufferPointer { sp in
            ptr.update(from: sp.baseAddress!, count: src.count)
        }
    }

    /// Converte um MLMultiArray Float32 para [Float] flat (copia).
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

// MARK: - Partitioned extractor (futuro)

/// Cabide para futuros experimentos com partição (acc / gyro / GPS), espelhando
/// `FeatureExtractor._partitioned_call` do Python. **Não implementado ainda**
/// porque o `.mlpackage` atual tem 11 canais fixos no input. Para suportar
/// partição on-device é preciso converter modelos separados (acc-only,
/// gyro-only, gps-only) e empacotá-los como `.mlpackage` distintos.
///
/// Quando você gerar `TFC_Backbone_acc.mlpackage` etc., instancie cada um
/// e concatene os outputs (256-d × n_partitions) — a interface fica simétrica
/// ao `embed(windowed:)` aqui.
final class PartitionedTFCFeatureExtractor {
    // TODO: instanciar múltiplos modelos quando os .mlpackages estiverem disponíveis.
}
