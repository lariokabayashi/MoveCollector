//
//  AppConstants.swift
//  MotionApp
//
//  Created by Larissa Okabayashi on 15/10/25.
//

import Foundation

struct AppConstants{
    let backgroundTaskIdentifier = "com.LarissaOkabayashi.MoveCollector.task.process"
    let updateInterval = 1.0/50.0
    let saveThreshold = 500 // salva a cada 500 amostras
    let totalTime = 600 as Int64
}
