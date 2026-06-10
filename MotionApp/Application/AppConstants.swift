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
    
    // MARK: - Sensor Frequencies
    let sensorUpdateInterval = 1.0/20.0      // 0.05s = 20 Hz para sensores (acelerômetro + giroscópio)
    let gpsUpdateInterval = 1.0              // 1s = 1 Hz para GPS (frequência menor)
    
    // MARK: - CSV Export
    let csvAutoSaveInterval = 60             // Salvar CSV automaticamente a cada 60 segundos
    let csvBufferSize = 10000                // Máximo de 10000 registros em memória (~8 min a 20 Hz)
    
    // MARK: - Processing Parameters
    //
    // CRITICAL: windowSize está casado com o TFC_Backbone.mlpackage:
    //   inputs x_t, x_f shape [1, 11, 300]  →  windowSize = 300, nChannels = 11.
    // 300 samples @ 20 Hz = 15 segundos por janela. Não overlapping (step = window),
    // mesmo critério da pipeline Python de referência.
    let windowSize = 300               // 15 sec @ 20 Hz (matches TFC_Backbone input)
    let stepSize = 300                 // sem overlap (idêntico ao Python step_size = window_size)
    let nChannels = 11                 // 11 features: acc xyz + gyro xyz + lat + lon + alt + hAcc + vAcc
    //
    // ETAPA F (TFC particionado): 3 backbones (Acc, Gyro, GPS) cada um produzindo
    // 256d (concat z_t + z_f). Final = concat das 3 partições = 768d.
    // Antes (monolítico, 11 canais) era 256.
    let embeddingDim = 768             // 3 × (z_t[128] + z_f[128])
    let saveThreshold = 100            // Save every 100 seconds to prevent memory buildup
    let totalTime = .max as Int64
    
    // MARK: - Buffer Sizes
    let bufferSizeLoc = 10             // Salvar a cada 10 localizações GPS (10 segundos @ 1 Hz)
    
    // MARK: - UI
    let backgroundColor = Color(red: 242/255, green: 242/255, blue: 247/255)
    
    // MARK: - Timestamp Configuration
    // Tipo mais eficiente para timestamp: Int (milissegundos)
    // Int64: 8 bytes vs String (ISO8601): ~25+ bytes = 70% de economia de espaço
    typealias TimestampMillis = Int
    
    // MARK: - Helper Properties
    var sensorFrequencyHz: Double { 1.0 / sensorUpdateInterval }  // 20 Hz
    var gpsFrequencyHz: Double { 1.0 / gpsUpdateInterval }        // 1 Hz
}
