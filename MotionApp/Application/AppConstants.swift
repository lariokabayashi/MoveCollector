//
//  AppConstants.swift
//  MotionApp
//
//  Created by Larissa Okabayashi on 15/10/25.
//

import Foundation
import SwiftUI

struct AppConstants{
    let backgroundTaskIdentifier = "com.LarissaOkabayashi.MoveCollector.task.process"
    let updateInterval = 1.0/10.0
    let windowSize = 150                // 3 sec @ 20 Hz
    let saveThreshold = 500
    let totalTime = .max as Int64
    let backgroundColor = Color(red: 242/255, green: 242/255, blue: 247/255)
}
