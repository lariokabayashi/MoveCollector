//
//  Util.swift
//  MotionApp
//
//  Created by Larissa Okabayashi on 19/03/26.
//

import Foundation
import SwiftUI
import CoreMotion
import UniformTypeIdentifiers
import CoreData
import CoreLocation
import CoreML

struct Utils {
    
    func argmax(_ arr: MLShapedArray<Float>) -> Int {
        var bestIndex = 0
        var bestValue = Float.leastNormalMagnitude

        for i in 0..<arr.shape[1] {
            let slice = arr[0, i]
            let value = slice.scalar
            
            if value! > bestValue {
                bestValue = value!
                bestIndex = i
            }
        }
        return bestIndex
    }
    
    func lerp(_ v0: Float, _ v1: Float, alpha: Float) -> Float {
        return v0 + (v1 - v0) * alpha
    }
    
    func interpolateLinear(t: TimeInterval, p0: Sample, p1: Sample) -> Sample {
        let dt = p1.t - p0.t
        let alpha = Float(dt > 0 ? (t - p0.t) / dt : 0.0)
        return Sample(
            t: t,
            ax: lerp(p0.ax, p1.ax, alpha: alpha),
            ay: lerp(p0.ay, p1.ay, alpha: alpha),
            az: lerp(p0.az, p1.az, alpha: alpha),
            gx: lerp(p0.gx, p1.gx, alpha: alpha),
            gy: lerp(p0.gy, p1.gy, alpha: alpha),
            gz: lerp(p0.gz, p1.gz, alpha: alpha)
        )
    }
    
    func resampleToFixedRate(samples: [Sample], startTime: TimeInterval, count: Int, rateHz: Double) -> [Sample] {
        guard samples.count >= 2 else { return samples }
        let dt = 1.0 / rateHz
        var result: [Sample] = []
        result.reserveCapacity(count)
        var i = 0
        for n in 0..<count {
            let targetT = startTime + Double(n) * dt
            while i + 1 < samples.count && samples[i + 1].t < targetT {
                i += 1
            }
            if i + 1 < samples.count {
                let p0 = samples[i]
                let p1 = samples[i + 1]
                if targetT <= p0.t {
                    result.append(Sample(t: targetT, ax: p0.ax, ay: p0.ay, az: p0.az, gx: p0.gx, gy: p0.gy, gz: p0.gz))
                } else if targetT <= p1.t {
                    result.append(interpolateLinear(t: targetT, p0: p0, p1: p1))
                } else {
                    result.append(Sample(t: targetT, ax: p1.ax, ay: p1.ay, az: p1.az, gx: p1.gx, gy: p1.gy, gz: p1.gz))
                }
            } else if let last = samples.last {
                result.append(Sample(t: targetT, ax: last.ax, ay: last.ay, az: last.az, gx: last.gx, gy: last.gy, gz: last.gz))
            }
        }
        return result
    }
    
    let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()
    
    func parseTimestamp(_ s: String?) -> TimeInterval? {
        guard let s = s, let d = isoParser.date(from: s) else { return nil }
        return d.timeIntervalSince1970
    }
    
//    /// Calcula a distância euclidiana entre dois vetores.
//    /// - Parameters:
//    ///   - a: Vetor de valores em Double.
//    ///   - b: Vetor de valores em Double.
//    /// - Returns: Distância euclidiana entre `a` e `b`. Se os vetores tiverem tamanhos diferentes, retorna `nil`.
//    func euclideanDist(a: [Double], b: [Double]) -> Double? {
//        guard a.count == b.count else { return nil }
//        var sum: Double = 0
//        var i = 0
//        let n = a.count
//        while i < n {
//            let d = a[i] - b[i]
//            sum += d * d
//            i += 1
//        }
//        return sqrt(sum)
//    }
    
    // Optimized squared Euclidean distance for Float buffers (no allocations)
    @inline(__always)
    func squaredEuclideanFloat(_ a: UnsafeBufferPointer<Float>, _ b: UnsafeBufferPointer<Float>) -> Float {
        precondition(a.count == b.count)
        var sum: Float = 0
        var i = 0
        let n = a.count
        while i < n {
            let d = a[i] - b[i]
            sum += d * d
            i += 1
        }
        return sum
    }
    
