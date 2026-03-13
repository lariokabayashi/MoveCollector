//
//  SensorManager.swift
//  MotionApp
//
//  Created by Larissa Okabayashi on 07/10/25.
//

import SwiftUI
import CoreMotion
import UniformTypeIdentifiers
import CoreData
import CoreLocation
import CoreML

@available(iOS 26.0, *)
final class SensorManagerViewModel: NSObject, ObservableObject {
    private let motionManager = CMMotionManager()
    private let context: NSManagedObjectContext
    private let queue = OperationQueue()
    weak var appDelegate: AppDelegate?
    private let appConstants = AppConstants()
    private var collectionTimer: DispatchSourceTimer?
    private var saveCounter = 0
    
    // MARK: - ML Model (ConvNet)
    private var cnn_pff_2D: CNN_PFF_2D?
    private var mlBufferTimed: [Sample6] = []     // sliding window buffer with timestamps
    private let windowSize = 60                // 3 sec @ 20 Hz
    
    private func lerp(_ v0: Double, _ v1: Double, alpha: Double) -> Double {
        return v0 + (v1 - v0) * alpha
    }
    
    private func interpolateLinear(t: TimeInterval, p0: Sample6, p1: Sample6) -> Sample6 {
        let dt = p1.t - p0.t
        let alpha = dt > 0 ? (t - p0.t) / dt : 0.0
        return Sample6(
            t: t,
            ax: lerp(p0.ax, p1.ax, alpha: alpha),
            ay: lerp(p0.ay, p1.ay, alpha: alpha),
            az: lerp(p0.az, p1.az, alpha: alpha),
            gx: lerp(p0.gx, p1.gx, alpha: alpha),
            gy: lerp(p0.gy, p1.gy, alpha: alpha),
            gz: lerp(p0.gz, p1.gz, alpha: alpha)
        )
    }
    
