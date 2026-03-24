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
    private let utils = Utils()
    
    // MARK: - ML Model
    private var cnn_pff_2D: CNN_PFF_2D?
    private var cnn_pff_2D_backbone: CNN_PFF_2D_backbone?
    private var mlBufferTimed: [Sample] = []     // sliding window buffer with timestamps
    private let windowSize = 60                // 3 sec @ 20 Hz
    
    @Published var mlStatusMessage: String = ""
    @Published var mlIsReady: Bool = false
    
    @Published var predictedActivity: String = ""
    
    @Published var features: MLShapedArray<Float> = []
    
    @Published var linkageMatrix: [[Double]] = []
    @Published var clusterLabels: [Int] = []
    
    // MARK: - Chart Data (original vs resampled)
    @Published var chartOriginalAX: [Sample] = []
    @Published var chartResampledAX: [Sample] = []
    
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
            let predictedIndex = utils.argmax(probs)
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
    
    private func run_CNN_PFF_2D_backbone() {
        guard mlIsReady, let model = cnn_pff_2D_backbone else {
            DispatchQueue.main.async { self.mlStatusMessage = "ML model not ready" }
            return
        }
        guard let input = prepareMLMultiArray() else {
            DispatchQueue.main.async { self.mlStatusMessage = "Failed to prepare ML input" }
            return
        }
        do {
            let output = try model.prediction(x_1: input)
            DispatchQueue.main.async {
                self.features = output.var_200ShapedArray
                self.mlStatusMessage = "Prediction OK"
            }
        } catch {
            DispatchQueue.main.async {
                self.mlStatusMessage = "CNN_PFF_2D_backbone Prediction Error: \(error.localizedDescription)"
            }
            print("CNN_PFF_2D_backbone Prediction Error:", error)
        }
    }
    
    func runAdjacentWardClustering() {
        let data2D = utils.shapedArrayTo2D(self.features)
        let Z = utils.linkageAdjacentWard(data: data2D)
        // t precisa ser inteiro, t é o número de clusters/episódios finais
        let labels = utils.fclusterCustom(Z: Z, t: 5.0)
        self.linkageMatrix = Z
        self.clusterLabels = labels
    }
    
    private func prepareMLMultiArray() -> MLMultiArray? {
        guard mlBufferTimed.count >= windowSize else { return nil }
        // derive rate from updateInterval
        let dt = appConstants.updateInterval
        guard dt > 0 else { return nil }
        let rateHz = 1.0 / dt

        // Build resampled window starting at the first timestamp
        guard let startT = mlBufferTimed.first?.t else { return nil }
        let resampled = utils.resampleToFixedRate(samples: mlBufferTimed, startTime: startT, count: windowSize, rateHz: rateHz)

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
    
    func appendToMLBuffer(timestamp: TimeInterval, ax: Double, ay: Double, az: Double,
                                  gx: Double, gy: Double, gz: Double) {
        mlBufferTimed.append(Sample(t: timestamp, ax: ax, ay: ay, az: az, gx: gx, gy: gy, gz: gz))

        if mlBufferTimed.count > windowSize { mlBufferTimed.removeFirst() }
        
        // Keep original samples for charting (limit to windowSize)
        chartOriginalAX = mlBufferTimed

        if mlBufferTimed.count == windowSize {
            // Build resampled sequence for charting using same rate/window
            let dt = appConstants.updateInterval
            if dt > 0, let startT = mlBufferTimed.first?.t {
                let rateHz = 1.0 / dt
                let resampled = utils.resampleToFixedRate(samples: mlBufferTimed, startTime: startT, count: windowSize, rateHz: rateHz)
//                chartResampledAX = resampled
                DispatchQueue.main.async {
                    self.chartResampledAX = resampled
                }
            }
            runHARPrediction()
        }
    }
    
    private func collectData() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let now = Date()
        let timestamp = formatter.string(from: now)
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
                
                let now = Date()
                let tEpoch = now.timeIntervalSince1970
                self.appendToMLBuffer(
                    timestamp: tEpoch,
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
//                    DispatchQueue.main.async {
//                        self.refreshChartFromStore()
//                    }
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