    /// Calcula o índice condensado do elemento (i, j) em uma matriz n x n na forma condensada.
    /// Em uma matriz condensada, apenas elementos fora da diagonal são armazenados.
    /// - Parameters:
    ///   - n: Dimensão da matriz quadrada original (n x n).
    ///   - i: Índice da linha (0-based).
    ///   - j: Índice da coluna (0-based).
    /// - Returns: O índice na forma condensada ou `nil` se (i == j) ou índices inválidos.
    func condensedIndex(n: Int, i: Int, j: Int) -> Int? {
        // Verificações básicas de validade
        guard n > 1, i >= 0, j >= 0, i < n, j < n else { return nil }
        // A diagonal não é representada na forma condensada
        if i == j { return nil }
        if i < j {
            // n * i - (i * (i + 1) // 2) + (j - i - 1)
            let left = n * i
            let tri = i * (i + 1) / 2
            return left - tri + (j - i - 1)
        } else {
            // i > j: n * j - (j * (j + 1) // 2) + (i - j - 1)
            let left = n * j
            let tri = j * (j + 1) / 2
            return left - tri + (i - j - 1)
        }
    }

    /// Retorna o número de elementos em um cluster.
    /// - Parameters:
    ///   - id: ID do cluster.
    ///   - z: Matriz de ligação atual (cada linha contém pelo menos 4 colunas; a quarta coluna é o tamanho do cluster).
    ///   - numFolhas: Número total de folhas (pontos) na base.
    /// - Returns: Número de elementos no cluster.
    func getNumElements(id: Int, z: [[Float]], numFolhas: Int) -> Int {
        if id < numFolhas { return 1 }
        let row = id - numFolhas
        guard row >= 0, row < z.count, z[row].count > 3 else { return 1 }
        // z[row][3] armazena o tamanho do cluster; converte para Int com truncamento.
        return Int(z[row][3])
    }
    
    // Converter MLShapedArray<Float> 1xNxF em [[Float]]
    func shapedArrayTo2D(_ arr: MLShapedArray<Float>) -> [[Float]] {
        precondition(arr.shape.count == 3 && arr.shape[0] == 1, "Esperado shape [1, N, F]")
        let n = arr.shape[1]
        let f = arr.shape[2]
        var result = Array(repeating: Array(repeating: Float(0.0), count: f), count: n)
        for i in 0..<n {
            for j in 0..<f {
                // arr[0, i, j] -> MLShapedArray.Scalar? (Float?), convertemos para Float
                if let v = arr[0, i, j].scalar {
                    result[i][j] = v
                } else {
                    result[i][j] = 0.0
                }
            }
        }
        return result
    }
    
    // Converte [[Float]] para flat [Float] (row-major)
    func flattenFloat2D(_ matrix: [[Float]]) -> [Float] {
        guard !matrix.isEmpty else { return [] }
        var result: [Float] = []
        let cols = matrix[0].count
        result.reserveCapacity(matrix.count * cols)
        for row in matrix {
            result.append(contentsOf: row)
        }
        return result
    }
    
    // MARK: - Data Conversion (Float ↔ Data)
    
    /// Converte array flat de Float para Data (raw bytes).
    /// Usado para salvar features em Core Data de forma eficiente.
    func flatFloatToData(_ buffer: [Float]) -> Data {
        return buffer.withUnsafeBufferPointer { Data(buffer: $0) }
    }
    