    private func resampleToFixedRate(samples: [Sample6], startTime: TimeInterval, count: Int, rateHz: Double) -> [Sample6] {
        guard samples.count >= 2 else { return samples }
        let dt = 1.0 / rateHz
        var result: [Sample6] = []
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
                    result.append(Sample6(t: targetT, ax: p0.ax, ay: p0.ay, az: p0.az, gx: p0.gx, gy: p0.gy, gz: p0.gz))
                } else if targetT <= p1.t {
                    result.append(interpolateLinear(t: targetT, p0: p0, p1: p1))
                } else {
                    result.append(Sample6(t: targetT, ax: p1.ax, ay: p1.ay, az: p1.az, gx: p1.gx, gy: p1.gy, gz: p1.gz))
                }
            } else if let last = samples.last {
                result.append(Sample6(t: targetT, ax: last.ax, ay: last.ay, az: last.az, gx: last.gx, gy: last.gy, gz: last.gz))
            }
        }
        return result
    }
    
    @Published var mlStatusMessage: String = ""
    @Published var mlIsReady: Bool = false
    
    @Published var predictedActivity: String = ""
    
    var CLASS_EMOJI = ["sit 🪑", "stand 🧍", "walk 🚶", "climb up 🪜⬆️", "climb down 🪜⬇️", "run 🏃"]
    
    init(context: NSManagedObjectContext) {
        self.context = context
        UIDevice.current.isBatteryMonitoringEnabled = true
        super.init()
        
        do {
            let model = try CNN_PFF_2D()
            self.cnn_pff_2D = model
            self.mlIsReady = true
            self.mlStatusMessage = "ML model loaded"
        } catch {
            self.mlIsReady = false
            self.mlStatusMessage = "Failed to load ML model: \(error.localizedDescription)"
            print("[ML] Model load error:", error)
        }
    }
    
    @Published var isRecording = false
    @Published var accelX = 0.0
    @Published var accelY = 0.0
    @Published var accelZ = 0.0
    
    @Published var gyroX = 0.0
    @Published var gyroY = 0.0
    @Published var gyroZ = 0.0
    
    @Published var batteryLevel: Float = UIDevice.current.batteryLevel
    
    func startCollection() {
        
        motionManager.deviceMotionUpdateInterval = appConstants.updateInterval
        motionManager.accelerometerUpdateInterval = appConstants.updateInterval
        motionManager.gyroUpdateInterval = appConstants.updateInterval
        
        context.reset()
        
        motionManager.startAccelerometerUpdates()
        motionManager.startGyroUpdates()
        motionManager.startDeviceMotionUpdates()
        
        startBackgroundTimer()
    }
    
    private func startBackgroundTimer() {
        collectionTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .background))
        collectionTimer?.schedule(deadline: .now(), repeating: appConstants.updateInterval)
        collectionTimer?.setEventHandler { [weak self] in
            self?.collectData()
        }
        collectionTimer?.resume()
    }
    
    func stopCollection() {
        collectionTimer?.cancel()
        collectionTimer = nil
        
        motionManager.stopAccelerometerUpdates()
        motionManager.stopGyroUpdates()
        motionManager.stopDeviceMotionUpdates()
    }
    
    func requestStopBackgroundCollection() {
        appDelegate?.stopBackgroundCollection()
    }
    
    func submitBackgroundCollection() {
        appDelegate?.submitBackgroundCollection()
    }
    
    private func argmax(_ arr: MLShapedArray<Float>) -> Int {
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
    
    private func runHARPrediction() {
        guard mlIsReady, let model = cnn_pff_2D else {
            DispatchQueue.main.async { self.mlStatusMessage = "ML model not ready" }
            return
        }
        guard let input = prepareMLMultiArray() else {
            DispatchQueue.main.async { self.mlStatusMessage = "Failed to prepare ML input" }
            return
        }

        do {
            let output = try model.prediction(x_1: input)
            let probs = output.var_134ShapedArray
            let predictedIndex = argmax(probs)
            DispatchQueue.main.async {
                self.predictedActivity = self.CLASS_EMOJI[predictedIndex]
                self.mlStatusMessage = "Prediction OK"
            }
        } catch {
            DispatchQueue.main.async {
                self.mlStatusMessage = "HAR Prediction Error: \(error.localizedDescription)"
            }
            print("HAR Prediction Error:", error)
        }
    }
    
    private func prepareMLMultiArray() -> MLMultiArray? {
        guard mlBufferTimed.count >= windowSize else { return nil }
        // derive rate from updateInterval
        let dt = appConstants.updateInterval
        guard dt > 0 else { return nil }
        let rateHz = 1.0 / dt

        // Build resampled window starting at the first timestamp
        guard let startT = mlBufferTimed.first?.t else { return nil }
        let resampled = resampleToFixedRate(samples: mlBufferTimed, startTime: startT, count: windowSize, rateHz: rateHz)

        let shape: [NSNumber] = [1, 6, NSNumber(value: windowSize)]
        guard let array = try? MLMultiArray(shape: shape, dataType: .float32) else { return nil }

        for (tIndex, s) in resampled.enumerated() {
            array[[0, 0, tIndex] as [NSNumber]] = NSNumber(value: Float32(s.ax))
            array[[0, 1, tIndex] as [NSNumber]] = NSNumber(value: Float32(s.ay))
            array[[0, 2, tIndex] as [NSNumber]] = NSNumber(value: Float32(s.az))
            array[[0, 3, tIndex] as [NSNumber]] = NSNumber(value: Float32(s.gx))
            array[[0, 4, tIndex] as [NSNumber]] = NSNumber(value: Float32(s.gy))
            array[[0, 5, tIndex] as [NSNumber]] = NSNumber(value: Float32(s.gz))
        }
        return array
    }
    
    private func appendToMLBuffer(ax: Double, ay: Double, az: Double,
                                  gx: Double, gy: Double, gz: Double) {
        let t = Date().timeIntervalSince1970
        mlBufferTimed.append(Sample6(t: t, ax: ax, ay: ay, az: az, gx: gx, gy: gy, gz: gz))

        if mlBufferTimed.count > windowSize { mlBufferTimed.removeFirst() }

        if mlBufferTimed.count == windowSize {
            runHARPrediction()
        }
    }
    
    private func collectData() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let timestamp = formatter.string(from: Date())
        if let accel = motionManager.deviceMotion?.userAcceleration, // shows the acceleration without the gravity force
           let gyro  = motionManager.gyroData {
            
            DispatchQueue.main.async {
                self.accelX = accel.x * 10
                self.accelY = accel.y * 10
                self.accelZ = accel.z * 10
                self.gyroX = gyro.rotationRate.x
                self.gyroY = gyro.rotationRate.y
                self.gyroZ = gyro.rotationRate.z
                self.batteryLevel = UIDevice.current.batteryLevel
                
                // ---- ML HAR Pipeline ----------------------------
                self.appendToMLBuffer(
                    ax: self.accelX,
                    ay: self.accelY,
                    az: self.accelZ,
                    gx: self.gyroX,
                    gy: self.gyroY,
                    gz: self.gyroZ
                )
            }
        }

        saveReading(timestamp: timestamp, ax: accelX, ay: accelY, az: accelZ, gx: gyroX, gy: gyroY, gz: gyroZ, battery: Double(batteryLevel))

    }
    
    private func saveReading(timestamp: String, ax: Double, ay: Double, az: Double, gx: Double, gy: Double, gz: Double, battery: Double) {
        context.perform {
            let reading = SensorReading(context: self.context)
            reading.id = UUID()
            reading.timestamp = timestamp
            reading.ax = ax
            reading.ay = ay
            reading.az = az
            reading.gx = gx
            reading.gy = gy
            reading.gz = gz
            reading.battery = battery
            
            self.saveCounter += 1
            if self.saveCounter >= self.appConstants.saveThreshold {
                do {
                    try self.context.save()
                    self.saveCounter = 0
                } catch {
                    print("Core Data save error: \(error.localizedDescription)")
                }
            }
            
            print("[DEBUG] Timestamp: \(timestamp), State: \(UIApplication.shared.applicationState.rawValue), Battery: \(UIDevice.current.batteryLevel)")
        }
    }
    
    private func fetchSensorData(context: NSManagedObjectContext, batchSize: Int = 1000) -> [SensorReading] {
        let fetchRequest: NSFetchRequest<SensorReading> = SensorReading.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
        fetchRequest.fetchBatchSize = batchSize
        
        do {
            let results = try context.fetch(fetchRequest)
            print("Fetched \(results.count) sensor data entries")
            return results
        } catch {
            print("Failed to fetch sensor data: \(error.localizedDescription)")
            return []
        }
    }
    
    private func deleteRequests(for context: NSManagedObjectContext){
        let fetchRequest: NSFetchRequest<NSFetchRequestResult> = SensorReading.fetchRequest()
        let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
        
        do {
            try context.execute(deleteRequest) // cleaning every remaining data
            context.reset()
        } catch {
            print("Failed to delete sensor data: \(error.localizedDescription)")
        }
    }
    
    func exportToCSV() -> URL? {
        let sensorData = fetchSensorData(context: context, batchSize: 1000)
        guard !sensorData.isEmpty else {
            print("No data to export")
            return nil
        }
        
        let fileName = "sensor_data_\(Date().timeIntervalSince1970).csv"

        let documentDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileURL = documentDirectory.appendingPathComponent(fileName)
        
        var csvText = "timestamp,ax,ay,az,gx,gy,gz,battery\n"

        for reading in sensorData {
            let timestamp = reading.timestamp ?? ""
            let line = "\(timestamp),\(reading.ax),\(reading.ay),\(reading.az)," +
                       "\(reading.gx),\(reading.gy),\(reading.gz),\(reading.battery)\n"
            csvText.append(line)
        }
        
        deleteRequests(for: context)
        
        do {
            try csvText.write(to: fileURL, atomically: true, encoding: .utf8)
            notify("CSV file saved to: \(fileURL)")
            return fileURL
        } catch {
            notify("Failed to write CSV file: \(error)")
            return nil
        }
    }
}

