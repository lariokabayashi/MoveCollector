//
//  Sample6.swift
//  MotionApp
//
//  Created by Larissa Okabayashi on 13/03/26.
//

import Foundation

// MARK: - Resampling/Interpolation types & helpers
struct Sample: Equatable {
    let t: TimeInterval
    let ax: Float
    let ay: Float
    let az: Float
    let gx: Float
    let gy: Float
    let gz: Float
}

struct PairKey: Hashable {
    let u: Int
    let v: Int
    init(u: Int, v: Int) {
        if u <= v { self.u = u; self.v = v } else { self.u = v; self.v = u }
    }
}

struct AdjPair: Comparable {
    let left: Int
    let right: Int
    let dist: Float
    let version: Int
    static func < (lhs: AdjPair, rhs: AdjPair) -> Bool { lhs.dist < rhs.dist }
}

struct BinaryMinHeap<T: Comparable> {
    private var storage: [T] = []
    var isEmpty: Bool { storage.isEmpty }
    mutating func insert(_ value: T) {
        storage.append(value)
        siftUp(from: storage.count - 1)
    }
    mutating func popMin() -> T? {
        guard !storage.isEmpty else { return nil }
        if storage.count == 1 { return storage.removeLast() }
        let minVal = storage[0]
        storage[0] = storage.removeLast()
        siftDown(from: 0)
        return minVal
    }
    func peek() -> T? { storage.first }
    private mutating func siftUp(from index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            if storage[child] < storage[parent] {
                storage.swapAt(child, parent)
                child = parent
            } else { break }
        }
    }
    private mutating func siftDown(from index: Int) {
        var parent = index
        while true {
            let left = 2 * parent + 1
            let right = left + 1
            var candidate = parent
            if left < storage.count && storage[left] < storage[candidate] { candidate = left }
            if right < storage.count && storage[right] < storage[candidate] { candidate = right }
            if candidate == parent { return }
            storage.swapAt(parent, candidate)
            parent = candidate
        }
    }
}

// Estrutura para armazenar dados de localização
struct LocationData {
    let timestamps: TimeInterval  // Para sincronização com sensores
    let latitude: Float
    let longitude: Float
    let altitude: Float
    let horizontalAccuracy: Float
    let verticalAccuracy: Float
}

// MARK: - Combined Sensor + GPS Data

/// Estrutura que combina dados de sensores (20 Hz) e GPS (1 Hz)
/// Formato CSV: timestamp, acc_x, acc_y, acc_z, gyro_x, gyro_y, gyro_z, latitude, longitude, altitude, horizontal_accuracy, vertical_accuracy
struct CombinedSensorGPSData {
    let timestamp: Int              // Unix timestamp em milissegundos
    let accX: Float
    let accY: Float
    let accZ: Float
    let gyroX: Float
    let gyroY: Float
    let gyroZ: Float
    let latitude: Float?           // Repetido entre atualizações de GPS
    let longitude: Float?
    let altitude: Float?
    let horizontalAccuracy: Float?
    let verticalAccuracy: Float?
    
    /// Converte para linha CSV
    func toCSVLine() -> String {
        let lat = latitude.map { String($0) } ?? ""
        let lon = longitude.map { String($0) } ?? ""
        let alt = altitude.map { String($0) } ?? ""
        let hAcc = horizontalAccuracy.map { String($0) } ?? ""
        let vAcc = verticalAccuracy.map { String($0) } ?? ""
        
        return "\(timestamp),\(accX),\(accY),\(accZ),\(gyroX),\(gyroY),\(gyroZ),\(lat),\(lon),\(alt),\(hAcc),\(vAcc)"
    }
    
    /// Header do CSV
    static func csvHeader() -> String {
        return "timestamp,acc_x,acc_y,acc_z,gyro_x,gyro_y,gyro_z,latitude,longitude,altitude,horizontal_accuracy,vertical_accuracy"
    }
}

/// Cache thread-safe para último GPS conhecido (para repetir entre updates de sensores)
class GPSCache {
    private var lastGPS: GPSSnapshot?
    private let lock = NSLock()
    
    struct GPSSnapshot {
        let latitude: Float
        let longitude: Float
        let altitude: Float
        let horizontalAccuracy: Float
        let verticalAccuracy: Float
    }
    
    func update(latitude: Float, longitude: Float, altitude: Float,
                horizontalAccuracy: Float, verticalAccuracy: Float) {
        lock.lock()
        defer { lock.unlock() }
        lastGPS = GPSSnapshot(
            latitude: latitude,
            longitude: longitude,
            altitude: altitude,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: verticalAccuracy
        )
    }
    
    func getLatest() -> GPSSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return lastGPS
    }
    
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        lastGPS = nil
    }
}