    /// Converte Data (raw bytes) para matriz 2D de Float.
    /// Usado para reconstruir features do Core Data.
    func dataToFloat2D(_ data: Data, rows: Int, cols: Int) -> [[Float]] {
        precondition(rows >= 0 && cols >= 0, "Invalid dimensions")
        let count = rows * cols
        
        // Converte Data → [Float] flat
        let flatBuffer = data.withUnsafeBytes {
            Array(UnsafeBufferPointer<Float>(
                start: $0.baseAddress!.assumingMemoryBound(to: Float.self),
                count: count
            ))
        }
        
        // Converte [Float] flat → [[Float]] 2D
        var result: [[Float]] = []
        result.reserveCapacity(rows)
        
        for r in 0..<rows {
            var row: [Float] = []
            row.reserveCapacity(cols)
            for c in 0..<cols {
                row.append(flatBuffer[r * cols + c])
            }
            result.append(row)
        }
        return result
    }
    
    // MARK: - Unsafe Buffer Operations (Performance Critical)

    /// Cria uma view (sem cópia) de uma linha em um buffer flat.
    /// Usado no clustering para evitar alocações desnecessárias.
    func rowSliceFloat(buffer: [Float], cols: Int, row: Int) -> UnsafeBufferPointer<Float> {
        let start = row * cols
        return buffer.withUnsafeBufferPointer { ptr in
            let base = ptr.baseAddress! + start
            return UnsafeBufferPointer(start: base, count: cols)
        }
    }
    
