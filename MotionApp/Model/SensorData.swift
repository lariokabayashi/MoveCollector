//
//  SensorData.swift
//  MotionApp
//
//  Created by Larissa Okabayashi on 15/10/25.
//

import SwiftUI
import CoreMotion
import UniformTypeIdentifiers
import CoreData

struct SensorData {
    let source: String       // "A", "G", "M", or "D"
    let x: Double
    let y: Double
    let z: Double
    
    let uaX: Double?         // user acceleration X (optional)
    let uaY: Double?
    let uaZ: Double?
    
    let pitch: Double?       // attitude pitch (optional)
    let roll: Double?
    let yaw: Double?
    
    let battery: Double      // battery level
    
    init(source: String, x: Double, y: Double, z: Double,
         uaX: Double? = nil, uaY: Double? = nil, uaZ: Double? = nil,
         pitch: Double? = nil, roll: Double? = nil, yaw: Double? = nil,
         battery: Double) {
        
        self.source = source
        self.x = x
        self.y = y
        self.z = z
        self.uaX = uaX
        self.uaY = uaY
        self.uaZ = uaZ
        self.pitch = pitch
        self.roll = roll
        self.yaw = yaw
        self.battery = battery
    }
}
