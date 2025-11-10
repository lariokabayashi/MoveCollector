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

@available(iOS 26.0, *)
final class SensorManagerViewModel: NSObject, ObservableObject {
    private let motionManager = CMMotionManager()
    private let context: NSManagedObjectContext
    private let queue = OperationQueue()
    weak var appDelegate: AppDelegate?
    private let appConstants = AppConstants()
    private var collectionTimer: DispatchSourceTimer?
    private var saveCounter = 0
    
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
    
    var dataBuffer: [String] = []
    
    func startCollection() {
        
        motionManager.deviceMotionUpdateInterval = appConstants.updateInterval
        motionManager.accelerometerUpdateInterval = appConstants.updateInterval
        motionManager.gyroUpdateInterval = appConstants.updateInterval
        
        context.reset()
        
        motionManager.startAccelerometerUpdates()
        motionManager.startGyroUpdates()
        motionManager.startDeviceMotionUpdates()
        
        startBackgroundTimer()
        
        dataBuffer = ["Source,When,X,Y,Z,UA_X,UA_Y,UA_Z,Pitch,Roll,Yaw,Battery"]
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
    
    private func collectData() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let timestamp = formatter.string(from: Date())
        DispatchQueue.main.async {
            self.batteryLevel = UIDevice.current.batteryLevel
        }
        // Accelerometer
        if let accel = motionManager.accelerometerData {
            DispatchQueue.main.async {
                self.accelX = accel.acceleration.x
                self.accelY = accel.acceleration.y
                self.accelZ = accel.acceleration.z
            }
            let csvLine = "A,\(timestamp),\(accelX),\(accelY),\(accelZ),,,,,,\(batteryLevel)"
            dataBuffer.append(csvLine)
            saveReading(timestamp: timestamp, source: "A", x: accelX, y: accelY, z: accelZ)
        }
        
        // Gyroscope
        if let gyro = motionManager.gyroData {
            DispatchQueue.main.async {
                self.gyroX = gyro.rotationRate.x
                self.gyroY = gyro.rotationRate.y
                self.gyroZ = gyro.rotationRate.z
            }
            let csvLine = "G,\(timestamp),\(gyroX),\(gyroY),\(gyroZ),,,,,,\(batteryLevel)"
            dataBuffer.append(csvLine)
            saveReading(timestamp: timestamp, source: "G", x: gyroX, y: gyroY, z: gyroZ)
        }
        
        if let motion = motionManager.deviceMotion {
            let rot = motion.rotationRate
            let ua = motion.userAcceleration
            let att = motion.attitude
            let csvLine = "D,\(timestamp),\(rot.x),\(rot.y),\(rot.z),\(ua.x),\(ua.y),\(ua.z),\(att.pitch),\(att.roll),\(att.yaw),\(batteryLevel)"
            dataBuffer.append(csvLine)
            saveReading(timestamp: timestamp, source: "D", x: rot.x, y: rot.y, z: rot.z,
                       uaX: ua.x, uaY: ua.y, uaZ: ua.z,
                       pitch: att.pitch, roll: att.roll, yaw: att.yaw)
        }
    }
    
    private func saveReading(timestamp: String, source: String, x: Double, y: Double, z: Double,
                             uaX: Double? = nil, uaY: Double? = nil, uaZ: Double? = nil,
                             pitch: Double? = nil, roll: Double? = nil, yaw: Double? = nil) {
        context.perform {
            let reading = SensorReading(context: self.context)
            reading.id = UUID()
            reading.source = source
            reading.timestamp = timestamp
            reading.x = x
            reading.y = y
            reading.z = z
            reading.uaX = uaX ?? 0
            reading.uaY = uaY ?? 0
            reading.uaZ = uaZ ?? 0
            reading.pitch = pitch ?? 0
            reading.roll = roll ?? 0
            reading.yaw = yaw ?? 0
            reading.battery = Double(UIDevice.current.batteryLevel)
            
            self.saveCounter += 1
            if self.saveCounter >= self.appConstants.saveThreshold {
                do {
                    try self.context.save()
                    self.dataBuffer.removeAll(keepingCapacity: true)
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
        
        var csvText = "timestamp,source,x,y,z,uaX,uaY,uaZ,pitch,roll,yaw,battery\n"

        for reading in sensorData {
            let timestamp = reading.timestamp ?? ""
            let source = reading.source ?? ""
            let line = "\(timestamp),\(source),\(reading.x),\(reading.y),\(reading.z)," +
                       "\(reading.uaX),\(reading.uaY),\(reading.uaZ)," +
                       "\(reading.pitch),\(reading.roll),\(reading.yaw),\(reading.battery)\n"
            csvText.append(line)
        }
        
        deleteRequests(for: context)
        
        do {
            try csvText.write(to: fileURL, atomically: true, encoding: .utf8)
            print("CSV file saved to: \(fileURL)")
            return fileURL
        } catch {
            print("Failed to write CSV file: \(error)")
            return nil
        }
    }
}
