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
    
    func lerp(_ v0: Double, _ v1: Double, alpha: Double) -> Double {
        return v0 + (v1 - v0) * alpha
    }
    
    func interpolateLinear(t: TimeInterval, p0: Sample, p1: Sample) -> Sample {
        let dt = p1.t - p0.t
        let alpha = dt > 0 ? (t - p0.t) / dt : 0.0
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
    
    /// Calcula a distância euclidiana entre dois vetores.
    /// - Parameters:
    ///   - a: Vetor de valores em Double.
    ///   - b: Vetor de valores em Double.
    /// - Returns: Distância euclidiana entre `a` e `b`. Se os vetores tiverem tamanhos diferentes, retorna `nil`.
    func euclideanDist(a: [Double], b: [Double]) -> Double? {
        guard a.count == b.count else { return nil }
        var sum: Double = 0
        for i in 0..<a.count {
            let d = a[i] - b[i]
            sum += d * d
        }
        return sqrt(sum)
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
    
    struct PairKey: Hashable {
        let u: Int
        let v: Int
        init(u: Int, v: Int) {
            if u <= v { self.u = u; self.v = v } else { self.u = v; self.v = u }
        }
    }

    final class LRUCache<Key: Hashable, Value> {
        private final class Node {
            let key: Key
            var value: Value
            var prev: Node?
            var next: Node?
            init(key: Key, value: Value) { self.key = key; self.value = value }
        }

        private var dict: [Key: Node] = [:]
        private var head: Node?
        private var tail: Node?
        private let capacity: Int

        init(capacity: Int = 256) { self.capacity = max(1, capacity) }

        func get(_ key: Key) -> Value? {
            guard let node = dict[key] else { return nil }
            moveToHead(node)
            return node.value
        }

        func set(_ value: Value, for key: Key) {
            if let node = dict[key] {
                node.value = value
                moveToHead(node)
                return
            }
            let node = Node(key: key, value: value)
            dict[key] = node
            addToHead(node)
            if dict.count > capacity { removeTailIfNeeded() }
        }

        private func addToHead(_ node: Node) {
            node.prev = nil
            node.next = head
            head?.prev = node
            head = node
            if tail == nil { tail = node }
        }

        private func moveToHead(_ node: Node) {
            guard head !== node else { return }
            // detach
            node.prev?.next = node.next
            node.next?.prev = node.prev
            if tail === node { tail = node.prev }
            // move to head
            node.prev = nil
            node.next = head
            head?.prev = node
            head = node
        }

        private func removeTailIfNeeded() {
            guard let t = tail else { return }
            dict[t.key] = nil
            if let prev = t.prev {
                prev.next = nil
                tail = prev
            } else {
                head = nil
                tail = nil
            }
        }
    }
    
    /// Calcula a distância entre um cluster u e um cluster v usando o método Ward, com programação dinâmica.
    /// - Parameters:
    ///   - u: ID do cluster u.
    ///   - v: ID do cluster v.
    ///   - z: Matriz de ligação (cada linha: [filhoEsq, filhoDir, ..., tamanhoCluster]).
    ///   - data: Dados originais (folhas), cada elemento é um vetor de Double.
    ///   - cache: Cache LRU para distâncias já computadas.
    /// - Returns: Distância entre os clusters u e v, ou nil se índices inválidos.
    func distSub(u: Int, v: Int, z: [[Double]], data: [[Double]], cache: inout LRUCache<PairKey, Double>) -> Double? {
        // Normaliza para u <= v
        let u0 = min(u, v)
        let v0 = max(u, v)
        let key = PairKey(u: u0, v: v0)
        let numFolhas = data.count

        // Se já foi computado, retorna do cache
        if let cached = cache.get(key) {
            return cached
        }

        // Caso ambos sejam folhas
        if u0 < numFolhas && v0 < numFolhas {
            if let d = euclideanDist(a: data[u0], b: data[v0]) {
                cache.set(d, for: key)
                return d
            } else {
                return nil
            }
        }

        // Função auxiliar para obter tamanho do cluster
        func clusterSize(_ id: Int) -> Double {
            if id < numFolhas { return 1.0 }
            let row = id - numFolhas
            if row >= 0 && row < z.count && z[row].count > 3 {
                return z[row][3]
            }
            return 1.0
        }

        // Função auxiliar para obter filhos (s, t) de um cluster não-folha
        func children(of id: Int) -> (Int, Int)? {
            guard id >= numFolhas else { return nil }
            let row = id - numFolhas
            guard row >= 0 && row < z.count, z[row].count >= 2 else { return nil }
            let s = Int(z[row][0])
            let t = Int(z[row][1])
            return (s, t)
        }

        // Se v é não-folha
        if v0 >= numFolhas, let (s, t) = children(of: v0) {
            let id_v = u0
            let id_s = s
            let id_t = t

            let size_v = clusterSize(id_v)
            let size_s = clusterSize(id_s)
            let size_t = clusterSize(id_t)
            let T = size_v + size_s + size_t

            guard let d_vs = distSub(u: id_v, v: id_s, z: z, data: data, cache: &cache),
                  let d_vt = distSub(u: id_v, v: id_t, z: z, data: data, cache: &cache),
                  let d_st = distSub(u: id_s, v: id_t, z: z, data: data, cache: &cache) else {
                return nil
            }

            var temp = ((size_v + size_s) / T) * (d_vs * d_vs)
            temp += ((size_v + size_t) / T) * (d_vt * d_vt)
            temp -= (size_v / T) * (d_st * d_st)
            if abs(temp) < 1e-6 { temp = 0 }
            let dist = sqrt(max(0, temp))
            cache.set(dist, for: key)
            return dist
        }
        // Caso contrário, u é não-folha
        else if u0 >= numFolhas, let (s, t) = children(of: u0) {
            let id_v = v0
            let id_s = s
            let id_t = t

            let size_v = clusterSize(id_v)
            let size_s = clusterSize(id_s)
            let size_t = clusterSize(id_t)
            let T = size_v + size_s + size_t

            guard let d_vs = distSub(u: id_v, v: id_s, z: z, data: data, cache: &cache),
                  let d_vt = distSub(u: id_v, v: id_t, z: z, data: data, cache: &cache),
                  let d_st = distSub(u: id_s, v: id_t, z: z, data: data, cache: &cache) else {
                return nil
            }

            var temp = ((size_v + size_s) / T) * (d_vs * d_vs)
            temp += ((size_v + size_t) / T) * (d_vt * d_vt)
            temp -= (size_v / T) * (d_st * d_st)
            if abs(temp) < 1e-6 { temp = 0 }
            let dist = sqrt(max(0, temp))
            cache.set(dist, for: key)
            return dist
        }

        // Se chegou aqui, algo está inconsistente
        return nil
    }
    
    /// Retorna o número de elementos em um cluster.
    /// - Parameters:
    ///   - id: ID do cluster.
    ///   - z: Matriz de ligação atual (cada linha contém pelo menos 4 colunas; a quarta coluna é o tamanho do cluster).
    ///   - numFolhas: Número total de folhas (pontos) na base.
    /// - Returns: Número de elementos no cluster.
    func getNumElements(id: Int, z: [[Double]], numFolhas: Int) -> Int {
        if id < numFolhas { return 1 }
        let row = id - numFolhas
        guard row >= 0, row < z.count, z[row].count > 3 else { return 1 }
        // z[row][3] armazena o tamanho do cluster; converte para Int com truncamento.
        return Int(z[row][3])
    }
    
    /// Implementa o agrupamento hierárquico considerando apenas pares adjacentes (método de Ward com distância euclidiana).
    /// - Parameter data: Dados de entrada no formato [[Double]] (n amostras x m atributos).
    /// - Returns: Matriz de ligação no formato (n - 1) x 4: [filhoEsq, filhoDir, distancia, tamanhoCluster].
    func linkageAdjacentWard(data: [[Double]]) -> [[Double]] {
        let nSamples = data.count
        guard nSamples >= 2 else { return [] }

        // Matriz de ligação Z (nSamples - 1) x 4
        var z = Array(repeating: Array(repeating: 0.0, count: 4), count: nSamples - 1)

        // Clusters iniciais: 0..nSamples-1
        var clusters = Array(0..<nSamples)

        // Cache LRU para distâncias
        var cache = LRUCache<PairKey, Double>(capacity: 512)

        // Loop principal
        for i in 0..<(nSamples - 1) {
            // Distâncias entre pares adjacentes atuais
            let pairsCount = clusters.count - 1
            var dists = Array(repeating: 0.0, count: max(0, pairsCount))
            if pairsCount > 0 {
                for j in 0..<pairsCount {
                    if let d = distSub(u: clusters[j], v: clusters[j + 1], z: z, data: data, cache: &cache) {
                        dists[j] = d
                    } else {
                        dists[j] = Double.greatestFiniteMagnitude
                    }
                }
            }

            // Encontra o índice do menor valor em dists
            var idx = 0
            if !dists.isEmpty {
                var minVal = dists[0]
                for k in 1..<dists.count {
                    if dists[k] < minVal { minVal = dists[k]; idx = k }
                }
                let minDist = dists[idx]

                // Número de elementos resultantes da união
                let numElem = Double(getNumElements(id: clusters[idx], z: z, numFolhas: nSamples) +
                                     getNumElements(id: clusters[idx + 1], z: z, numFolhas: nSamples))

                // Atualiza a matriz de ligação: [filhoEsq, filhoDir, distancia, tamanho]
                z[i][0] = Double(clusters[idx])
                z[i][1] = Double(clusters[idx + 1])
                z[i][2] = minDist
                z[i][3] = numElem

                // Atualiza os clusters: remove os dois e insere o novo id (nSamples + i)
                clusters.remove(at: idx)
                clusters.remove(at: idx) // remove o que ficou na posição idx após a 1ª remoção
                clusters.insert(nSamples + i, at: idx)
            }
        }

        return z
    }
    
    /// Implementação customizada de fcluster: gera rótulos planos a partir da matriz de ligação.
    /// - Parameters:
    ///   - Z: Matriz de ligação (cada linha: [esquerda, direita, distância, contagem]).
    ///   - t: Limiar usado para decidir até qual fusão processar.
    /// - Returns: Vetor de rótulos (1..k) para cada ponto original.
    func fclusterCustom(Z: [[Double]], t: Double) -> [Int] {
        // n = Z.shape[0] + 1
        let n = Z.count + 1
        if n == 0 { return [] }

        // Inicializa os rótulos: cada ponto começa em seu próprio cluster
        var labels = Array(0..<n)
        var clusterId = n

        // Processa cada fusão até o limite (n - t)
        // No Python, range(n - t) com t float é ambíguo; aqui usamos floor de (n - t)
        let limit = max(0, Int(floor(Double(n) - t)))
        if limit > 0 {
            for i in 0..<min(limit, Z.count) {
                let row = Z[i]
                if row.count < 2 { continue }
                let left = Int(row[0])
                let right = Int(row[1])

                for j in 0..<labels.count {
                    if labels[j] == left || labels[j] == right {
                        labels[j] = clusterId
                    }
                }
                clusterId += 1
            }
        }

        // Renumera rótulos para serem consecutivos a partir de 1
        let uniqueSorted = Array(Set(labels)).sorted()
        var mapping: [Int: Int] = [:]
        for (newId, oldId) in uniqueSorted.enumerated() {
            mapping[oldId] = newId + 1
        }
        let finalLabels = labels.map { mapping[$0] ?? 0 }
        return finalLabels
    }
    
    // Converter MLShapedArray<Float> 1xNxF em [[Double]]
    func shapedArrayTo2D(_ arr: MLShapedArray<Float>) -> [[Double]] {
        precondition(arr.shape.count == 3 && arr.shape[0] == 1, "Esperado shape [1, N, F]")
        let n = arr.shape[1]
        let f = arr.shape[2]
        var result = Array(repeating: Array(repeating: 0.0, count: f), count: n)
        for i in 0..<n {
            for j in 0..<f {
                // arr[0, i, j] -> MLShapedArray.Scalar? (Float?), convertemos para Double
                if let v = arr[0, i, j].scalar {
                    result[i][j] = Double(v)
                } else {
                    result[i][j] = 0.0
                }
            }
        }
        return result
    }
    
    // Converte [[Double]] para Data (apenas bytes, sem metadados)
    func double2DToDataRaw(_ matrix: [[Double]]) -> Data {
        // Flatten row-major
        let flat = matrix.flatMap { $0 }
        return flat.withUnsafeBufferPointer { Data(buffer: $0) }
    }
    
    // Reconstrói [[Double]] a partir de Data e metadados (rows/cols)
    func dataToDouble2DRaw(_ data: Data, rows: Int, cols: Int) -> [[Double]] {
        precondition(rows >= 0 && cols >= 0, "Dimensões inválidas")
        let count = rows * cols
        let array: [Double] = data.withUnsafeBytes {
            Array(UnsafeBufferPointer<Double>(
                start: $0.baseAddress!.assumingMemoryBound(to: Double.self),
                count: count
            ))
        }
        var result: [[Double]] = []
        result.reserveCapacity(rows)
        for r in 0..<rows {
            let start = r * cols
            let end = start + cols
            result.append(Array(array[start..<end]))
        }
        return result
    }
}