    /// Variante de linkage com parada antecipada: interrompe quando restarem k clusters.
    /// IMPORTANTE: Para datasets grandes, use downsample ANTES de chamar este método!
    /// - Parameters:
    ///   - matrix: Matriz 2D de Float contendo os dados (N x F).
    ///   - k: Número alvo de clusters finais (k >= 1).
    /// - Returns: Matriz de ligação parcial (até n-k merges) no formato [left, right, dist, size].
    func linkageAdjacentWard(_ matrix: [[Float]], stopAtK k: Int) -> [[Float]] {
        guard !matrix.isEmpty else { return [] }
        let nSamples = matrix.count
        guard nSamples >= 2 else { return [] }
        
        // CRITICAL: Safety check to prevent excessive memory usage
        // For N samples, dist dictionary can grow to ~N entries (adjacent + Ward updates)
        // Memory ~ N × 20 bytes per entry
        let maxSafeSamples = 2000  // ~40 KB for dist + reasonable compute time
        if nSamples > maxSafeSamples {
            print("[WARNING] linkageAdjacentWard: Input has \(nSamples) samples (max recommended: \(maxSafeSamples)). Consider more aggressive downsampling!")
        }
        
        let kClamped = max(1, min(k, nSamples))
        
        // Prepare flat buffer for efficient row access
        let cols = matrix[0].count
        let buffer = flattenFloat2D(matrix)

        // Matriz de ligação Z (no máximo nSamples - 1 merges)
        var z = Array(repeating: Array(repeating: Float(0.0), count: 4), count: nSamples - 1)

        // Clusters iniciais: 0..nSamples-1
        var clusters = Array(0..<nSamples)

        var clusterSize: [Int: Float] = [:]
        for i in 0..<nSamples { clusterSize[i] = 1.0 }
        
        // OPTIMIZATION: Only compute distances on-demand instead of all N×N upfront
        var dist: [PairKey: Float] = [:]
        
        // Helper to compute or retrieve distance (lazy evaluation)
        func getDistance(_ u: Int, _ v: Int) -> Float {
            let key = PairKey(u: u, v: v)
            if let cached = dist[key] { return cached }
            
            // Compute on-demand for original samples only
            if u < nSamples && v < nSamples {
                let ai = rowSliceFloat(buffer: buffer, cols: cols, row: u)
                let bj = rowSliceFloat(buffer: buffer, cols: cols, row: v)
                let d2 = squaredEuclideanFloat(ai, bj)
                let d = sqrt(d2)
                dist[key] = d
                return d
            }
            return Float.greatestFiniteMagnitude
        }

        // Versão para controle de validade dos pares na heap
        var aliveVersion = Array(repeating: 0, count: 2 * nSamples)

        // Heap mínimo para pares adjacentes (usando Double apenas para AdjPair)
        var heap = BinaryMinHeap<AdjPair>()

        // Construir heap inicial com distâncias entre pares adjacentes APENAS
        if clusters.count > 1 {
            for j in 0..<(clusters.count - 1) {
                let left = clusters[j]
                let right = clusters[j + 1]
                let v = max(aliveVersion[left], aliveVersion[right])
                let d = getDistance(left, right)  // Lazy compute only adjacent pairs
                heap.insert(AdjPair(left: left, right: right, dist: d, version: v))
            }
        }

        // Número de merges que precisamos executar para parar em k clusters: nSamples - k
        let mergesToDo = nSamples - kClamped
        var performed = 0

        while performed < mergesToDo {
            var minPair: AdjPair? = nil
            var pos: Int? = nil

            // Encontrar o par válido no heap
            while let pair = heap.popMin() {
                if pair.version != max(aliveVersion[pair.left], aliveVersion[pair.right]) {
                    continue
                }
                if let p = clusters.firstIndex(of: pair.left), p + 1 < clusters.count, clusters[p + 1] == pair.right {
                    minPair = pair
                    pos = p
                    break
                }
            }

            guard let pair = minPair, let p = pos else { break }

            let minDist = Float(pair.dist)
            let numElem = clusterSize[pair.left, default: 1.0] + clusterSize[pair.right, default: 1.0]

            z[performed][0] = Float(clusters[p])
            z[performed][1] = Float(clusters[p + 1])
            z[performed][2] = minDist
            z[performed][3] = numElem

            // Atualiza os clusters: remove os dois e insere o novo id (nSamples + performed)
            clusters.remove(at: p)
            clusters.remove(at: p)
            let newId = nSamples + performed
            clusters.insert(newId, at: p)

            let sizeLeft = clusterSize[pair.left] ?? 1.0
            let sizeRight = clusterSize[pair.right] ?? 1.0
            clusterSize[newId] = sizeLeft + sizeRight
            clusterSize[pair.left] = nil
            clusterSize[pair.right] = nil

            aliveVersion[newId] = max(aliveVersion[pair.left], aliveVersion[pair.right]) + 1

            // Remove dist entries for merged clusters with other clusters
            for c in clusters where c != newId {
                dist[PairKey(u: pair.left, v: c)] = nil
                dist[PairKey(u: pair.right, v: c)] = nil
            }
            dist[PairKey(u: pair.left, v: pair.right)] = nil

            // Update distances with new cluster using Ward formula
            for c in clusters where c != newId {
                let sizeA = sizeLeft
                let sizeB = sizeRight
                let sizeC = clusterSize[c] ?? 1.0
                
                // Use cached or lazy-computed distances
                let keyAC = PairKey(u: pair.left, v: c)
                let keyBC = PairKey(u: pair.right, v: c)
                let dAC = dist[keyAC] ?? getDistance(pair.left, c)
                let dBC = dist[keyBC] ?? getDistance(pair.right, c)
                let dAB = minDist
                
                let T = sizeA + sizeB + sizeC
                let newDistSquared = ((sizeC + sizeA) / T) * dAC * dAC + ((sizeC + sizeB) / T) * dBC * dBC - (sizeC / T) * dAB * dAB
                let newDist = sqrt(max(0, newDistSquared))
                dist[PairKey(u: newId, v: c)] = newDist
            }

            // Atualiza pares adjacentes afetados
            if p - 1 >= 0 {
                let leftNeighbor = clusters[p - 1]
                let rightNeighbor = newId
                let v = max(aliveVersion[leftNeighbor], aliveVersion[rightNeighbor])
                let key = PairKey(u: leftNeighbor, v: rightNeighbor)
                let d = dist[key] ?? getDistance(leftNeighbor, rightNeighbor)
                heap.insert(AdjPair(left: leftNeighbor, right: rightNeighbor, dist: d, version: v))
            }
            if p + 1 < clusters.count {
                let leftNeighbor = newId
                let rightNeighbor = clusters[p + 1]
                let v = max(aliveVersion[leftNeighbor], aliveVersion[rightNeighbor])
                let key = PairKey(u: leftNeighbor, v: rightNeighbor)
                let d = dist[key] ?? getDistance(leftNeighbor, rightNeighbor)
                heap.insert(AdjPair(left: leftNeighbor, right: rightNeighbor, dist: d, version: v))
            }

            performed += 1
        }

        // Retorna apenas as linhas preenchidas (performed merges)
        if performed < z.count {
            return Array(z.prefix(performed))
        }
        return z
    }
    
