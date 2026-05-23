//
//  SensorTensor.swift
//  MotionApp
//
//  Espelho Swift de `SensorTensor` + `WindowedSensorDataset` + `normalize_features`
//  da pipeline Python de referência (exemplo_refactored.ipynb).
//
//  Invariantes (source of truth = Python):
//  - timestamps NUNCA entram no tensor que vai para o modelo.
//  - features são float32, channel-last na origem (N, C) e channel-first quando
//    viram windows (W, C, T) para o Conv1d/CoreML.
//  - O esquema canônico é:
//      timestamp, acc_x, acc_y, acc_z, gyro_x, gyro_y, gyro_z,
//      latitude, longitude, altitude, horizontal_accuracy, vertical_accuracy
//    Ou seja, C = 11 features (sem o timestamp).
//

import Foundation

// MARK: - Schema canônico

/// Nome das colunas do CSV exportado pelo MoveCollector.
/// Equivale a `RAW_COLUMNS` do Python.
enum SensorSchema {
    static let rawColumns: [String] = [
        "timestamp",
        "acc_x", "acc_y", "acc_z",
        "gyro_x", "gyro_y", "gyro_z",
        "latitude", "longitude", "altitude",
        "horizontal_accuracy", "vertical_accuracy",
    ]

    /// Tudo menos o timestamp — o que vai virar tensor.
    /// Equivale a `FEATURE_COLUMNS` do Python.
    static let featureColumns: [String] = Array(rawColumns.dropFirst())

    /// nome → índice no feature-space (0-based).
    /// Equivale a `FEATURE_INDEX` do Python.
    static let featureIndex: [String: Int] = {
        var dict: [String: Int] = [:]
        for (i, name) in featureColumns.enumerated() {
            dict[name] = i
        }
        return dict
    }()

    /// Atalhos para uso fora deste arquivo.
    static let nChannels: Int = featureColumns.count        // 11
    static let accChannels: [Int] = [0, 1, 2]               // acc_x/y/z
    static let gyroChannels: [Int] = [3, 4, 5]              // gyro_x/y/z
    static let gpsChannels: [Int] = [6, 7, 8, 9, 10]        // lat, lon, alt, hAcc, vAcc
    static let latLonChannels: [Int] = [6, 7]               // só lat/lon para o mapa
}

// MARK: - Normalização (apenas features)

/// Tipo de normalização suportado, espelhando o `kind` do Python
/// (`"standard"`, `"minmax"`, `None`).
enum NormalizationKind {
    case standard
    case minmax
    case none
}

/// Normaliza features in-place no buffer flat row-major (N, C) float32.
/// Equivale a `normalize_features(features, kind)` do Python.
///
/// - Parameters:
///   - buffer: buffer flat row-major de tamanho `n * c`, float32. Modificado in-place.
///   - n: número de amostras.
///   - c: número de canais (features).
///   - kind: tipo de normalização.
///
/// Por quê in-place + flat: evitar alocar (N, C) como [[Float]] enquanto rola
/// no iPhone — pra 30 min @ 20 Hz isso são ~400k entries × 11 colunas.
func normalizeFeaturesInPlace(
    buffer: inout [Float],
    n: Int,
    c: Int,
    kind: NormalizationKind
) {
    guard kind != .none, n > 0, c > 0, buffer.count == n * c else { return }

    switch kind {
    case .standard:
        // Média + std por canal (column-wise sobre row-major buffer).
        for col in 0..<c {
            var sum: Float = 0
            var sumSq: Float = 0
            for row in 0..<n {
                let v = buffer[row * c + col]
                sum += v
                sumSq += v * v
            }
            let mean = sum / Float(n)
            // Var populacional (Python's `np.std` default ddof=0).
            var variance = sumSq / Float(n) - mean * mean
            if variance < 0 { variance = 0 }
            var std = Float(sqrt(variance))
            if std == 0 { std = 1 }
            for row in 0..<n {
                let idx = row * c + col
                buffer[idx] = (buffer[idx] - mean) / std
            }
        }
    case .minmax:
        for col in 0..<c {
            var lo: Float = .greatestFiniteMagnitude
            var hi: Float = -.greatestFiniteMagnitude
            for row in 0..<n {
                let v = buffer[row * c + col]
                if v < lo { lo = v }
                if v > hi { hi = v }
            }
            var rng = hi - lo
            if rng == 0 { rng = 1 }
            for row in 0..<n {
                let idx = row * c + col
                buffer[idx] = (buffer[idx] - lo) / rng
            }
        }
    case .none:
        break
    }
}

// MARK: - SensorTensor

/// Container imutável que mantém `timestamps` (Int64 Unix-ms) estritamente
/// separados de `features` (float32, row-major (N, C)).
///
/// Equivale ao `@dataclass SensorTensor` do Python.
struct SensorTensor {
    /// Timestamps em milissegundos Unix epoch (mesma unidade gravada no Core Data).
    /// Tamanho N.
    let timestamps: [Int64]

    /// Features flat row-major. Tamanho N * featureNames.count.
    /// **CRITICAL**: timestamp NUNCA entra aqui. Esta é uma invariante da pipeline.
    let features: [Float]

    /// Nomes das features na ordem das colunas do `features`.
    /// Tamanho C. Permite indexar por nome via `featureNames.firstIndex(of:)`.
    let featureNames: [String]

    /// Número de amostras (linhas).
    var count: Int { timestamps.count }

    /// Número de canais (colunas em `features`).
    var nChannels: Int { featureNames.count }

