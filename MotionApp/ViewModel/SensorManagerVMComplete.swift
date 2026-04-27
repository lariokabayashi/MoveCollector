//
//  SensorManagerVMCompletel.swift
//  MotionApp
//
//  Created by Larissa Okabayashi on 25/03/26.
//

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
final class SensorManagerVMComplete: NSObject, ObservableObject {
    private let motionManager = CMMotionManager()
    private let context: NSManagedObjectContext
    private let queue = OperationQueue()
    weak var appDelegate: AppDelegate?
    private let appConstants = AppConstants()
    private var collectionTimer: DispatchSourceTimer?
    private var saveCounter = 0
    private let utils = Utils()
    private let constants = AppConstants()
    
    private let lastProcessKey = "lastProcessDate"
    
    // MARK: - ML Model
    private var cnn_pff_2D: CNN_PFF_2D?
    private var cnn_pff_2D_backbone: CNN_PFF_2D_backbone?
    private var mlBufferTimed: [Sample] = []     // sliding window buffer with timestamps
    
    private var features: MLShapedArray<Float> = []
    
    @Published var mlStatusMessage: String = ""
    @Published var mlIsReady: Bool = false
    
    @Published var predictedActivity: String = ""
    
    @Published var data2D: [[Double]] = []
    
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
        
        NotificationCenter.default.addObserver(
            forName: UIDevice.batteryStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleBatteryStateChange()
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
            let features = output.var_200ShapedArray
            DispatchQueue.main.async {
                self.data2D = self.utils.shapedArrayTo2D(features)
                self.mlStatusMessage = "Prediction OK"
            }
        } catch {
            DispatchQueue.main.async {
                self.mlStatusMessage = "CNN_PFF_2D_backbone Prediction Error: \(error.localizedDescription)"
            }
            print("CNN_PFF_2D_backbone Prediction Error:", error)
        }
    }
    
    private func prepareMLMultiArray() -> MLMultiArray? {
        guard mlBufferTimed.count >= constants.windowSize else { return nil }
        // derive rate from updateInterval
        let dt = appConstants.updateInterval
        guard dt > 0 else { return nil }
        let rateHz = 1.0 / dt

        // Build resampled window starting at the first timestamp
        guard let startT = mlBufferTimed.first?.t else { return nil }
        let resampled = utils.resampleToFixedRate(samples: mlBufferTimed, startTime: startT, count: constants.windowSize, rateHz: rateHz)

        let shape: [NSNumber] = [1, 6, NSNumber(value: constants.windowSize)]
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

        if mlBufferTimed.count > constants.windowSize { mlBufferTimed.removeFirst() }
        
        // Keep original samples for charting (limit to windowSize)
        chartOriginalAX = mlBufferTimed

        if mlBufferTimed.count == constants.windowSize {
            // Build resampled sequence for charting using same rate/window
            let dt = appConstants.updateInterval
            if dt > 0, let startT = mlBufferTimed.first?.t {
                let rateHz = 1.0 / dt
                let resampled = utils.resampleToFixedRate(samples: mlBufferTimed, startTime: startT, count: constants.windowSize, rateHz: rateHz)
                chartResampledAX = resampled
                DispatchQueue.main.async {
                    self.chartResampledAX = resampled
                }
            }
            runHARPrediction()
            run_CNN_PFF_2D_backbone()
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
        
        saveFeatures(timestamp: timestamp, data2D: data2D)

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
    
    private func saveFeatures(timestamp: String, data2D: [[Double]]) {
        context.perform {
            let featureMatrix = FeatureMatrix(context: self.context)
            featureMatrix.id = UUID()
            featureMatrix.timestamp = timestamp
            featureMatrix.rows = Int16(data2D.count)
            featureMatrix.cols = Int16(data2D.first?.count ?? 0)
            featureMatrix.payload = self.utils.double2DToDataRaw(data2D)
            
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
    
    // Funções só para Export to CSV
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
    
    // MARK: - Battery / Daily Processing
    private func handleBatteryStateChange() {
        let state = UIDevice.current.batteryState
        if state == .charging || state == .full {
            processDailyClusteringIfNeeded()
        }
    }

    func processDailyClusteringIfNeeded() {
        DispatchQueue.global(qos: .utility).async {
            let matrices = self.fetchFeaturesForToday()
            guard !matrices.isEmpty else { return }
            let aggregated = self.aggregateFeatureMatrices(matrices)
            guard aggregated.count >= 2 else { return }
            let Z = self.utils.linkageAdjacentWard(data: aggregated)
            let labels = self.utils.fclusterCustom(Z: Z, t: 8.0) // ajuste t conforme desejado
            DispatchQueue.main.async {
                self.linkageMatrix = Z
                self.clusterLabels = labels
            }
        }
    }

    // Busca FeatureMatrix do dia corrente e reconstrói [[Double]]
    private func fetchFeaturesForToday() -> [[[Double]]] {
        let fetchRequest: NSFetchRequest<FeatureMatrix> = FeatureMatrix.fetchRequest()
        // Filtrar por dia corrente usando timestamp ISO8601 armazenado como String
        // Carrega todas e filtra em memória por simplicidade; para grandes volumes, use predicate adequado.
        do {
            let results = try context.fetch(fetchRequest)
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            iso.timeZone = TimeZone(secondsFromGMT: 0)
            let startOfDay = Calendar.current.startOfDay(for: Date())
            let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay)!

            var matrices: [[[Double]]] = []
            for fm in results {
                guard let ts = fm.timestamp,
                      let date = iso.date(from: ts) else { continue }
                if date >= startOfDay && date < endOfDay {
                    let rows = Int(fm.rows)
                    let cols = Int(fm.cols)
                    guard let payload = fm.payload else { continue }
                    let mat = self.utils.dataToDouble2DRaw(payload, rows: rows, cols: cols)
                    matrices.append(mat)
                }
            }
            return matrices
        } catch {
            print("Failed to fetch FeatureMatrix: \(error.localizedDescription)")
            return []
        }
    }

    // Concatena uma lista de [[Double]] em uma única [[Double]] (empilha por linhas)
    private func aggregateFeatureMatrices(_ matrices: [[[Double]]]) -> [[Double]] {
        var aggregated: [[Double]] = []
        for m in matrices {
            aggregated.append(contentsOf: m)
        }
        return aggregated
    }
}