    /// Downsampling temporal simples por média em janelas fixas.
    /// - Parameters:
    ///   - buffer: Buffer flat de Float (row-major) contendo os dados (N x F).
    ///   - rows: Número de linhas (amostras).
    ///   - cols: Número de colunas (features).
    ///   - window: Tamanho da janela (>= 1).
    /// - Returns: Buffer flat de Float com sinais reduzidos por média de janela e o novo número de linhas.
    func downsampleMean(buffer: [Float], rows: Int, cols: Int, window: Int) -> (buffer: [Float], rows: Int) {
        guard rows > 0, cols > 0, window > 1 else { return (buffer, rows) }
        
        var result: [Float] = []
        result.reserveCapacity((rows / window + 1) * cols)
        var newRows = 0
        var i = 0
        
        while i < rows {
            let end = min(rows, i + window)
            var acc = Array(repeating: Float(0.0), count: cols)
            let windowSize = end - i
            
            for r in i..<end {
                for c in 0..<cols {
                    acc[c] += buffer[r * cols + c]
                }
            }
            
            let divisor = Float(windowSize)
            for c in 0..<cols {
                result.append(acc[c] / divisor)
            }
            newRows += 1
            i = end
        }
        
        return (result, newRows)
    }
    
    /// Versão de downsample que aceita [[Float]] e retorna [[Float]]
    func downsampleMean(_ matrix: [[Float]], window: Int) -> [[Float]] {
        guard !matrix.isEmpty, window > 1 else { return matrix }
        let cols = matrix[0].count
        let flatBuffer = flattenFloat2D(matrix)
        let (reducedBuffer, newRows) = downsampleMean(buffer: flatBuffer, rows: matrix.count, cols: cols, window: window)
        
        // Convert back to 2D
        var result: [[Float]] = []
        result.reserveCapacity(newRows)
        for r in 0..<newRows {
            var row: [Float] = []
            row.reserveCapacity(cols)
            for c in 0..<cols {
                row.append(reducedBuffer[r * cols + c])
            }
            result.append(row)
        }
        return result
    }
    
    /// Gera rótulos planos a partir de uma matriz de ligação parcial (Z parcial) resultante de parada antecipada.
    /// - Parameters:
    ///   - Z: Matriz de ligação parcial (cada linha: [esquerda, direita, distância, tamanho]). Deve conter as fusões realizadas, em ordem.
    ///   - n: Número de folhas (pontos originais) na base dos dados.
    /// - Returns: Vetor de rótulos (1..k) para cada ponto original, onde k = n - Z.count.
    func fclusterFromPartialZ(Z: [[Float]], n: Int) -> [Int] {
        // n = número de folhas (pontos originais)
        guard n > 0 else { return [] }
        if Z.isEmpty { return Array(repeating: 1, count: n) }

        // Inicialmente, cada ponto é seu próprio cluster (id = índice da folha)
        var labels = Array(0..<n)
        var nextClusterId = n // ids de clusters mesclados começam após as folhas

        // Aplica cada fusão na ordem em que ocorreu
        for row in Z {
            if row.count < 2 { continue }
            let left = Int(row[0])
            let right = Int(row[1])

            // Todos os pontos cujo rótulo atual é left ou right passam a ter o novo id
            for j in 0..<labels.count {
                if labels[j] == left || labels[j] == right {
                    labels[j] = nextClusterId
                }
            }
            nextClusterId += 1
        }

        // Compacta os ids para faixa 1..k (ordem estável por ordenação crescente dos ids únicos)
        let uniqueSorted = Array(Set(labels)).sorted()
        var mapping: [Int: Int] = [:]
        for (newId, oldId) in uniqueSorted.enumerated() {
            mapping[oldId] = newId + 1
        }
        return labels.map { mapping[$0] ?? 0 }
    }

}
