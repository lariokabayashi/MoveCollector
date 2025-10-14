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
import BackgroundTasks

final class SensorManager: NSObject, ObservableObject {
    private let motionManager = CMMotionManager()
    private let context: NSManagedObjectContext
    private let queue = OperationQueue()
    private var timer: Timer?
    private let updateInterval = 1.0/50.0
    private var saveCounter = 0
    private let saveThreshold = 500 // salva a cada 500 amostras
    
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
    
    @Published var magX = 0.0
    @Published var magY = 0.0
    @Published var magZ = 0.0
    
    @Published var batteryLevel: Float = UIDevice.current.batteryLevel
    
    var dataBuffer: [String] = []
    
    func startCollection() {
        motionManager.deviceMotionUpdateInterval = updateInterval
        motionManager.accelerometerUpdateInterval = updateInterval
        motionManager.gyroUpdateInterval = updateInterval
        motionManager.magnetometerUpdateInterval = updateInterval
        
        motionManager.startAccelerometerUpdates()
        motionManager.startGyroUpdates()
        motionManager.startDeviceMotionUpdates()
        motionManager.startMagnetometerUpdates()
        
        timer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { _ in
            self.collectData()
        }
        
        dataBuffer = ["Source,When,X,Y,Z,UA_X,UA_Y,UA_Z,Pitch,Roll,Yaw,Battery"]
    }
    
    func stopCollection() {
        isRecording = false
        
        motionManager.stopAccelerometerUpdates()
        motionManager.stopGyroUpdates()
        motionManager.stopDeviceMotionUpdates()
        motionManager.stopMagnetometerUpdates()
        timer?.invalidate()
        
        // Save any remaining data
        try? context.save()
    }

    private func saveReading(source: String, x: Double, y: Double, z: Double,
                             uaX: Double? = nil, uaY: Double? = nil, uaZ: Double? = nil,
                             pitch: Double? = nil, roll: Double? = nil, yaw: Double? = nil) {
        context.perform {
            let reading = SensorReading(context: self.context)
            reading.id = UUID()
            reading.source = source
            reading.timestamp = Date().timeIntervalSince1970
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
            if self.saveCounter >= self.saveThreshold {
                do {
                    try self.context.save()
                    self.saveCounter = 0
                } catch {
                    print("Core Data save error: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func collectData() {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        batteryLevel = UIDevice.current.batteryLevel
        
        // Accelerometer
        if let accel = motionManager.accelerometerData {
            accelX = accel.acceleration.x
            accelY = accel.acceleration.y
            accelZ = accel.acceleration.z
            let csvLine = "A,\(timestamp),\(accelX),\(accelY),\(accelZ),,,,,,\(batteryLevel)"
            dataBuffer.append(csvLine)
            saveReading(source: "A", x: accelX, y: accelY, z: accelZ)
        }
        
        // Gyroscope
        if let gyro = motionManager.gyroData {
            gyroX = gyro.rotationRate.x
            gyroY = gyro.rotationRate.y
            gyroZ = gyro.rotationRate.z
            let csvLine = "G,\(timestamp),\(gyroX),\(gyroY),\(gyroZ),,,,,,\(batteryLevel)"
            dataBuffer.append(csvLine)
            saveReading(source: "G", x: gyroX, y: gyroY, z: gyroZ)
        }
        
        // Magnetometer
        if let mag = motionManager.magnetometerData {
            magX = mag.magneticField.x
            magY = mag.magneticField.y
            magZ = mag.magneticField.z
            let csvLine = "M,\(timestamp),\(magX),\(magY),\(magZ),,,,,,\(batteryLevel)"
            dataBuffer.append(csvLine)
            saveReading(source: "M", x: magX, y: magY, z: magZ)
        }
        
        // Device Motion (rotation rate + user accel + attitude)
        if let motion = motionManager.deviceMotion {
            let rot = motion.rotationRate
            let ua = motion.userAcceleration
            let att = motion.attitude
            let csvLine = "D,\(timestamp),\(rot.x),\(rot.y),\(rot.z),\(ua.x),\(ua.y),\(ua.z),\(att.pitch),\(att.roll),\(att.yaw),\(batteryLevel)"
            dataBuffer.append(csvLine)
            saveReading(source: "D", x: rot.x, y: rot.y, z: rot.z,
                       uaX: ua.x, uaY: ua.y, uaZ: ua.z,
                       pitch: att.pitch, roll: att.roll, yaw: att.yaw)
        }
    }
    
    func exportToCSV() -> URL? {
        guard !dataBuffer.isEmpty else {
            print("No data to export")
            return nil
        }
        
        let csvText = dataBuffer.joined(separator: "\n")
        let fileName = "sensor_data_\(Date().timeIntervalSince1970).csv"
        
        // Use Documents directory
        let documentDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileURL = documentDirectory.appendingPathComponent(fileName)
        
        do {
            try csvText.write(to: fileURL, atomically: true, encoding: .utf8)
            print("CSV file saved to: \(fileURL)")
            return fileURL
        } catch {
            print("Failed to write CSV file: \(error)")
            return nil
        }
    }
    
    func setupBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.LarissaOkabayashi.MoveCollector",
                                      using: nil) { task in
            self.handleBackgroundCollection(task: task as! BGProcessingTask)
        }
    }
    
    private func handleBackgroundCollection(task: BGProcessingTask) {
        task.expirationHandler = {
            self.stopCollection()
        }
        
        // Continue collection in background
        startCollection()
        
        // Schedule next background task
        scheduleBackgroundCollection()
    }
    
    func scheduleBackgroundCollection() {
        let request = BGProcessingTaskRequest(identifier: "com.yourapp.sensor.collection")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60) // 30 minutes
        try? BGTaskScheduler.shared.submit(request)
    }
}
