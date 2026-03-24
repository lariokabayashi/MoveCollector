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
    let ax: Double
    let ay: Double
    let az: Double
    let gx: Double
    let gy: Double
    let gz: Double
}
