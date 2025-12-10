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
    private let convNet = try! ConvNet_DynamicBatch()
    private var mlBuffer: [[Double]] = []      // sliding window buffer
    private let windowSize = 60                // 3 sec @ 20 Hz
    
    @Published var predictedActivity: String = ""
    
    var CLASS_EMOJI = ["sit 🪑", "stand 🧍", "walk 🚶", "climb up 🪜⬆️", "climb down 🪜⬇️", "run 🏃"]
    
    init(context: NSManagedObjectContext) {
        self.context = context
        UIDevice.current.isBatteryMonitoringEnabled = true
        super.init()
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
        guard let input = prepareMLMultiArray() else { return }
        print(input)

        do {
            let output = try convNet.prediction(input: input)
            let probs = output.var_53ShapedArray
            let predictedIndex = argmax(probs)
            
            DispatchQueue.main.async {
                self.predictedActivity = self.CLASS_EMOJI[predictedIndex]
            }
            
        } catch {
            print("HAR Prediction Error:", error)
        }
    }
    
    private func prepareMLMultiArray() -> MLMultiArray? {
        let shape: [NSNumber] = [1, 6, 60]
        guard let array = try? MLMultiArray(shape: shape, dataType: .float32) else { return nil }
        
        for t in 0..<windowSize {
            let sample = mlBuffer[t]   // [ax, ay, az, gx, gy, gz]
            
            for (index, element) in sample.enumerated() {
                array[[0, index, t] as [NSNumber]] = NSNumber(value: element)
                print("array value at \(index):\(NSNumber(value: element))")
            }
//            for c in 0..<6 {
//                let value = Float(sample[c])
//                array[[0, c, t] as [NSNumber]] = value as NSNumber
//                print("array value at \(c):\(array[c])")
//            }
        }
        return array
    }
    
    private func appendToMLBuffer(ax: Double, ay: Double, az: Double,
                                  gx: Double, gy: Double, gz: Double) {
        
        let sample = [ax, ay, az, gx, gy, gz]
        mlBuffer.append(sample)
        
        if mlBuffer.count > windowSize {
            mlBuffer.removeFirst()
        }
        
        if mlBuffer.count == windowSize {
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