    /// Acesso conveniente por (row, col) na matriz row-major.
    @inline(__always)
    func feature(row: Int, col: Int) -> Float {
        return features[row * nChannels + col]
    }

    /// Cria um SensorTensor a partir de buffers já normalizados.
    init(timestamps: [Int64], features: [Float], featureNames: [String]) {
        precondition(features.count == timestamps.count * featureNames.count,
                     "features.count (\(features.count)) deve bater com N(\(timestamps.count)) * C(\(featureNames.count))")
        self.timestamps = timestamps
        self.features = features
        self.featureNames = featureNames
    }

    /// Aplica normalização e retorna um novo SensorTensor com os mesmos
    /// `timestamps` e `featureNames`, mas `features` transformados.
    func normalized(_ kind: NormalizationKind) -> SensorTensor {
        guard kind != .none else { return self }
        var buf = features
        normalizeFeaturesInPlace(buffer: &buf, n: count, c: nChannels, kind: kind)
        return SensorTensor(timestamps: timestamps, features: buf, featureNames: featureNames)
    }

    /// Retorna apenas um subconjunto de canais (feature-space indices).
    /// Útil para PARTITIONED inference (acc / gyro / GPS).
    func subset(channels: [Int]) -> SensorTensor {
        let newC = channels.count
        var newFeats = [Float](repeating: 0, count: count * newC)
        for row in 0..<count {
            for (newCol, oldCol) in channels.enumerated() {
                newFeats[row * newC + newCol] = features[row * nChannels + oldCol]
            }
        }
        let newNames = channels.map { featureNames[$0] }
        return SensorTensor(timestamps: timestamps, features: newFeats, featureNames: newNames)
    }
}

// MARK: - Windowed view

/// Janela deslizante de `windowSize` amostras com passo `stepSize` sobre
/// um `SensorTensor`.
///
/// Equivale a `WindowedSensorDataset` do Python. Diferenças notáveis:
/// - Aqui ficamos com buffer flat (W * C * T) em vez de [[Float]] aninhado
///   para não fragmentar memória durante coleta de horas.
/// - `__getitem__(idx)` do Python vira `window(at:)` retornando um sub-buffer.
/// - Não há shuffle aqui (não treinamos on-device — só inferimos).
///
/// IMPORTANTE: o layout interno é `(W, C, T)` row-major — igual ao Python
/// (que faz `np.swapaxes(win, 1, 2)` para alimentar Conv1d). Isso é o que o
/// modelo CoreML `TFC_Backbone` espera (`x_t` de shape `[1, 11, 300]`).
struct WindowedSensorDataset {
    /// Janelas empilhadas, layout (W, C, T) row-major.
    let data: [Float]
    /// Índices na série original onde cada janela começa. Tamanho W.
    let starts: [Int]
    /// Timestamps brutos da série completa (mesma referência do SensorTensor original).
    let timestamps: [Int64]
    let windowSize: Int
    let stepSize: Int
    let nChannels: Int

    var count: Int { starts.count }

    /// Wall-clock ms do offset `offset` dentro da janela `idx`.
    /// Equivale a `window_timestamp(window_idx, offset)` do Python.
    @inline(__always)
    func windowTimestampMs(at idx: Int, offset: Int = 0) -> Int64 {
        return timestamps[starts[idx] + offset]
    }

    /// Timestamp inicial (offset=0) de cada janela. Usado pelo EpisodeBuilder.
    var windowStartTimestamps: [Int64] {
        return starts.map { timestamps[$0] }
    }

    /// Constrói as janelas a partir de um SensorTensor (já normalizado).
    init(sensors: SensorTensor, windowSize: Int, stepSize: Int) {
        precondition(windowSize > 0 && stepSize > 0, "windowSize e stepSize devem ser positivos")
        self.windowSize = windowSize
        self.stepSize = stepSize
        self.nChannels = sensors.nChannels
        self.timestamps = sensors.timestamps

        let n = sensors.count
        let c = sensors.nChannels

        guard n >= windowSize else {
            self.data = []
            self.starts = []
            return
        }

        // Mesma fórmula do Python: starts = arange(0, n - W + 1, step).
        var startsBuf: [Int] = []
        var s = 0
        while s <= n - windowSize {
            startsBuf.append(s)
            s += stepSize
        }
        self.starts = startsBuf

        // Aloca (W * C * T) e preenche transpondo (T, C) → (C, T) por janela.
        // Mantém leitura sequencial do `sensors.features` para cache locality.
        let W = startsBuf.count
        let T = windowSize
        var buf = [Float](repeating: 0, count: W * c * T)

        for w in 0..<W {
            let baseIn = startsBuf[w] * c          // início da janela na série original (row-major NxC)
            let baseOut = w * c * T                // início da janela no buffer (W,C,T)
            for t in 0..<T {
                let rowIn = baseIn + t * c         // amostra t da janela na série original
                for ch in 0..<c {
                    // (W=w, C=ch, T=t) = baseOut + ch * T + t
                    buf[baseOut + ch * T + t] = sensors.features[rowIn + ch]
                }
            }
        }

        self.data = buf
    }

    /// Retorna a janela `idx` no layout (C, T) flat (C * T floats), pronta
    /// para virar `MLMultiArray` de shape `[1, C, T]`.
    ///
    /// Não copia — devolve sub-array. Para inferência batched, prefira
    /// percorrer `data` direto com offsets.
    func window(at idx: Int) -> ArraySlice<Float> {
        let stride = nChannels * windowSize
        let start = idx * stride
        return data[start..<(start + stride)]
    }
}
